# Lab 46: Distributed Schema Design

In this lab, you will design a distributed schema using Citus. You will first provision a brand-new Citus cluster in AWS using Pulumi to ensure this lab is standalone. Then, you will define database models for tenants, products, and orders, configuring `orders` as a sharded table based on `tenant_id` and `products` as a globally replicated reference table.

*(Image prompt: A comprehensive database schema overview diagram showing the Citus cluster architecture hosted on AWS EC2. It visualizes large transaction data being sharded and distributed evenly across multiple Worker nodes, while smaller lookup tables are fully copied and replicated to every Worker node to allow fast, localized data processing without network latency. No code shown, just the conceptual architecture.)*

## Concept

| Term | Definition |
|---|---|
| Infrastructure as Code (IaC) | Automating the creation of AWS EC2 and networking resources using Pulumi. |
| Distributed Table | A table split into smaller shards across worker nodes based on a distribution column. |
| Reference Table | A smaller table fully replicated to all worker nodes to enable fast local joins without network overhead. |

When designing a schema in Citus, large transaction tables (like `orders`) are distributed to scale storage and compute. Smaller, frequently joined lookup tables (like `products`) are made into reference tables. This ensures that when a worker processes a query for a specific tenant's orders, it has local access to all product details without asking other nodes.

## Objectives

- Provision a Citus database cluster in AWS using Pulumi.
- Configure SQLAlchemy models for tenants, products, and orders.
- Implement distributed tables using `create_distributed_table`.
- Implement reference tables using `create_reference_table`.
- Verify the schema distribution across the Citus cluster.

## What You Will Build

```text
flask-schema-lab/
├── infra/
│   ├── Pulumi.yaml
│   └── __main__.py
└── app/
    ├── requirements.txt
    ├── database.py
    └── setup.py
```

You will build a standalone Pulumi infrastructure script to deploy a Citus database. Following that, you will write a database setup script that defines the schema using SQLAlchemy and executes Citus-specific commands to distribute and replicate the tables.

## Step 1: Configure AWS CLI and Set Up Pulumi

First, you need to configure your AWS credentials and initialize a Pulumi project to provision the database infrastructure.

Create a directory for the infrastructure and initialize Pulumi:

```bash
mkdir -p flask-schema-lab/infra
cd flask-schema-lab/infra
sudo apt update && sudo apt install -y python3.8-venv awscli
aws configure
pulumi new aws-python
aws ec2 create-key-pair --key-name CitusKeyPair --query 'KeyMaterial' --output text > CitusKeyPair.pem
chmod 400 CitusKeyPair.pem
```

**Explanation:**
- `aws configure`: Prompts you to enter your AWS Access Key, Secret Key, and Region (`ap-southeast-1`).
- `pulumi new aws-python`: Scaffolds a new Pulumi Python project for deploying AWS resources.
- `aws ec2 create-key-pair`: Creates an SSH key pair securely to access the deployed EC2 instance if needed.

## Step 2: Define and Deploy the AWS Infrastructure

Replace the contents of `flask-schema-lab/infra/__main__.py` with the following Pulumi code to provision a Citus cluster via Docker Compose on a single EC2 instance:

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
- `user_data`: A bash script executed on the EC2 instance at boot. It installs Docker, runs a Citus coordinator and two workers using `docker-compose`, and registers the workers automatically.
- `pulumi.export`: Exposes the public IP of the EC2 instance so you can connect to the database locally.
- *Wait 2-3 minutes after deployment finishes for the database to fully start.*

## Step 3: Create Application Dependencies

Navigate out of the infrastructure folder, create an `app` directory, and set up your Python environment:

```bash
cd ../
mkdir app
cd app
python3 -m venv venv
source venv/bin/activate
```

Create a file named `flask-schema-lab/app/requirements.txt` with the following contents:

```text
psycopg2-binary==2.9.9
Flask-SQLAlchemy==3.1.1
Flask==3.0.0
```

Install the dependencies:

```bash
pip install -r requirements.txt
```

**Explanation:**
- `psycopg2-binary==2.9.9`: PostgreSQL driver required for database connection.
- `Flask-SQLAlchemy==3.1.1`: ORM used to define the database models.
- `Flask==3.0.0`: Required to provide the application context for SQLAlchemy.

## Step 4: Define the Database Models

Create a file named `flask-schema-lab/app/database.py` with the following contents:

```python
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()

class Tenant(db.Model):
    __tablename__ = 'tenants'
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)

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
- `class Product(db.Model)`: Defines the products lookup table.
- `class Order(db.Model)`: Defines the transaction table.
- `tenant_id = db.Column(..., primary_key=True)`: Citus requires the distribution column to be part of the primary key for distributed tables, so it is included in the composite primary key.

## Step 5: Implement Schema Distribution

Create a file named `flask-schema-lab/app/setup.py` with the following contents:

```python
import os
from flask import Flask
from sqlalchemy import text
from database import db

app = Flask(__name__)
COORDINATOR_IP = os.environ.get("COORDINATOR_IP", "127.0.0.1")
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://citus:citus_password@{COORDINATOR_IP}:5432/citus'
db.init_app(app)

def initialize_database():
    with app.app_context():
        db.create_all()
        
        try:
            db.session.execute(text("SELECT create_reference_table('products');"))
            db.session.commit()
            print("Products table replicated successfully.")
        except Exception as e:
            db.session.rollback()
            print(f"Products table setup: {e}")
            
        try:
            db.session.execute(text("SELECT create_distributed_table('orders', 'tenant_id');"))
            db.session.commit()
            print("Orders table distributed successfully.")
        except Exception as e:
            db.session.rollback()
            print(f"Orders table setup: {e}")

if __name__ == '__main__':
    initialize_database()
```

**Explanation:**
- `db.create_all()`: Creates the physical tables in the database based on the models.
- `SELECT create_reference_table('products')`: Replicates the `products` table across all worker nodes.
- `SELECT create_distributed_table('orders', 'tenant_id')`: Shards the `orders` table across the cluster using `tenant_id` as the distribution column.

## Verification

Get your Coordinator IP from the Pulumi outputs in Step 2, and run the setup script.

**Scenario 1: Run setup script (Success)**

```bash
export COORDINATOR_IP="YOUR_EC2_PUBLIC_IP" 
python3 setup.py
```

Expected Output:
```text
Products table replicated successfully.
Orders table distributed successfully.
```

**Scenario 2: Verify Citus distribution via PSQL (Success)**

```bash
psql -h $COORDINATOR_IP -U citus -d citus -c "SELECT logicalrelid, replication_model FROM citus_tables;"
```

*(Enter password `citus_password` when prompted)*

Expected Output:
```text
 logicalrelid | replication_model 
--------------+-------------------
 products     | reference
 orders       | 2pc
(2 rows)
```

| # | Call | Status | Body snippet |
|---|---|---|---|
| 1 | `python3 setup.py` | 0 | `Products table replicated successfully.` |
| 2 | `psql -c "SELECT ..."` | 0 | `products \| reference` |

## Conclusion

You have successfully automated the creation of an AWS environment and defined a complex schema in Citus. By defining `orders` as a distributed table and `products` as a reference table, you have prepared the newly provisioned database for high-performance distributed queries.
