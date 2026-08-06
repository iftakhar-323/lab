# Lab 5: Asynchronous Processing with Celery

## Overview

A modern web API must respond to HTTP requests almost instantly to avoid blocking client threads and exhausting server resources. When an API endpoint triggers long-running tasks like sending emails, generating PDFs, or processing media, handling them synchronously degrades performance under heavy load. Celery addresses this bottleneck by offloading time-consuming operations to independent background worker processes using a message broker like Redis. In this lab, you will learn the core Celery architecture, trace task lifecycles, and build an asynchronous Flask application.

<p align="center">
  <img src="./image/lab_5_final.drawio.svg" alt="Lab 5 Architecture Overview" width="100%">
</p>

---

## 1. Core Concepts & Architecture

### Synchronous vs. Asynchronous Execution

- **Synchronous Execution**: The API server executes long-running operations directly inside the HTTP request handler. Client threads block until the task finishes, causing request queuing and high latency under traffic spikes.
- **Asynchronous Execution**: The API server delegates long operations to a background queue and responds immediately. Independent worker processes execute the tasks asynchronously.

#### Request Flow Comparison

**Without Celery (Synchronous):**
```text
Client Request → Flask API (Executes 10s Task) → Client Response (User waits 10s)
```

**With Celery (Asynchronous):**
```text
Client Request → Flask API (Enqueues Task to Redis) → Immediate Response (202 Accepted)
                               ↓
                        Celery Worker (Executes 10s Task in background)
```

---

### Core Architecture Components

| Component | Role & Responsibility |
|---|---|
| **Flask API** | Receives HTTP requests, creates background tasks, enqueues them to Redis, and returns immediate responses. |
| **Redis Broker** | Message queue (Redis DB 0) that stores enqueued tasks until a worker picks them up. |
| **Celery Worker** | Background process that continuously fetches and executes tasks from the Redis queue. |
| **Result Backend** | Storage backend (Redis DB 0) used to store and query completed task results by `task_id`. |

---

### Tracing the End-to-End Workflow

<p align="center">
  <img src="./image/End-to-End Workflow_final.drawio.svg" alt="End-to-End Workflow Overview" width="100%">
</p>

| Aspect | Synchronous Processing | Asynchronous (Celery) |
|---|---|---|
| **Request Latency** | Equal to task execution time | Near-instant (~ms) |
| **Server Thread State** | Blocked during execution | Free immediately for new requests |
| **Failure Isolation** | Task errors crash request thread | Failures isolated to worker process |
| **Result Retrieval** | Returned in HTTP response body | Queried via polling status endpoint |

---

### Task Offloading Guidelines

| Task Category | Recommended Model | Rationale |
|---|---|---|
| Form Input Validation | Synchronous | Fast, in-memory execution; user requires immediate validation. |
| Email & Notification Delivery | Asynchronous | Dependent on external SMTP latency and network stability. |
| Report & PDF Generation | Asynchronous | CPU & memory intensive; exceeds typical HTTP timeouts. |
| Database Record Lookup | Synchronous | Low-latency operation; queuing overhead is unjustified. |

---

## 2. Environment Setup & Prerequisites

1. **System & Environment Initialization**:
   ```bash
   sudo apt update -y
   sudo fuser -k 6379/tcp || true
   sudo fuser -k 5000/tcp || true
   ```

2. **Project Workspace & Virtualenv Setup**:
   ```bash
   mkdir -p celery-lab && cd celery-lab
   python3 -m venv venv
   source venv/bin/activate
   ```

3. **Dependency Installation**:
   ```bash
   pip install flask celery redis
   ```

   <p align="center">
     <img src="./image/pip-install-flask-celery-redis.png" alt="Install Dependencies" width="650">
   </p>

4. **Redis Infrastructure Setup**:
   ```bash
   sudo apt install -y redis-server
   sudo systemctl start redis-server
   redis-cli ping # Expected output: PONG
   ```

---

## 3. Step-by-Step Code Implementation

Create the unified application file `app.py`:

