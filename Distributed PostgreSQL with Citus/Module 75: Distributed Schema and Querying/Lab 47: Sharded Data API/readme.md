# Lab 47: Sharded Data API

In this lab, you will build and deploy a multi-tenant REST API using Flask that communicates with a distributed Citus database cluster. You will deploy a 3-node Citus cluster (1 Coordinator + 2 Workers) directly using Docker Compose in your Poridhi environment. You will then create API endpoints to insert and retrieve tenant orders, leverage Citus's distributed query routing engine, and expose your service publicly using the **Poridhi Load Balancer**.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/architecture_diagram.svg?v=2" alt="Sharded Data API Architecture" width="750">
</p>

---

## Objectives

- Deploy a 3-node Citus cluster (1 Coordinator + 2 Workers) using Docker Compose.
- Configure a Python virtual environment with Flask, SQLAlchemy, and psycopg2.
- Define relational models with a distributed transaction table (`orders`) and a replicated reference catalog (`products`).
- Build `POST /orders` to insert distributed multi-tenant order data.
- Build `GET /orders/<tenant_id>` to query sharded data with single-node query routing.
- Expose port `5000` publicly via the **Poridhi Load Balancer**.
- Verify query routing and API responsiveness using cURL and browser requests.

---

## Project Structure

```text
flask-api-lab/
├── citus/
│   └── docker-compose.yml
└── app/
    ├── requirements.txt
    ├── database.py
    └── app.py
```

---

## Step 1: Deploy Citus Cluster using Docker Compose

Create a dedicated directory for the Citus cluster and define the multi-node cluster services:

```bash
mkdir -p ~/flask-api-lab/citus
cd ~/flask-api-lab/citus
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/01_mkdir_citus.png" alt="Create Citus Directory" width="700">
</p>

Create `docker-compose.yml`:

```bash
cat << 'EOF' > docker-compose.yml
version: '3.8'
services:
  coordinator:
    image: citusdata/citus:12.1
    container_name: citus_coordinator
    restart: always
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus
    command: ["-c", "listen_addresses=*"]

  worker1:
    image: citusdata/citus:12.1
    container_name: citus_worker_1
    restart: always
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus

  worker2:
    image: citusdata/citus:12.1
    container_name: citus_worker_2
    restart: always
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/02_create_docker_compose.png" alt="Create docker-compose.yml" width="700">
</p>

Start the Citus cluster:

```bash
docker compose up -d || docker-compose up -d
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/03_docker_compose_up.png" alt="Start Citus Containers" width="700">
</p>

Wait 10 seconds for PostgreSQL instances to initialize, then register the worker nodes with the coordinator:

```bash
sleep 10
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker1', 5432);"
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker2', 5432);"
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/04_citus_add_nodes.png" alt="Register Citus Worker Nodes" width="700">
</p>

Verify active worker nodes:

```bash
docker exec -it citus_coordinator psql -U citus -d citus -c "SELECT * FROM citus_get_active_worker_nodes();"
```

Expected Output:

```text
 node_name | node_port 
-----------+-----------
 worker1   |      5432
 worker2   |      5432
(2 rows)
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/05_citus_active_workers.png" alt="Verify Active Citus Workers" width="700">
</p>

---

## Step 2: Set Up Application Environment & Dependencies

Navigate to your workspace directory, create the `app` folder, and configure the Python virtual environment:

```bash
mkdir -p ~/flask-api-lab/app
cd ~/flask-api-lab/app

python3 -m venv venv
source venv/bin/activate
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/06_setup_app_venv.png" alt="Setup Virtual Environment" width="700">
</p>

Create `requirements.txt`:

```bash
cat << 'EOF' > requirements.txt
Flask==3.0.0
psycopg2-binary==2.9.9
Flask-SQLAlchemy==3.1.1
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/07_create_requirements.png" alt="Create requirements.txt" width="700">
</p>

Install dependencies:

```bash
pip install -r requirements.txt
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/08_pip_install.png" alt="Pip Install Dependencies" width="700">
</p>

---

