# Module 54 - Lab 8: Monitoring Celery with Flower

## Overview

Real-time visibility into background worker health, task queue depth, execution latency, and failure rates is essential for operating distributed applications. Flower provides a web-based management dashboard and REST API for Celery clusters by passively consuming worker event streams from Redis. In this lab, you will deploy Flower with SQLite state persistence, enforce HTTP basic authentication, and secure access behind an Nginx reverse proxy running at the network edge.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/lab_8_final_update.drawio.svg" alt="Lab 8 System Overview Diagram">
</p>

---

## 1. Core Concepts & Architecture

### Key Concepts

| Term | Meaning |
|---|---|
| Flower | A web-based monitor for Celery showing live task and worker state via event streams. |
| Event stream | Messages emitted on state changes (`task-received`, `task-started`, `task-succeeded`, etc.). |
| Broker URL | Redis connection string matching the worker's broker queue. |
| Workers view | Dashboard page listing connected worker processes, pool size, uptime, and load. |
| Tasks view | Searchable table of tasks with state, arguments, execution runtime, and retries. |
| REST API | Endpoints (`/api/tasks`, `/api/workers`) returning monitoring data in JSON format. |
| `--persistent` | Flag saving task and worker history to a local SQLite database (`flower.db`). |
| `--basic_auth` | Flag gating dashboard and API access behind username and password credentials. |

---

### Flower Monitoring Architecture

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/flower-monitoring-architecture_final.drawio.svg" alt="Flower Monitoring Architecture Diagram">
</p>

---

### Objectives & Target Structure

- Install Flower and connect to Redis DB 0.
- Persist task history with `--persistent=True --db=flower_data/flower.db`.
- Gate access using `--basic_auth` and Nginx reverse proxy HTTP basic auth.

```text
celery-retry-lab/
├── requirements.txt
├── celery_app.py
├── tasks.py
├── app.py
├── flower_data/
│   └── flower.db
├── scripts/
│   └── start_flower.sh
└── nginx/
    └── flower.conf
```

---

## 2. Environment Setup & Prerequisites

1. Check the existing environment:
   ```bash
   python3 --version
   docker --version
   ```

   Expected output:
   ```text
   Python 3.12.3
   Docker version 29.7.2, build a7dcaa6
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/check-environment.png" alt="Check Environment">
   </p>

2. Install system prerequisites (Nginx & apache2-utils for htpasswd):
   ```bash
   sudo apt update
   sudo apt install -y nginx apache2-utils python3-venv python3-pip curl
   ```

   Expected output:
   ```text
   Setting up nginx ...
   Setting up apache2-utils ...
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/install-system-prerequisites.png" alt="Install System Prerequisites">
   </p>

3. Start Redis container via Docker:
   ```bash
   docker rm -f redis 2>/dev/null || true
   docker run -d --name redis -p 6379:6379 redis:7-alpine
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/start-redis-docker.png" alt="Start Redis Container">
   </p>

   Verify Redis container is running:
   ```bash
   docker ps
   ```

   Expected output:
   ```text
   CONTAINER ID   IMAGE            COMMAND                  CREATED         STATUS         PORTS                    NAMES
   ...            redis:7-alpine   "docker-entrypoint.s…"   29 seconds ago  Up 28 seconds  0.0.0.0:6379->6379/tcp   redis
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/verify-redis-docker-ps.png" alt="Verify Redis Container Running">
   </p>

   Verify Redis connectivity:
   ```bash
   docker exec redis redis-cli ping
   ```

   Expected output:
   ```text
   PONG
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/verify-redis-ping.png" alt="Verify Redis Ping">
   </p>

4. Create project directory and virtual environment:
   ```bash
   mkdir -p ~/celery-retry-lab/scripts ~/celery-retry-lab/flower_data ~/celery-retry-lab/nginx ~/celery-retry-lab/logs
   cd ~/celery-retry-lab
   python3 -m venv venv
   source venv/bin/activate
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/create-project-venv.png" alt="Create Project Directory and Virtual Environment">
   </p>

