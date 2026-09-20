# Lab 45: Flask–Citus Integration

In this lab, you will build a Python REST API using Flask and SQLAlchemy that connects to a distributed Citus database cluster. You will deploy a 3-node Citus cluster (1 Coordinator + 2 Workers) directly using Docker Compose within your Poridhi environment. Then, you will create endpoints to handle multi-tenant data, inserting and querying records across sharded tables, and expose the application publicly using the **Poridhi Load Balancer**.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/architecture_diagram.svg?v=4" alt="Flask and Citus Architecture" width="750">
</p>

---

## Objectives

- Deploy a multi-node Citus cluster (Coordinator + 2 Workers) using Docker Compose.
- Register worker nodes with the Citus coordinator and verify active cluster nodes.
- Configure a Python virtual environment with Flask, SQLAlchemy, and psycopg2.
- Define a multi-tenant database model and distribute the table using Citus's `create_distributed_table()` function.
- Build REST API endpoints to insert and fetch sharded tenant data.
- Expose port `5000` via the **Poridhi Load Balancer** and verify the API through public and local requests.

---

## Project Structure

```text
flask-citus-lab/
├── citus/
│   └── docker-compose.yml
└── app/
    ├── requirements.txt
    ├── database.py
    └── app.py
```

---

## Step 1: Deploy Citus Cluster using Docker Compose

First, create a dedicated directory for the Citus cluster and define the multi-node cluster using Docker Compose:

```bash
mkdir -p ~/flask-citus-lab/citus
cd ~/flask-citus-lab/citus
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/01_mkdir_citus.png" alt="Create Citus Directory" width="700">
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
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/02_create_docker_compose.png" alt="Create docker-compose.yml" width="700">
</p>

Start the containers:

```bash
docker compose up -d || docker-compose up -d
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/03_docker_compose_up.png" alt="Docker Compose Up Output" width="700">
</p>

Wait 10 seconds for the database engines to finish initial boot, then register the worker nodes with the coordinator:

```bash
sleep 10
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker1', 5432);"
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker2', 5432);"
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/04_citus_add_nodes.png" alt="Register Citus Worker Nodes" width="700">
</p>

---

## Step 2: Verify Active Citus Worker Nodes

Check that both worker nodes are connected and registered with the coordinator:

```bash
docker exec -it citus_coordinator psql -U citus -d citus -c "SELECT * FROM citus_get_active_worker_nodes();"
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/05_citus_active_workers.png" alt="Verify Active Citus Workers" width="700">
</p>

---

## Step 3: Set Up Application Environment & Dependencies

Navigate to your workspace directory, create the `app` folder, and configure the Python environment:

```bash
cd ~/flask-citus-lab
mkdir -p app && cd app

python3 -m venv venv
source venv/bin/activate
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/06_setup_app_venv.png" alt="Setup App Directory and Virtual Environment" width="700">
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
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/07_create_requirements.png" alt="Create requirements.txt" width="700">
</p>

Install the dependencies:

```bash
pip install -r requirements.txt
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/08_pip_install.png" alt="Pip Install Dependencies" width="700">
</p>

---

## Step 4: Implement Database Models and Distributed Tables

Create `flask-citus-lab/app/database.py`:

```bash
cat << 'EOF' > database.py
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy import text

db = SQLAlchemy()

class Event(db.Model):
    __tablename__ = 'events'

    # In Citus distributed tables, the distribution column must be part of the primary key
    id = db.Column(db.Integer, primary_key=True, autoincrement=True)
    tenant_id = db.Column(db.Integer, primary_key=True)
    event_name = db.Column(db.String(100), nullable=False)

def setup_database(app):
    with app.app_context():
        # Create base PostgreSQL table
        db.create_all()

        # Distribute the table across worker nodes based on tenant_id
        distribute_query = text("SELECT create_distributed_table('events', 'tenant_id');")
        try:
            db.session.execute(distribute_query)
            db.session.commit()
            print("Events table distributed successfully across Citus workers.")
        except Exception as e:
            db.session.rollback()
            print(f"Distribution status: {e}")
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/10_create_database_py.png" alt="Create database.py" width="700">
</p>

---

## Step 5: Implement the Flask REST API

Create `flask-citus-lab/app/app.py`:

```bash
cat << 'EOF' > app.py
import os
from flask import Flask, request, jsonify
from database import db, Event, setup_database

app = Flask(__name__)

# Connect to the local Citus coordinator container on port 5432
COORDINATOR_IP = os.environ.get("COORDINATOR_IP", "127.0.0.1")
app.config['SQLALCHEMY_DATABASE_URI'] = f'postgresql://citus:citus_password@{COORDINATOR_IP}:5432/citus'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

db.init_app(app)
setup_database(app)

@app.route('/', methods=['GET'])
def index():
    return jsonify({
        "status": "online",
        "service": "Flask-Citus Multi-Tenant API",
        "database": "Citus Distributed Cluster"
    }), 200

@app.route('/events', methods=['POST'])
def create_event():
    data = request.get_json()
    if not data or 'tenant_id' not in data or 'event_name' not in data:
        return jsonify({"error": "tenant_id and event_name are required"}), 400

    new_event = Event(
        tenant_id=data['tenant_id'],
        event_name=data['event_name']
    )
    db.session.add(new_event)
    db.session.commit()

    return jsonify({
        "message": "Event created",
        "id": new_event.id,
        "tenant_id": new_event.tenant_id,
        "event_name": new_event.event_name
    }), 201