```bash
cat << 'EOF' > app.py
import time
from flask import Flask, jsonify, request
from celery import Celery

app = Flask(__name__)

# Celery Configuration: Redis serves as both broker and result backend
app.config['CELERY_BROKER_URL'] = 'redis://localhost:6379/0'
app.config['CELERY_RESULT_BACKEND'] = 'redis://localhost:6379/0'

celery = Celery(
    app.import_name,
    broker=app.config['CELERY_BROKER_URL'],
    backend=app.config['CELERY_RESULT_BACKEND']
)
celery.conf.update(app.config)


@celery.task(name='send_email_task')
def send_email_task(to_email):
    time.sleep(10)  # Simulates slow I/O operation (e.g. SMTP transmission)
    return f"Email sent to {to_email}"


@app.route('/send-email', methods=['POST'])
def send_email():
    data = request.get_json()
    to_email = data.get('to')

    if not to_email:
        return jsonify({"error": "to field is required"}), 400

    # Offload task to Celery queue
    task = send_email_task.delay(to_email)

    return jsonify({
        "message": "Email is being sent in the background",
        "task_id": task.id
    }), 202


@app.route('/task-status/<task_id>', methods=['GET'])
def task_status(task_id):
    task = send_email_task.AsyncResult(task_id)

    response = {
        "task_id": task_id,
        "status": task.status,
    }

    if task.status == "SUCCESS":
        response["result"] = task.result

    return jsonify(response)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
EOF
```

> **Explicit Task Naming**: `@celery.task(name='send_email_task')` prevents module import mismatch errors (`KeyError: unregistered task`) between Flask and Celery processes.

### API Endpoints Reference

| Endpoint | Method | Payload / Parameter | Description |
|---|---|---|---|
| `/send-email` | POST | `{"to": "user@example.com"}` | Enqueues email task; returns `202 Accepted` and `task_id`. |
| `/task-status/<task_id>` | GET | `task_id` (URL path) | Queries task execution state (`PENDING`, `SUCCESS`, `FAILURE`). |

---

## 4. Execution & Verification Scenarios

### Step 1: Start Flask API (Terminal 1)
```bash
cd celery-lab && source venv/bin/activate
python3 app.py
```
<p align="center">
  <img src="./image/start-flask-api.png" alt="Start Flask API" width="650">
</p>

### Step 2: Start Celery Worker (Terminal 2)
```bash
cd celery-lab && source venv/bin/activate
celery -A app.celery worker --loglevel=info
```
<p align="center">
  <img src="./image/start-celery-worker.png" alt="Start Celery Worker" width="650">
</p>

### Step 3: Trigger Background Task (Terminal 3)
```bash
curl -X POST http://127.0.0.1:5000/send-email \
  -H "Content-Type: application/json" \
  -d '{"to": "user@example.com"}'
```
<p align="center">
  <img src="./image/send-email-request.png" alt="Send POST Request" width="650">
</p>

### Step 4: Poll Task Status
```bash
curl http://127.0.0.1:5000/task-status/<TASK_ID>
```

- **Immediate Response (`PENDING`)**:
  ```json
  {"status": "PENDING", "task_id": "<TASK_ID>"}
  ```
- **Response After ~10s (`SUCCESS`)**:
  ```json
  {
    "result": "Email sent to user@example.com",
    "status": "SUCCESS",
    "task_id": "<TASK_ID>"
  }
  ```

---

### Broker Resilience Verification

1. Stop Celery worker (`Ctrl+C` in Terminal 2).
2. Submit new task via `POST /send-email`. Task is safely queued in Redis.
3. Restart Celery worker (`celery -A app.celery worker --loglevel=info`). Worker immediately picks up and processes the queued task.

---

## Conclusion

In this lab, you successfully decoupled task execution from HTTP request handling by integrating Celery and Redis into a Flask application. You observed how offloading slow operations improves API throughput and learned how to query background task results via polling endpoints. This architecture provides the foundation for scalable, high-performance web applications under heavy traffic.