## Step 3: Implement Database Models and Distributed Tables

Create `flask-api-lab/app/database.py` to define the database schema, replicate `products` as a reference table, distribute `orders` across worker shards, and seed sample product catalog items:

```bash
cat << 'EOF' > database.py
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text

db = SQLAlchemy()

class Product(db.Model):
    __tablename__ = 'products'
    # Reference table: Duplicated on all worker nodes
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    price = db.Column(db.Float, nullable=False)

class Order(db.Model):
    __tablename__ = 'orders'
    # Distributed table: Sharded across workers by tenant_id
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    tenant_id = db.Column(db.Integer, primary_key=True)
    product_id = db.Column(db.Integer, nullable=False)
    quantity = db.Column(db.Integer, nullable=False)

def setup_database(app):
    with app.app_context():
        # Create base PostgreSQL tables
        db.create_all()

        # Replicate products as Reference Table
        try:
            db.session.execute(text("SELECT create_reference_table('products');"))
            db.session.commit()
            print("Products reference table initialized.")
        except Exception:
            db.session.rollback()

        # Distribute orders by tenant_id
        try:
            db.session.execute(text("SELECT create_distributed_table('orders', 'tenant_id');"))
            db.session.commit()
            print("Orders distributed table initialized.")
        except Exception:
            db.session.rollback()

        # Seed initial catalog products if empty
        if not Product.query.first():
            db.session.add(Product(id=1, name="Mechanical Keyboard", price=120.00))
            db.session.add(Product(id=2, name="Ergonomic Mouse", price=65.00))
            db.session.add(Product(id=3, name="4K Monitor", price=450.00))
            db.session.commit()
            print("Sample products seeded into reference table.")
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/09_create_database_py.png" alt="Create database.py" width="700">
</p>

---

## Step 4: Implement the Flask API Application

Create `flask-api-lab/app/app.py` with endpoints to create and retrieve tenant orders:

```bash
cat << 'EOF' > app.py
import os
from flask import Flask, request, jsonify
from database import db, Product, Order, setup_database

app = Flask(__name__)

COORDINATOR_IP = os.environ.get("COORDINATOR_IP", "127.0.0.1")
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://citus:citus_password@{COORDINATOR_IP}:5432/citus'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db.init_app(app)
setup_database(app)

@app.route('/', methods=['GET'])
def index():
    return jsonify({
        "service": "Sharded Order Management API",
        "status": "ready",
        "database": "Citus Distributed Cluster"
    }), 200

@app.route('/orders', methods=['POST'])
def create_order():
    data = request.get_json()
    if not data or 'tenant_id' not in data or 'product_id' not in data or 'quantity' not in data:
        return jsonify({"error": "tenant_id, product_id, and quantity are required"}), 400

    product = Product.query.get(data['product_id'])
    if not product:
        return jsonify({"error": f"Product with ID {data['product_id']} not found"}), 404

    order = Order(
        tenant_id=data['tenant_id'],
        product_id=data['product_id'],
        quantity=data['quantity']
    )
    db.session.add(order)
    db.session.commit()

    return jsonify({
        "message": "Order created successfully",
        "order_id": order.id,
        "tenant_id": order.tenant_id,
        "product": product.name,
        "total_amount": round(product.price * order.quantity, 2)
    }), 201

@app.route('/orders/<int:tenant_id>', methods=['GET'])
def get_orders(tenant_id):
    # Citus routes this query directly to the worker holding this tenant_id shard
    orders = Order.query.filter_by(tenant_id=tenant_id).all()
    result = []
    for o in orders:
        product = Product.query.get(o.product_id)
        result.append({
            "order_id": o.id,
            "tenant_id": o.tenant_id,
            "product": product.name if product else "Unknown",
            "quantity": o.quantity,
            "unit_price": product.price if product else 0.0,
            "total_price": round((product.price if product else 0.0) * o.quantity, 2)
        })
    return jsonify(result), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/10_create_app_py.png" alt="Create app.py" width="700">
</p>

---

## Step 5: Expose API via Poridhi Load Balancer

