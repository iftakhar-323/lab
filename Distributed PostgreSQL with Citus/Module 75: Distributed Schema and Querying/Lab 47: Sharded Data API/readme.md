# Lab 47: Sharded Data API

In this lab, you will build a REST API using Flask to interact with your distributed database. To ensure this lab is fully standalone, you will first provision a Citus database in AWS using Pulumi. Then, you will create endpoints to insert new orders and query sharded data based on the `tenant_id`, leveraging Citus's distributed query engine.

*(Image prompt: A comprehensive request flow diagram illustrating an intelligent query routing system within an AWS infrastructure. A client sends a request containing a specific tenant identifier to the backend. The backend forwards this to the Citus Coordinator EC2 instance, which uses the identifier to bypass unnecessary servers and route the request directly and exclusively to the single specific Worker node holding that tenant's data. No code shown, just the conceptual architecture.)*

## Concept

| Term | Definition |
|---|---|
| Query Routing | The process where the coordinator node identifies which worker holds the necessary shard and forwards the query there. |
| Co-location | Storing related data for the same tenant on the same node to ensure fast local joins and transactions. |

When interacting with a distributed table, always include the distribution column (`tenant_id`) in your queries. For inserts, this tells Citus which shard should store the data. For reads, filtering by `tenant_id` allows Citus to route the query directly to the single worker node containing that data, completely avoiding cross-node network traffic and maximizing performance.

## Objectives

- Provision a Citus database cluster in AWS using Pulumi.
- Implement a `POST /orders` endpoint to insert multi-tenant data.
- Implement a `GET /orders/<tenant_id>` endpoint to retrieve sharded data.
- Verify distributed data insertion and retrieval.

## What You Will Build

```text
flask-api-lab/
├── infra/
│   ├── Pulumi.yaml
│   └── __main__.py
└── app/
    ├── requirements.txt
    ├── database.py
    └── app.py
```

You will build an infrastructure script to launch your AWS EC2 database server. Then, you will build a Flask application that defines API routes for creating and fetching orders, relying on the distributed schema concepts taught in the previous module.

## Step 1: Configure AWS CLI and Set Up Pulumi

First, you need to configure your AWS credentials and initialize a Pulumi project to provision the database infrastructure.

Create a directory for the infrastructure and initialize Pulumi:

```bash
mkdir -p flask-api-lab/infra
cd flask-api-lab/infra
sudo apt update && sudo apt install -y python3.8-venv awscli
aws configure
pulumi new aws-python
aws ec2 create-key-pair --key-name CitusKeyPair --query 'KeyMaterial' --output text > CitusKeyPair.pem
chmod 400 CitusKeyPair.pem
```

**Explanation:**
- `aws configure`: Prompts you to enter your AWS Access Key, Secret Key, and Region (`ap-southeast-1`).
- `pulumi new aws-python`: Scaffolds a new Pulumi Python project for deploying AWS resources.

## Step 2: Define and Deploy the AWS Infrastructure

Replace the contents of `flask-api-lab/infra/__main__.py` with the following Pulumi code to provision a Citus cluster via Docker Compose on a single EC2 instance:

```python
import pulumi
import pulumi_aws as aws

user_data = """#!/bin/bash
apt-get update -y
apt-get install -y docker.io docker-compose
systemctl start docker
systemctl enable docker
usermod -aG docker ubuntu

cat > /home/ubuntu/docker-compose.yml << 'EOF'
version: '3.8'
services:
  coordinator:
    image: citusdata/citus:12.1
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus
    command: ["-c", "listen_addresses=*"]
  worker1:
    image: citusdata/citus:12.1
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus
  worker2:
    image: citusdata/citus:12.1
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus
EOF

cd /home/ubuntu/
docker-compose up -d
sleep 20
docker exec coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker1', 5432);"
docker exec coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker2', 5432);"
docker exec coordinator psql -U citus -d citus -c "CREATE TABLE products (id int PRIMARY KEY, name text, price float);"
docker exec coordinator psql -U citus -d citus -c "CREATE TABLE orders (id serial, tenant_id int, product_id int, quantity int, PRIMARY KEY(id, tenant_id));"
docker exec coordinator psql -U citus -d citus -c "SELECT create_reference_table('products');"
docker exec coordinator psql -U citus -d citus -c "SELECT create_distributed_table('orders', 'tenant_id');"
"""

vpc = aws.ec2.Vpc("citus-vpc", cidr_block="10.0.0.0/16", enable_dns_hostnames=True, enable_dns_support=True)
igw = aws.ec2.InternetGateway("citus-igw", vpc_id=vpc.id)
subnet = aws.ec2.Subnet("citus-subnet", vpc_id=vpc.id, cidr_block="10.0.1.0/24", map_public_ip_on_launch=True)
rt = aws.ec2.RouteTable("citus-rt", vpc_id=vpc.id, routes=[aws.ec2.RouteTableRouteArgs(cidr_block="0.0.0.0/0", gateway_id=igw.id)])
rt_assoc = aws.ec2.RouteTableAssociation("citus-rt-assoc", subnet_id=subnet.id, route_table_id=rt.id)

sg = aws.ec2.SecurityGroup("citus-sg",
    vpc_id=vpc.id,
    ingress=[
        {"protocol": "tcp", "from_port": 22, "to_port": 22, "cidr_blocks": ["0.0.0.0/0"]},
        {"protocol": "tcp", "from_port": 5432, "to_port": 5432, "cidr_blocks": ["0.0.0.0/0"]}
    ],
    egress=[{"protocol": "-1", "from_port": 0, "to_port": 0, "cidr_blocks": ["0.0.0.0/0"]}]
)

citus_instance = aws.ec2.Instance("citus-instance",
    instance_type="t2.medium",
    vpc_security_group_ids=[sg.id],
    ami="ami-04b70fa74e45c3917",
    subnet_id=subnet.id,
    key_name="CitusKeyPair",
    user_data=user_data,
    user_data_replace_on_change=True,
    opts=pulumi.ResourceOptions(depends_on=[rt_assoc])
)

pulumi.export("coordinator_ip", citus_instance.public_ip)
```

Run the deployment and save the outputted IP:

```bash
pulumi up --yes
```

**Explanation:**
- `user_data`: Sets up the database cluster. Notice we also included the SQL commands to create and distribute the `products` and `orders` tables, so the schema is completely ready for the API to use.
- *Wait 2-3 minutes after deployment finishes for the database and schemas to fully initialize.*

## Step 3: Create Application Dependencies

Navigate out of the infrastructure folder, create an `app` directory, and set up your Python environment:

```bash
cd ../
mkdir app
cd app
python3 -m venv venv
source venv/bin/activate
```

Create a file named `flask-api-lab/app/requirements.txt` with the following contents:

```text
Flask==3.0.0
psycopg2-binary==2.9.9
Flask-SQLAlchemy==3.1.1
```

Install the dependencies:

```bash
pip install -r requirements.txt
```

## Step 4: Define the Database Models

Create a file named `flask-api-lab/app/database.py` with the following contents:

```python
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()

class Product(db.Model):
    __tablename__ = 'products'
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    price = db.Column(db.Float, nullable=False)

class Order(db.Model):
    __tablename__ = 'orders'
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    tenant_id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, nullable=False)
    quantity = db.Column(db.Integer, nullable=False)
```

**Explanation:**
- `class Product(db.Model)`: Maps to the reference table across the cluster.
- `class Order(db.Model)`: Maps to the distributed table sharded by `tenant_id`.

## Step 5: Implement the API Routes

Create a file named `flask-api-lab/app/app.py` with the following contents:

```python
import os
from flask import Flask, request, jsonify
from database import db, Order, Product

app = Flask(__name__)
COORDINATOR_IP = os.environ.get("COORDINATOR_IP", "127.0.0.1")
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://citus:citus_password@{COORDINATOR_IP}:5432/citus'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db.init_app(app)

@app.route('/orders', methods=['POST'])
def create_order():
    data = request.get_json()
    new_order = Order(
        tenant_id=data['tenant_id'],
        product_id=data['product_id'],
        quantity=data['quantity']
    )
    db.session.add(new_order)
    db.session.commit()
    return jsonify({"message": "Order created", "tenant_id": new_order.tenant_id, "order_id": new_order.id}), 201

@app.route('/orders/<int:tenant_id>', methods=['GET'])
def get_orders(tenant_id):
    # Query routed directly to the specific tenant's shard
    orders = Order.query.filter_by(tenant_id=tenant_id).all()
    result = []
    for o in orders:
        product = Product.query.get(o.product_id)
        result.append({
            "order_id": o.id,
            "tenant_id": o.tenant_id,
            "product": product.name if product else "Unknown",
            "quantity": o.quantity
        })
    return jsonify(result), 200

if __name__ == '__main__':
    # Insert dummy products if empty for testing
    with app.app_context():
        if not Product.query.first():
            db.session.add(Product(id=1, name="Laptop", price=1200.00))
            db.session.add(Product(id=2, name="Mouse", price=25.00))
            db.session.commit()
            
    app.run(host='0.0.0.0', port=5000)
```

**Explanation:**
- `@app.route('/orders', methods=['POST'])`: Endpoint to accept new orders. The incoming JSON must contain `tenant_id` to allow Citus to route the insert.
- `Order.query.filter_by(tenant_id=tenant_id)`: Crucial step that includes the distribution column in the WHERE clause, ensuring single-shard query performance.
- `Product.query.get(...)`: Since `products` is a reference table, this join is performed seamlessly and locally on whichever worker node executes the query.

## Verification

Start the application by setting the coordinator IP (from your Pulumi output in Step 2):

```bash
export COORDINATOR_IP="YOUR_EC2_PUBLIC_IP"
python3 app.py
```

Open a new terminal to run the test commands.

**Scenario 1: Insert an order for Tenant A (Success)**

```bash
curl -X POST http://localhost:5000/orders \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 501, "product_id": 1, "quantity": 2}'
```

Expected Output:
```json
{
  "message": "Order created",
  "order_id": 1,
  "tenant_id": 501
}
```

**Scenario 2: Insert an order for Tenant B (Success)**

```bash
curl -X POST http://localhost:5000/orders \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 502, "product_id": 2, "quantity": 5}'
```

Expected Output:
```json
{
  "message": "Order created",
  "order_id": 2,
  "tenant_id": 502
}
```

**Scenario 3: Retrieve orders for Tenant A (Success)**

```bash
curl -X GET http://localhost:5000/orders/501
```

Expected Output:
```json
[
  {
    "order_id": 1,
    "product": "Laptop",
    "quantity": 2,
    "tenant_id": 501
  }
]
```

**Scenario 4: Retrieve orders with a non-existent tenant (Success but Empty)**

```bash
curl -X GET http://localhost:5000/orders/999
```

Expected Output:
```json
[]
```

| # | Call | Status | Body snippet |
|---|---|---|---|
| 1 | `POST /orders` for tenant 501 | 201 | `{"message": "Order created"...}` |
| 2 | `POST /orders` for tenant 502 | 201 | `{"message": "Order created"...}` |
| 3 | `GET /orders/501` | 200 | `[{"product": "Laptop"...}]` |
| 4 | `GET /orders/999` | 200 | `[]` |

## Conclusion

You have successfully built an API that securely interacts with an AWS-hosted sharded database. By designing queries that filter by the distribution column, the API ensures optimal performance by pushing down executions directly to the correct worker nodes.
