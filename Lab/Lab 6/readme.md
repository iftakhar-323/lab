# Lab 6: Building a Flask API with Celery and Redis

## Overview

Building scalable background processing in production requires a clean, modular project architecture. This lab demonstrates how to structure a Flask application connected to Celery, using Dockerized Redis as both the message broker and result backend. You will implement asynchronous tasks for sending emails and generating PDF reports, then verify task queues and state polling using HTTP endpoints. By separating task declarations from application handlers, you ensure your backend remains maintainable and responsive.

<p align="center">
  <img src="./images/lab_6_final.drawio.svg" alt="Lab 6 Architecture Overview" width="100%">
</p>

---

## 1. Core Concepts & Architecture

### Broker vs Result Backend

Celery requires two infrastructure roles:
1. **Message Broker**: Holds pending tasks published by the web server until picked up by a worker. Redis DB `0` is used for this role.
2. **Result Backend**: Stores task execution outcomes so state and return values can be queried via API endpoints. Redis DB `1` is used for this role.

### Task Lifecycle

A Celery task progresses through submission, queueing, execution, and state storage:

<p align="center">
  <img src="./images/task-lifecycle.gif" alt="Task lifecycle" width="100%">
</p>

- The `@celery.task` decorator registers functions with Celery.
- `.delay()` submits function arguments as messages to the broker.
- `celery.AsyncResult(task_id)` reconstructs handles to check task state (`PENDING`, `SUCCESS`, etc.) from Redis.

---

## 2. Environment Setup & Prerequisites

1. Update system package index:
   ```bash
   sudo apt update
   ```

2. Create project directory and virtual environment:
   ```bash
   mkdir flask-celery-lab && cd flask-celery-lab
   python3 -m venv venv
   source venv/bin/activate
   ```

3. Install required packages:
   ```bash
   pip install flask "celery[redis]"
   ```

4. Start Redis container via Docker:
   ```bash
   docker run -d --name redis-broker -p 6379:6379 redis:7-alpine
   redis-cli ping # Expected: PONG
   ```

   > **Troubleshooting — port already in use:** If port 6379 is occupied, check `sudo lsof -i :6379` and stop any host service with `sudo systemctl stop redis-server`.

5. Create application directory structure:
   ```bash
   mkdir app
   touch app/__init__.py app/celery_app.py app/tasks.py app/main.py
   ```

<p align="center">
  <img src="./images/project-structure.png" alt="Project structure created in the terminal" width="650">
</p>

---

## 3. Step-by-Step Code Implementation

### Step 3.1: Configure Celery Instance (`app/celery_app.py`)

Create `app/celery_app.py` using the following command:

```bash
cat << 'EOF' > app/celery_app.py
from celery import Celery

celery = Celery(
    "flask_celery_lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/1",
)
EOF
```

---

### Step 3.2: Define Background Tasks (`app/tasks.py`)

Create `app/tasks.py` using the following command:

```bash
cat << 'EOF' > app/tasks.py
import time
from app.celery_app import celery

@celery.task
def send_email(recipient):
    time.sleep(5)  # simulate slow email delivery
    return f"Email sent to {recipient}"

@celery.task
def generate_pdf(document_id):
    time.sleep(8)  # simulate slow PDF rendering
    return f"PDF generated for document {document_id}"
EOF
```

---

### Step 3.3: Submit Tasks from Flask (`app/main.py`)

Create `app/main.py` using the following command:

```bash
cat << 'EOF' > app/main.py
from flask import Flask, jsonify, request
from app.tasks import send_email
from app.celery_app import celery

app = Flask(__name__)

@app.route("/send-email", methods=["POST"])
def trigger_email():
    recipient = request.json.get("recipient")
    task = send_email.delay(recipient)
    return jsonify({"task_id": task.id}), 202

@app.route("/status/<task_id>", methods=["GET"])
def check_status(task_id):
    result = celery.AsyncResult(task_id)
    return jsonify({
        "task_id": task_id,
        "state": result.state,
        "result": result.result if result.ready() else None
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
EOF
```

---

## 4. Execution & Verification Scenarios

### 1. Start Celery Worker (Terminal 1)
```bash
source venv/bin/activate
celery -A app.celery_app.celery worker --loglevel=info
```

<p align="center">
  <img src="./images/celery-worker-start.png" alt="Celery worker starting up successfully" width="650">
</p>

---

### 2. Start Flask Server (Terminal 2)
```bash
source venv/bin/activate
python -m flask --app app.main run --host 0.0.0.0 --port 5001
```

<p align="center">
  <img src="./images/flask-server-running.png" alt="Flask development server running on port 5001" width="650">
</p>

---

### 3. Submit Task & Check Status (Terminal 3)

Submit task:
```bash
curl -X POST http://localhost:5001/send-email \
  -H "Content-Type: application/json" \
  -d '{"recipient": "user@example.com"}'
```

<p align="center">
  <img src="./images/send-email-request.png" alt="curl POST to /send-email returning a task_id JSON response" width="650">
</p>

Check task status:
```bash
curl http://localhost:5001/status/<TASK_ID>
```

Status output after 5 seconds:
```json
{"task_id":"<TASK_ID>","state":"SUCCESS","result":"Email sent to user@example.com"}
```

<p align="center">
  <img src="./images/task-status-success.png" alt="curl status check output showing SUCCESS" width="650">
</p>

---

### Broker Resilience Experiment

Stop Redis container during server execution:
```bash
docker stop redis-broker
```
Submit new task and observe error handling. Restore container:
```bash
docker start redis-broker
```

---

## Conclusion

In this lab, you built a modular Flask and Celery application utilizing Docker for lightweight Redis infrastructure management. You implemented separated task definitions and asynchronous API routes to handle slow jobs seamlessly. This modular setup allows easy maintenance, straightforward unit testing, and effortless horizontal worker scaling in production environments.