---

## 3. Step-by-Step Code Implementation

### Step 3.1: Configure Dependencies (`requirements.txt`)

Create `requirements.txt` with Flask, Celery, Redis, and Flower dependencies:

```bash
cd ~/celery-retry-lab
source venv/bin/activate

cat << 'EOF' > requirements.txt
flask==3.0.3
celery==5.4.0
redis==5.0.8
flower==2.0.1
EOF

pip install -r requirements.txt
```

Expected output:
```text
Successfully installed celery-5.4.0 flask-3.0.3 flower-2.0.1 redis-5.0.8 ...
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/install-requirements.png" alt="Install Dependencies">
</p>

---

### Step 3.2: Celery Application Configuration (`celery_app.py`)

Create `celery_app.py` enabling worker event streams for Flower monitoring:

```bash
cat << 'EOF' > celery_app.py
import os
from celery import Celery

REDIS_BROKER_URL = os.getenv("CELERY_BROKER_URL", "redis://localhost:6379/0")
REDIS_RESULT_BACKEND = os.getenv("CELERY_RESULT_BACKEND", "redis://localhost:6379/1")

celery_app = Celery(
    "retry_lab",
    broker=REDIS_BROKER_URL,
    backend=REDIS_RESULT_BACKEND,
    include=["tasks"]
)

celery_app.conf.update(
    task_track_started=True,
    task_send_sent_event=True,
    worker_send_task_events=True,
    result_expires=3600,
    broker_connection_retry_on_startup=True
)

if __name__ == "__main__":
    celery_app.start()
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/create-celery-app.png" alt="Create Celery App Configuration">
</p>

---

### Step 3.3: Implement Celery Tasks (`tasks.py`)

Create `tasks.py` defining an asynchronous task simulating an upstream service:

```bash
cat << 'EOF' > tasks.py
import time
import random
import logging
from celery_app import celery_app

logger = logging.getLogger(__name__)

class UpstreamServiceError(Exception):
    """Raised when the upstream service call fails."""
    pass

@celery_app.task(
    bind=True,
    max_retries=3,
    autoretry_for=(UpstreamServiceError,),
    retry_backoff=2,
    retry_backoff_max=10,
    retry_jitter=True,
    soft_time_limit=15,
    time_limit=20
)
def call_upstream_service(self, payload, fail_probability=0.5):
    attempt = self.request.retries + 1
    logger.info(f"Executing call_upstream_service attempt {attempt} for {payload}")
    
    time.sleep(1)
    
    if random.random() < fail_probability:
        logger.warning(f"Upstream service failure on attempt {attempt}")
        raise UpstreamServiceError(f"upstream rejected payload '{payload}'")
    
    logger.info(f"Successfully processed {payload} on attempt {attempt}")
    return {
        "processed": True,
        "payload": payload,
        "attempts": attempt
    }
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/create-tasks.png" alt="Create Celery Tasks">
</p>

---

### Step 3.4: Build Flask API Server (`app.py`)

Create `app.py` exposing REST endpoints to submit and check tasks:

```bash
cat << 'EOF' > app.py
from flask import Flask, request, jsonify
from celery_app import celery_app
from tasks import call_upstream_service

app = Flask(__name__)

@app.route("/health", methods=["GET"])
def health_check():
    return jsonify({"status": "healthy"}), 200

@app.route("/tasks", methods=["POST"])
def submit_task():
    data = request.get_json() or {}
    payload = data.get("payload")
    fail_prob = data.get("fail_probability", 0.0)

    if not payload:
        return jsonify({"error": "field 'payload' is required"}), 400

    if not (0.0 <= float(fail_prob) <= 1.0):
        return jsonify({"error": "field 'fail_probability' must be between 0.0 and 1.0"}), 400

    task = call_upstream_service.delay(payload, float(fail_prob))
    return jsonify({
        "task_id": task.id,
        "state": task.state
    }), 202

