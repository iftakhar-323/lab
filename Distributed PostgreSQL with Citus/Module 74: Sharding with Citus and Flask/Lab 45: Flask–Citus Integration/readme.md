# Lab 45: Flask–Citus Integration

In this lab, you will build a Python REST API using Flask and SQLAlchemy that connects to a distributed Citus cluster. You will first provision the Citus database infrastructure in AWS using Pulumi, ensuring this lab is entirely standalone. You will then create endpoints to handle multi-tenant data, inserting and querying records across sharded tables. This demonstrates how a standard Flask application interacts seamlessly with Citus just like regular PostgreSQL.

*(Image prompt: A comprehensive architectural overview diagram of the lab showing a user making API requests to a web application backend. The backend is connected to a Citus database cluster hosted on an AWS EC2 instance, highlighting a central Coordinator node managing communication and distributing the workload across multiple Worker nodes for horizontal scalability. No code shown, just the conceptual architecture.)*

## Concept

| Term | Definition |
|---|---|
| Infrastructure as Code (IaC) | The process of managing and provisioning computing infrastructure through machine-readable definition files, such as Pulumi scripts. |
| Distribution Column | The column used by Citus to shard data across worker nodes (e.g., `tenant_id`). |
| Multi-tenant | An architecture where a single instance of a software application serves multiple customers (tenants), isolated by a tenant ID. |

Citus is fully compatible with standard PostgreSQL drivers like `psycopg2`. This means your Flask application does not need any specialized Citus libraries to work. You simply define your models, mark the table as distributed by executing a specific Citus function (`create_distributed_table`), and ensure all queries include the distribution column to efficiently route them to the correct shards.

## Objectives

- Provision a Citus database cluster in AWS using Pulumi.
- Configure a Python virtual environment with Flask and SQLAlchemy.
- Implement a multi-tenant database model.
- Build REST endpoints to insert and retrieve sharded data.
- Verify distributed query execution and data insertion.

## What You Will Build

```text
flask-citus-lab/
├── infra/
│   ├── Pulumi.yaml
│   └── __main__.py
└── app/
    ├── requirements.txt
    ├── database.py
    └── app.py
```

You will write a Pulumi script to automatically deploy a Citus cluster on an AWS EC2 instance. Then, you will build a Flask application that connects to this coordinator, initializing a multi-tenant `events` table distributed by `tenant_id`, and exposes REST API routes.

## Step 1: Configure AWS CLI and Set Up Pulumi

First, you need to configure your AWS credentials and initialize a Pulumi project to provision the database infrastructure.

Create a directory for the infrastructure and initialize Pulumi:

```bash
mkdir -p flask-citus-lab/infra
cd flask-citus-lab/infra
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

Replace the contents of `flask-citus-lab/infra/__main__.py` with the following Pulumi code to provision a Citus cluster via Docker Compose on a single EC2 instance:

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
- `aws.ec2.Vpc` & `aws.ec2.SecurityGroup`: Configures the networking to allow traffic on port `5432` (PostgreSQL).
- `pulumi.export`: Exposes the public IP of the EC2 instance so you can connect to the database from your Flask application.
- *Wait 2-3 minutes after deployment finishes for the database to fully start.*

## Step 3: Create the Application Dependencies

Navigate out of the infrastructure folder, create an `app` directory, and set up your Python environment. Create a file named `flask-citus-lab/app/requirements.txt` with the following contents:

```text
Flask==3.0.0
psycopg2-binary==2.9.9
Flask-SQLAlchemy==3.1.1
```

Install the dependencies:

```bash
cd ../
mkdir app
cd app
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

**Explanation:**
- `Flask==3.0.0`: The lightweight web framework used to create the API endpoints.
- `psycopg2-binary==2.9.9`: The PostgreSQL database adapter required to communicate with the Citus coordinator.
- `Flask-SQLAlchemy==3.1.1`: An extension that simplifies using SQLAlchemy with Flask.

## Step 4: Implement Database Connection and Schema

Create a file named `flask-citus-lab/app/database.py` with the following contents:

```python
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text

db = SQLAlchemy()

class Event(db.Model):
    __tablename__ = 'events'
    
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    tenant_id = db.Column(db.Integer, primary_key=True)
    event_name = db.Column(db.String(100), nullable=False)
    
def setup_database(app):
    with app.app_context():
        db.create_all()
        distribute_query = text("SELECT create_distributed_table('events', 'tenant_id');")
        try:
            db.session.execute(distribute_query)
            db.session.commit()
        except Exception:
            db.session.rollback()
            pass
```

**Explanation:**
- `db = SQLAlchemy()`: Initializes the SQLAlchemy instance.
- `class Event(db.Model)`: Defines the `events` table model.
- `tenant_id = db.Column(..., primary_key=True)`: Citus requires the distribution column to be part of the primary key for distributed tables.
- `db.session.execute(distribute_query)`: Executes the specific Citus function to shard the table across worker nodes based on the `tenant_id`.

## Step 5: Implement the Flask Application

Create a file named `flask-citus-lab/app/app.py` with the following contents:

```python
import os
from flask import Flask, request, jsonify
from database import db, Event, setup_database

app = Flask(__name__)

COORDINATOR_IP = os.environ.get("COORDINATOR_IP", "127.0.0.1")
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://citus:citus_password@{COORDINATOR_IP}:5432/citus'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db.init_app(app)
setup_database(app)

@app.route('/events', methods=['POST'])
def create_event():
    data = request.get_json()
    new_event = Event(
        tenant_id=data['tenant_id'],
        event_name=data['event_name']
    )
    db.session.add(new_event)
    db.session.commit()
    return jsonify({"message": "Event created", "tenant_id": new_event.tenant_id}), 201

@app.route('/events/<int:tenant_id>', methods=['GET'])
def get_events(tenant_id):
    events = Event.query.filter_by(tenant_id=tenant_id).all()
    result = [{"id": e.id, "tenant_id": e.tenant_id, "event_name": e.event_name} for e in events]
    return jsonify(result), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
```

**Explanation:**
- `app.config['SQLALCHEMY_DATABASE_URI']`: Sets the connection string to point to the remote Citus EC2 instance you provisioned.
- `setup_database(app)`: Calls the function to create and distribute the table on startup.
- `Event.query.filter_by(tenant_id=tenant_id).all()`: Queries events for a specific tenant, allowing Citus to route the query directly to the correct worker node.

## Verification

Get your Coordinator IP from the Pulumi outputs in Step 2, set it as an environment variable, and start the Flask app:

```bash
export COORDINATOR_IP="YOUR_EC2_PUBLIC_IP"
python3 app.py
```

Open a new terminal window to run the following verification commands.

**Scenario 1: Create an event (Success)**

```bash
curl -X POST http://localhost:5000/events \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 101, "event_name": "User Signup"}'
```

Expected Output:
```json
{
  "message": "Event created",
  "tenant_id": 101
}
```

**Scenario 2: Create another event for a different tenant (Success)**

```bash
curl -X POST http://localhost:5000/events \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 102, "event_name": "Item Purchased"}'
```

Expected Output:
```json
{
  "message": "Event created",
  "tenant_id": 102
}
```

**Scenario 3: Retrieve events for a specific tenant (Success)**

```bash
curl -X GET http://localhost:5000/events/101
```

Expected Output:
```json
[
  {
    "event_name": "User Signup",
    "id": 1,
    "tenant_id": 101
  }
]
```

**Scenario 4: Retrieve events with missing data (Failure)**

```bash
curl -X GET http://localhost:5000/events
```

Expected Output:
```html
<!doctype html>
<html lang=en>
<title>405 Method Not Allowed</title>
<h1>Method Not Allowed</h1>
<p>The method is not allowed for the requested URL.</p>
</html>
```

| # | Call | Status | Body snippet |
|---|---|---|---|
| 1 | `POST /events` with valid JSON | 201 | `{"message": "Event created"...}` |
| 2 | `POST /events` for tenant 102 | 201 | `{"message": "Event created"...}` |
| 3 | `GET /events/101` | 200 | `[{"event_name": "User Signup"...}]` |
| 4 | `GET /events` | 405 | `<title>405 Method Not Allowed</title>` |

## Conclusion

You have successfully built a Flask API integrated with a Citus cluster completely from scratch. By utilizing Pulumi for infrastructure automation and SQLAlchemy for application routing, you demonstrated how modern microservices connect to distributed shards seamlessly.