@app.route('/events/<int:tenant_id>', methods=['GET'])
def get_events(tenant_id):
    # Query routed directly to the single worker holding this tenant_id shard
    events = Event.query.filter_by(tenant_id=tenant_id).all()
    result = [{"id": e.id, "tenant_id": e.tenant_id, "event_name": e.event_name} for e in events]
    return jsonify(result), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000)
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/11_create_app_py.png" alt="Create app.py" width="700">
</p>

---

## Step 6: Start the Flask Application

Start the Flask application in your terminal to initialize the distributed database tables and start listening on port `5000`:

```bash
cd ~/flask-citus-lab/app
source venv/bin/activate
python3 app.py
```

Expected Startup Output:

```text
Events table distributed successfully across Citus workers.
 * Serving Flask app 'app'
 * Debug mode: off
WARNING: This is a development server. Do not use it in a production deployment. Use a production WSGI server instead.
 * Running on all addresses (0.0.0.0)
 * Running on http://127.0.0.1:5000
 * Running on http://<YOUR_VM_IP>:5000
Press CTRL+C to quit
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/13_flask_run.png" alt="Flask Server Running Terminal Output" width="700">
</p>

> [!TIP]
> **Working with Terminal Tabs:**
> The Flask server is actively running in this terminal window. Keep this terminal running, and click the **`+`** icon next to `Terminal` in the top bar of your Poridhi workspace to open a **second terminal tab** for running subsequent commands (or you can run Flask in the background using `python3 app.py &`).

---

## Step 7: Expose Application via Poridhi Load Balancer

In the Poridhi cloud lab environment, the virtual machine runs inside a private isolated network. Now that your Flask application is actively running on port `5000`, expose it using the built-in **Poridhi Load Balancer**:

1. Open a **second terminal tab** by clicking the **`+`** icon next to `Terminal` in the top bar of your Poridhi interface.

2. In the new terminal tab, navigate to your application directory and activate the virtual environment:

   ```bash
   cd ~/flask-citus-lab/app
   source venv/bin/activate
   ```

3. Find the primary private IP of your Poridhi VM:

   ```bash
   hostname -I | awk '{print $1}'
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/09_hostname_ip.png" alt="Get Hostname Private IP" width="700">
   </p>

4. Open the **Load Balancer** modal from the Poridhi lab interface (the Cloud icon in the header or sidebar).
5. Enter the configuration:

   - **Enter IP**: Paste the IP address obtained above (e.g., `10.x.x.x`).
   - **Enter Port**: `5000`
   - Click **Expose**.

6. Poridhi will provision an edge load balancer and provide an active URL (e.g., `http://<lab-id>-5000.lb.poridhi.io`).

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/12_load_balancer_exposed.png" alt="Poridhi Load Balancer Exposed" width="700">
</p>

7. Open the generated Load Balancer URL in your web browser. Because the Flask server is already actively running on port `5000`, you will immediately receive the live JSON status:

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/14_load_balancer_browser.png" alt="Browser Health Check via Poridhi Load Balancer" width="700">
</p>

---

## Step 8: Verify API Endpoints via cURL

In your **second terminal tab** (where the virtual environment is already activated), test the multi-tenant API endpoints:

> [!NOTE]
> You can test directly using `http://localhost:5000` or replace it with your **Poridhi Load Balancer URL** (e.g., `http://<id>-5000.lb.poridhi.io`) to test requests over the public web.

**Scenario 1: Health check endpoint**

```bash
curl -X GET http://localhost:5000/
```

Expected Output:

```json
{
  "database": "Citus Distributed Cluster",
  "service": "Flask-Citus Multi-Tenant API",
  "status": "online"
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/14_load_balancer_browser.png" alt="Browser Health Check via Poridhi Load Balancer" width="700">
</p>

**Scenario 2: Create an event for Tenant 101**

```bash
curl -X POST http://localhost:5000/events \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 101, "event_name": "User Signup"}'
```

Expected Output:

```json
{
  "event_name": "User Signup",
  "id": 1,
  "message": "Event created",
  "tenant_id": 101
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/15_curl_post_tenant_101.png" alt="Create Event Tenant 101 cURL Output" width="700">
</p>

**Scenario 3: Create an event for Tenant 102**

```bash
curl -X POST http://localhost:5000/events \
     -H "Content-Type: application/json" \
     -d '{"tenant_id": 102, "event_name": "Item Purchased"}'
```

Expected Output:

```json
{
  "event_name": "Item Purchased",
  "id": 2,
  "message": "Event created",
  "tenant_id": 102
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/16_curl_post_tenant_102.png" alt="Create Event Tenant 102 cURL Output" width="700">
</p>

**Scenario 4: Retrieve events for Tenant 101**

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

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/17_curl_get_tenant_101.png" alt="Retrieve Tenant 101 Events cURL Output" width="700">
</p>

**Scenario 5: Request with missing required fields**

```bash
curl -X POST http://localhost:5000/events \
     -H "Content-Type: application/json" \
     -d '{"event_name": "Incomplete Event"}'
```

Expected Output:

```json
{
  "error": "tenant_id and event_name are required"
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/images/18_curl_missing_fields.png" alt="Missing Required Fields cURL Output" width="700">
</p>

---

## Conclusion

You have successfully deployed a multi-node Citus cluster using Docker Compose and integrated it with a Flask REST API. By distributing the `events` table across worker nodes using the `tenant_id` distribution column, the API achieves single-worker point-query routing and linear write scalability. Finally, by exposing port `5000` through the **Poridhi Load Balancer**, your containerized service is accessible externally from any web browser.