@app.route("/tasks/<task_id>", methods=["GET"])
def get_task_status(task_id):
    result = celery_app.AsyncResult(task_id)
    response = {
        "task_id": task_id,
        "state": result.state
    }
    
    if result.state == "SUCCESS":
        response["result"] = result.result
    elif result.state == "FAILURE":
        response["error"] = str(result.result)
    elif result.state == "PENDING":
        response["detail"] = "task ID unknown or not yet started"
        
    return jsonify(response), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/create-app-py.png" alt="Create Flask Application">
</p>

---

### Step 3.5: Create Flower Startup Script (`scripts/start_flower.sh`)

Create `scripts/start_flower.sh` with persistent SQLite storage and basic auth:

```bash
mkdir -p scripts
cat << 'EOF' > scripts/start_flower.sh
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source venv/bin/activate

mkdir -p flower_data

celery -A celery_app.celery_app flower \
  --port=5555 \
  --persistent=True \
  --db=flower_data/flower.db \
  --basic_auth=admin:change-me-in-lab \
  --url_prefix=""
EOF

chmod +x scripts/start_flower.sh
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/create-start-flower-sh.png" alt="Create Flower Startup Script">
</p>

---

### Step 3.6: Configure Nginx Reverse Proxy (`nginx/flower.conf`)

1. Create Nginx basic auth credentials file using `htpasswd`:
   ```bash
   sudo htpasswd -b -c /etc/nginx/.flower_htpasswd admin change-me-in-lab
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/create-htpasswd.png" alt="Create Nginx Basic Auth Credentials">
   </p>

2. Create `nginx/flower.conf`:
   ```bash
   cat << 'EOF' > nginx/flower.conf
   server {
       listen 8080;
       server_name localhost;

       auth_basic "Flower dashboard";
       auth_basic_user_file /etc/nginx/.flower_htpasswd;

       location / {
           proxy_pass http://127.0.0.1:5555;
           proxy_set_header Host $host;
           proxy_set_header X-Real-IP $remote_addr;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
           proxy_set_header X-Forwarded-Proto $scheme;

           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection "upgrade";
       }
   }
   EOF
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/create-nginx-flower-conf.png" alt="Create Nginx Flower Configuration">
   </p>

3. Enable Nginx site configuration, test syntax, and restart Nginx:
   ```bash
   sudo ln -sf "$(pwd)/nginx/flower.conf" /etc/nginx/sites-enabled/flower.conf
   sudo nginx -t
   sudo systemctl restart nginx
   ```

   Expected output:
   ```text
   nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
   nginx: configuration file /etc/nginx/nginx.conf test is successful
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/nginx-flower-conf.png" alt="Enable Nginx Site and Restart">
   </p>

   Verify Nginx is active and running:
   ```bash
   sudo systemctl status nginx --no-pager
   ```

   Expected output:
   ```text
   Active: active (running)
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/verify-nginx-status.png" alt="Verify Nginx Status Running">
   </p>

4. Verify project structure:
   ```bash
   ls -la celery_app.py tasks.py app.py requirements.txt scripts/start_flower.sh nginx/flower.conf
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/check-all-files.png" alt="Verify Project Files Structure">
   </p>

---

## 4. Execution & Verification Workflow

To execute and verify all components, use separate terminal windows.

### 1. Start Celery Worker (Terminal 1)

Navigate to project directory and start Celery worker with event capture enabled (`-E`):

```bash
cd ~/celery-retry-lab
source venv/bin/activate
celery -A celery_app.celery_app worker --loglevel=info -E
```