In the Poridhi cloud lab environment, the virtual machine runs inside a private isolated network. To access your Flask application from your browser or via public HTTP requests, expose port `5000` using the built-in **Poridhi Load Balancer**:

1. Find the primary IP of the Poridhi lab container:

   ```bash
   hostname -I | awk '{print $1}'
   ```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/11_hostname_ip.png" alt="Get Hostname IP" width="700">
</p>

2. Open the **Load Balancer** modal from the Poridhi interface (the Cloud icon in the header or sidebar).
3. Enter the configuration:

   - **Enter IP**: Paste the IP obtained above (e.g., `10.x.x.x`).
   - **Enter Port**: `5000`
   - Click **Expose**.
4. Poridhi will provision an edge load balancer and provide an active public URL (e.g., `http://<lab-id>-5000.lb.poridhi.io`).

---

## Step 6: Run & Verify Application

### 1. Start the Application

In your terminal, start the Flask server:

```bash
cd ~/flask-api-lab/app
source venv/bin/activate
python3 app.py
```

Expected Startup Output:

```text
Products reference table initialized.
Orders distributed table initialized.
Sample products seeded into reference table.
 * Serving Flask app 'app'
 * Running on all addresses (0.0.0.0)
 * Running on http://127.0.0.1:5000
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/13_flask_run.png" alt="Flask Server Running Output" width="700">
</p>

### 2. Verify via cURL or Poridhi Load Balancer URL

Open a second terminal window (or test using your browser / cURL):

You can replace `http://localhost:5000` with your **Poridhi Load Balancer URL** (e.g., `http://<id>-5000.lb.poridhi.io`) in any of the commands below to test the public endpoint.

**Scenario 1: Health check**

```bash
curl -X GET http://localhost:5000/
```

Expected Output:

```json
{
  "database": "Citus Distributed Cluster",
  "service": "Sharded Order Management API",
  "status": "ready"
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/14_curl_health_check.png" alt="Health Check API Response" width="700">
</p>

**Scenario 2: Create an order for Tenant 501**

```bash
curl -X POST http://localhost:5000/orders \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 501, "product_id": 1, "quantity": 2}'
```

Expected Output:

```json
{
  "message": "Order created successfully",
  "order_id": 1,
  "product": "Mechanical Keyboard",
  "tenant_id": 501,
  "total_amount": 240.0
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/15_curl_post_tenant_501.png" alt="Create Order Tenant 501 Response" width="700">
</p>

**Scenario 3: Create an order for Tenant 502**

```bash
curl -X POST http://localhost:5000/orders \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 502, "product_id": 2, "quantity": 3}'
```

Expected Output:

```json
{
  "message": "Order created successfully",
  "order_id": 2,
  "product": "Ergonomic Mouse",
  "tenant_id": 502,
  "total_amount": 195.0
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/16_curl_post_tenant_502.png" alt="Create Order Tenant 502 Response" width="700">
</p>

**Scenario 4: Retrieve orders for Tenant 501**

```bash
curl -X GET http://localhost:5000/orders/501
```

Expected Output:

```json
[
  {
    "order_id": 1,
    "product": "Mechanical Keyboard",
    "quantity": 2,
    "tenant_id": 501,
    "total_price": 240.0,
    "unit_price": 120.0
  }
]
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/17_curl_get_tenant_501.png" alt="Retrieve Orders Tenant 501 Response" width="700">
</p>

**Scenario 5: Retrieve orders for a non-existent tenant (503)**

```bash
curl -X GET http://localhost:5000/orders/503
```

Expected Output:

```json
[]
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/images/18_curl_get_tenant_503.png" alt="Retrieve Orders Tenant 503 Empty Response" width="700">
</p>

---

## Conclusion

You have successfully built an API service that operates on a sharded Citus database cluster. By leveraging the `tenant_id` distribution column in queries, the API allows Citus to bypass cross-node cluster network overhead and route queries directly to the correct shard. Furthermore, by using the **Poridhi Load Balancer**, your containerized Flask backend is safely accessible externally from any web browser.
