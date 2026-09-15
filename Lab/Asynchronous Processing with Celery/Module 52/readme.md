# Module 52 - Lab 6: Building a Flask API with Celery and Redis

## Overview

Building scalable background processing in production requires a clean, modular project architecture. This lab demonstrates how to structure a Flask application connected to Celery, using Dockerized Redis as both the message broker and result backend. You will implement asynchronous tasks for sending emails and generating PDF reports, then verify task queues and state polling using HTTP endpoints. By separating task declarations from application handlers, you ensure your backend remains maintainable and responsive.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/lab_6_final.drawio.svg" alt="Lab 2 Architecture Overview">
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
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/Task%20Lifecycle.drawio.svg" alt="Task Lifecycle Diagram">
</p>

- The `@celery.task` decorator registers functions with Celery:
  ```python
  @celery.task
  ```
- `.delay()` submits function arguments as messages to the broker:
  ```python
  task = send_email.delay(recipient)
  ```
- `celery.AsyncResult(task_id)` reconstructs handles to check task state (`PENDING`, `SUCCESS`, etc.) from Redis:
  ```python
  result = celery.AsyncResult(task_id)
  ```

---

## 2. Environment Setup & Prerequisites

1. Update system package index:
   ```bash
   sudo apt update
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/sudo-apt-update.png" alt="sudo apt update">
   </p>

2. Create project directory and virtual environment:
   ```bash
   mkdir flask-celery-lab && cd flask-celery-lab
   python3 -m venv venv
   source venv/bin/activate
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/create-project.png" alt="Create Project">
   </p>

3. Install required packages:
   ```bash
   pip install flask "celery[redis]"
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/install-dependencies.png" alt="Install Dependencies">
   </p>

4. Start Redis container via Docker:
   ```bash
   sudo systemctl stop redis-server 2>/dev/null || true
   docker rm -f redis-broker 2>/dev/null || true
   docker run -d --name redis-broker -p 6379:6379 redis:7-alpine
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/start-redis-docker.png" alt="Start Redis using Docker">
   </p>

   Check that Redis is running:
   ```bash
   docker ps
   ```

   Test Redis:
   ```bash
   docker exec redis-broker redis-cli ping
   ```

   Expected output:
   ```text
   PONG
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/redis-ping-test.png" alt="Redis Ping Test">
   </p>

   > **Troubleshooting — port already in use:** If port 6379 is occupied, check `sudo lsof -i :6379` and stop any host service with `sudo systemctl stop redis-server`.

5. Create application directory structure:
   ```bash
   mkdir -p app
   touch app/__init__.py
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/create-app-dir.png" alt="Create App Directory">
   </p>

   The project structure will be:
   ```text
   flask-celery-lab/
   │
   ├── venv/
   │
   └── app/
       ├── __init__.py
       ├── celery_app.py
       ├── tasks.py
       └── main.py
   ```

---

## 3. Step-by-Step Code Implementation

### Step 3.1: Configure Celery Instance (`app/celery_app.py`)

Create `app/celery_app.py` using the following command:

```bash
cat > app/celery_app.py <<'EOF'
from celery import Celery

celery = Celery(
    "flask_celery_lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/1",
    include=["app.tasks"],
)
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/config-celery-app.png" alt="Configure Celery App">
</p>

The `include=["app.tasks"]` ensures that Celery imports and registers the tasks defined in `app/tasks.py`.

---

### Step 3.2: Define Background Tasks (`app/tasks.py`)

Create `app/tasks.py` using the following command:

```bash
cat > app/tasks.py <<'EOF'
import time
from app.celery_app import celery


@celery.task
def send_email(recipient):
    time.sleep(5)
    return f"Email sent to {recipient}"


@celery.task
def generate_pdf(document_id):
    time.sleep(8)
    return f"PDF generated for document {document_id}"
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/create-celery-tasks.png" alt="Create Celery Tasks">
</p>

---

### Step 3.3: Submit Tasks from Flask (`app/main.py`)

Create `app/main.py` using the following command:

```bash
cat > app/main.py <<'EOF'
from flask import Flask, jsonify, request
from app.tasks import send_email
from app.celery_app import celery

app = Flask(__name__)


@app.route("/send-email", methods=["POST"])
def trigger_email():
    data = request.get_json(silent=True) or {}
    recipient = data.get("recipient")

    if not recipient:
        return jsonify({"error": "recipient is required"}), 400

    task = send_email.delay(recipient)

    return jsonify({"task_id": task.id}), 202


@app.route("/status/<task_id>", methods=["GET"])
def check_status(task_id):
    result = celery.AsyncResult(task_id)

    response = {
        "task_id": task_id,
        "state": result.state,
        "result": None
    }

    if result.successful():
        response["result"] = result.result
    elif result.failed():
        response["result"] = str(result.result)

    return jsonify(response)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/create-main-py.png" alt="Create Flask App">
</p>

---

## 4. Execution & Verification Scenarios

We will use three terminals.

### 1. Start Celery Worker (Terminal 1)

First go to the project directory:

```bash
cd ~/flask-celery-lab
source venv/bin/activate
```

Start the Celery worker:

```bash
celery -A app.celery_app.celery worker --loglevel=info
```

The worker should show:

```text
[tasks]
  . app.tasks.generate_pdf
  . app.tasks.send_email

Connected to redis://localhost:6379/0
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/start-celery-worker-final.png" alt="Celery Worker Start">
</p>

---

### 2. Start Flask Server (Terminal 2)

Open another terminal.

Go to the project directory and activate the virtual environment:

```bash
cd ~/flask-celery-lab
source venv/bin/activate
```

Start Flask:

```bash
python -m flask --app app.main run --host 0.0.0.0 --port 5001
```

You should see:

```text
* Running on http://127.0.0.1:5001
* Running on http://<your-ip>:5001
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/flask-server-running-new.png" alt="Flask Server">
</p>

---

### 3. Submit Task & Check Status (Terminal 3)

Open another terminal.

Make sure you are inside the project directory:

```bash
cd ~/flask-celery-lab
source venv/bin/activate
```

Send the request:

```bash
curl -X POST http://localhost:5001/send-email -H "Content-Type: application/json" -d '{"recipient":"user@example.com"}'
```

You should receive:

```json
{
  "task_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/send-email-request-final.png" alt="Send Email Request">
</p>

> **Important:** The `curl` command above is intentionally written in one line so you can copy-paste it directly into the terminal.

If you use multi-line `curl`, use a single `\` at the end of each line:

```bash
curl -X POST http://localhost:5001/send-email \
  -H "Content-Type: application/json" \
  -d '{"recipient":"user@example.com"}'
```

#### Check Task Status

Copy the `task_id` returned from the previous request:

```bash
curl http://localhost:5001/status/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Immediately after submitting the task, you may see:

```json
{
  "result": null,
  "state": "PENDING",
  "task_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

After approximately 5 seconds, check again:

```bash
curl http://localhost:5001/status/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

You should get:

```json
{
  "result": "Email sent to user@example.com",
  "state": "SUCCESS",
  "task_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2052/image/task-status-success-new.png" alt="Task Status Success">
</p>

---

## Conclusion

In this lab, you built a modular Flask and Celery application utilizing Docker for lightweight Redis infrastructure management. You implemented separated task definitions and asynchronous API routes to handle slow jobs seamlessly. This modular setup allows easy maintenance, straightforward unit testing, and effortless horizontal worker scaling in production environments.