Expected output:
```text
[tasks]
  . tasks.call_upstream_service

[2026-09-08 00:00:00,000: INFO/MainProcess] celery@... ready.
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/celery-worker-running.png" alt="Celery Worker Running with Events Terminal Output">
</p>

**Keep this terminal open.**

---

### 2. Start Flower Dashboard (Terminal 2)

Open a second terminal and launch the Flower monitoring service:

```bash
cd ~/celery-retry-lab
./scripts/start_flower.sh
```

Expected output:
```text
[I ... command:168] Visit me at http://0.0.0.0:5555:
[I ... command:173] Broker: redis://localhost:6379/0
[I ... command:174] Registered tasks: ['tasks.call_upstream_service']
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/start-flower.png" alt="Flower Startup Terminal Output">
</p>

**Keep this terminal open.**

---

### 3. Start Flask API Server (Terminal 3)

Open a third terminal and run the Flask server:

```bash
cd ~/celery-retry-lab
source venv/bin/activate
python app.py
```

Expected output:
```text
* Running on http://127.0.0.1:5000
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/flask-server-startup.png" alt="Flask Server Startup Terminal Output">
</p>

**Keep this terminal open.**

---

### 4. Verification & Monitoring Workflow (Terminal 4)

Open a fourth terminal to execute the end-to-end verification flow, monitor task executions on the **Flower Web Dashboard**, and validate API security and persistence.

#### Step 4.1: Submit Background Tasks via Flask API

Submit a task guaranteed to succeed (`fail_probability = 0.0`) to trigger Celery worker processing and generate execution records:

```bash
curl -s -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"payload": "order-2001", "fail_probability": 0.0}'
```

Expected output:
```json
{"state":"PENDING","task_id":"8ea27faa-b241-416f-ac55-b840df953d26"}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/scenario-1-submit-task.png" alt="Submit Background Task via Flask API">
</p>

*(Optional) Submit an additional task with a different payload to observe multiple records in Flower:*
```bash
curl -s -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"payload": "order-2002", "fail_probability": 0.0}'
```

---

#### Step 4.2: Expose Flower Web Dashboard via Poridhi Load Balancer

Flower provides a real-time web-based monitoring interface for your Celery cluster. In the Poridhi cloud lab environment, the virtual machine runs inside a private isolated network. To access the Flower dashboard securely in your web browser, expose port `8080` (where Nginx reverse proxy is running) using the built-in **Poridhi Load Balancer**:

1. **Retrieve VM Private IP & Verify Nginx Port**:
   Retrieve the private IP address of your VM:
   ```bash
   hostname -I
   ```

   Output (example):
   ```text
   10.61.9.216 100.80.124.118 172.17.0.1
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/poridhi-vm-ip-check.png" alt="Retrieve VM Private IP from Terminal Output">
   </p>

   > [!NOTE]
   > When running `hostname -I`, the terminal returns multiple network interface IPs (for example: `10.61.9.216 100.80.124.118 172.17.0.1`). The **first IP address** (`10.61.9.216` or your specific `10.x.x.x` address) is the VM's primary private IP assigned to `eth0`. The subsequent IPs belong to internal overlay and container bridges. Copy **only the first IP address** (highlighted in the screenshot above) to use in the Poridhi Load Balancer configuration.

   Confirm Nginx is actively listening on port `8080`:
   ```bash
   sudo ss -lntp | grep 8080
   ```

   Expected output:
   ```text
   LISTEN 0      511          0.0.0.0:8080        0.0.0.0:*    users:(("nginx",pid=...,fd=...)...)
   ```

2. **Configure Poridhi Load Balancer**:
   - Open the **Load Balancer** panel from the left sidebar of the Poridhi lab interface (the Cloud icon).
   - In the **1. Enter IP** field, enter your VM's private IP address retrieved from the previous step.
   - In the **1. Enter Port** field, enter the Nginx proxy port: `8080`.

   > [!TIP]
   > The IP `10.61.9.216` shown in the screenshot below is an example from our lab session. Always enter your own VM's private IP.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/poridhi-load-balancer-config.png" alt="Poridhi Load Balancer Configuration">
</p>

3. **Expose and Retrieve Public URL**:
   - Click the purple **Expose** button.
   - Poridhi instantly provisions an edge load balancer and assigns a public URL (e.g., `http://6a0c8515950c78444441b86c-f2444e7f.lb.poridhi.io`).

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/poridhi-load-balancer-exposed.png" alt="Poridhi Load Balancer Exposed Endpoint">
</p>

4. **Access the Dashboard & Authenticate**:
   - Click on the generated URL to open the Flower dashboard in a new browser tab.
   - When prompted by the HTTP Basic Authentication modal, enter the credentials configured in Step 3.6:
     - **Username:** `admin`
     - **Password:** `change-me-in-lab`

---

#### Step 4.3: Monitor Connected Workers via Flower Dashboard (Workers View)

Once authenticated, Flower opens the main **Dashboard** displaying the connected Celery worker nodes:

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/flower-dashboard-workers.png" alt="Flower Web Dashboard - Workers Overview">
</p>

**Key Metrics & Elements to Inspect:**
- **Worker Name**: Identified as `celery@d2528143c56b4a90` (matching your active Celery worker node).
- **Status**: Displayed as **True** (Online and accepting tasks).
- **Task Counters**:
  - **Active**: Current executing tasks (`0` when idle).
  - **Processed**: Total number of tasks accepted and completed (`2`).
  - **Failed**: Total number of unhandled task failures (`0`).
  - **Succeeded**: Number of successfully executed tasks (`2`).
  - **Retried**: Number of retry operations executed (`0`).
- **Load Average**: System load metrics across 1, 5, and 15-minute intervals (`0.03, 0.06, 0.04`).

---

#### Step 4.4: Query & Inspect Task Records via Flower Dashboard (Tasks View)

To view, search, and filter execution records across the Celery cluster:

1. Click on the **Tasks** tab in the top navigation bar of the Flower dashboard (or navigate to `https://<YOUR_URL>/tasks`).

2. **Query Records & Filtering**:
   - **Filter by Task Name**: Enter `tasks.call_upstream_service` in the search filter to display only relevant task records.
   - **Filter by State**: Filter records by execution state (e.g., `SUCCESS`, `FAILURE`, `RETRY`).

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/flower-dashboard-tasks-query.png" alt="Flower Web Dashboard - Tasks View Query Records">
</p>

3. **Inspect Task Query Records Table**:
   Examine the real-time execution records for all submitted tasks:

   | Column | Record 1 (`order-2002`) | Record 2 (`order-2001`) | Description |
   |---|---|---|---|
   | **Name** | `tasks.call_upstream_service` | `tasks.call_upstream_service` | Fully qualified Celery task function |
   | **UUID** | `955d2f24-8340-4606-b631-2286f8cd18da` | `38e7fcc3-7dc7-42a2-9e8a-fdd663e80684` | Unique execution identifier |
   | **State** | `SUCCESS` | `SUCCESS` | Final execution state (green badge) |
   | **args** | `('order-2002', 0.0)` | `('order-2001', 0.0)` | Arguments dispatched to the task |
   | **kwargs** | `{}` | `{}` | Keyword arguments |
   | **Result** | `{'processed': True, 'payload': 'order-2002', 'attempts': 1}` | `{'processed': True, 'payload': 'order-2001', 'attempts': 1}` | Return dictionary produced by worker |
   | **Runtime** | `1.01` | `1.02` | Total execution duration (seconds) |
   | **Worker** | `celery@d2528143c56b4a90` | `celery@d2528143c56b4a90` | Worker node that processed the task |

---

#### Step 4.5: Inspect Detailed Task Execution Record (Task Detail View)

Click directly on any **UUID** link (e.g., `955d2f24-8340-4606-b631-2286f8cd18da`) in the Tasks table to open the full task detail view:

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/flower-task-detail-record.png" alt="Flower Web Dashboard - Task Detail View">
</p>

**Query Record Details:**
- **Execution Metadata**: Task name (`tasks.call_upstream_service`), UUID, status (`SUCCESS`), worker node (`celery@d2528143c56b4a90`), and routing key (`celery`).
- **Timing Analysis**: Received timestamp (`2026-09-10 12:19:40.380 UTC`), Started timestamp, Succeeded timestamp, and precise runtime duration (`1.0066s`).
- **Parameters & Return Data**: Full input arguments `('order-2002', 0.0)` and structured JSON return payload `{'processed': True, 'payload': 'order-2002', 'attempts': 1}`.
- **Retries & Exceptions**: Tracks retry count (`0` for first-attempt success) and confirms zero unhandled exceptions.

---

#### Step 4.6: Headless Verification via Flower REST API (Terminal 4)

In automated environments or command-line workflows, Flower exposes REST API endpoints to inspect workers and task query records programmatically.

1. **Query Connected Worker Status**:
   ```bash
   curl -s -u admin:change-me-in-lab http://localhost:5555/api/workers | python3 -m json.tool
   ```

   Expected output:
   ```json
   {
       "celery@5a6b908333a84036": {
           "stats": {
               "total": {},
               "pid": 2460,
               "clock": "15",
               "uptime": 12,
               "pool": {
                   "implementation": "celery.concurrency.prefork:TaskPool",
                   "max-concurrency": 2,
                   "processes": [
                       2462,
                       2463
                   ]
               }
           }
       }
   }
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/scenario-2-flower-workers.png" alt="Inspect Worker Status via Flower REST API">
   </p>

2. **Query Task Records & Metadata via REST API**:
   ```bash
   curl -s -u admin:change-me-in-lab "http://localhost:5555/api/tasks?limit=1" | python3 -m json.tool
   ```

   Expected output:
   ```json
   {
       "8ea27faa-b241-416f-ac55-b840df953d26": {
           "uuid": "8ea27faa-b241-416f-ac55-b840df953d26",
           "name": "tasks.call_upstream_service",
           "state": "SUCCESS",
           "received": 1788810853.7961712,
           "sent": 1788810853.7892377,
           "started": 1788810853.8052475,
           "rejected": null
       }
   }
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/scenario-3-flower-tasks.png" alt="Inspect Task History via Flower REST API">
   </p>

---

#### Step 4.7: Test Authentication Controls & Reverse Proxy

1. Verify Flower direct port (`5555`) rejects unauthenticated requests:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:5555/api/workers
   ```

   Expected output:
   ```text
   401
   ```

2. Verify Nginx edge proxy (`port 8080`) blocks unauthenticated access:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/
   ```

   Expected output:
   ```text
   401
   ```

3. Verify Nginx edge proxy forwards authenticated requests:
   ```bash
   curl -s -o /dev/null -w "%{http_code}\n" -u admin:change-me-in-lab http://localhost:8080/api/workers
   ```

   Expected output:
   ```text
   200
   ```

---

#### Step 4.8: Verify Flower Database State Persistence (`flower.db`)

Confirm that the SQLite persistence database file exists and retains monitoring history across service restarts:

```bash
ls -lh ~/celery-retry-lab/flower_data/flower.db
```

Expected output:
```text
-rw-rw-r-- 1 poridhian poridhian 16K Sep 7 19:53 /home/poridhian/celery-retry-lab/flower_data/flower.db
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2054/image/scenario-4-5-6-verification.png" alt="Authentication and Persistence Verification Output">
</p>

---

## Conclusion

In this lab, you successfully integrated Flower real-time monitoring into your Celery task processing stack. You enabled persistent state retention across service restarts using SQLite and configured WebSocket support for live metrics. By placing Flower behind an Nginx reverse proxy with HTTP basic authentication, you established network edge security while maintaining complete operational visibility into your distributed background system.
