# Lab 6: Building a Flask API with Celery and Redis

## Overview

Building scalable background processing in production requires a clean, modular project architecture. This lab demonstrates how to structure a Flask application connected to Celery, using Dockerized Redis as both the message broker and result backend. You will implement asynchronous tasks for sending emails and generating PDF reports, then verify task queues and state polling using HTTP endpoints. By separating task declarations from application handlers, you ensure your backend remains maintainable and responsive.

<p align="center">
  <img src="./images/lab_6_final.drawio.svg" alt="Lab 6 Architecture Overview" width="100%">
</p>

---

## Step-by-Step Implementation

### Step 1: Environment & Project Setup

Update the system package index:
```bash
sudo apt update
```

Create a project directory and a virtual environment:
```bash
mkdir flask-celery-lab
cd flask-celery-lab
python3 -m venv venv
```

Activate the virtual environment:
```bash
source venv/bin/activate
```

> **Note:** The virtual environment must be activated separately in **every new terminal tab**. If a terminal prompt does not show `(venv)` at the start, Python and pip commands will use the system Python instead of the project's virtual environment.

Install the required packages:
```bash
pip install flask "celery[redis]"
```

Start a Redis instance using Docker:
```bash
docker run -d --name redis-broker -p 6379:6379 redis:7-alpine
```

Confirm Redis is reachable:
```bash
redis-cli ping
# → PONG
```

> **Troubleshooting — port already in use:** If `docker run` fails with `Conflict. The container name "/redis-broker" is already in use`, a container with that name already exists. Either reuse it (`docker start redis-broker`) or remove it and create a fresh one:
> ```bash
> docker rm -f redis-broker
> docker run -d --name redis-broker -p 6379:6379 redis:7-alpine
> ```
> If instead you see `failed to bind host port 0.0.0.0:6379/tcp: address already in use`, check with `sudo lsof -i :6379` and stop any system redis service (`sudo systemctl stop redis-server`).

Create the project structure:
```bash
mkdir app
touch app/__init__.py app/celery_app.py app/tasks.py app/main.py
```

<p align="center">
  <img src="./images/project-structure.png" alt="Project structure created in the terminal" width="650">
</p>

---

### Step 2: Connecting Celery to Redis (`app/celery_app.py`)

Celery requires a message broker to hold pending tasks and a result backend to store task outcomes.

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

**Understanding the Code:**
The `Celery` constructor takes a name that identifies the application. The `broker` argument tells Celery where to publish and consume task messages. The `backend` argument tells Celery where to store task state and return values. Database `0` on Redis is used for the broker, and database `1` for the backend.

---

### Step 3: Defining Background Tasks (`app/tasks.py`)

A Celery task is a regular Python function decorated so that Celery can route calls to it through the broker.

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

**Understanding the Code:**
The `@celery.task` decorator registers a function with the Celery application. Once registered, the function gains methods such as `.delay()` and `.apply_async()`, which submit the function call as a message to the broker instead of executing it immediately in the current process.

---

### Step 4: Submitting Tasks from Flask (`app/main.py`)

The Flask API is responsible for accepting client requests and submitting tasks to Celery.

<p align="center">
  <img src="./images/task-lifecycle.gif" alt="Task lifecycle" width="100%">
</p>

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

**Understanding the Code:**
The `202 Accepted` status code is used because the request has been accepted for processing, but work is not yet complete. `celery.AsyncResult(task_id)` reconstructs a result handle from a task ID, allowing state to be queried from any process via the shared Redis backend.

---

### Step 5: Test and Verify

1. Start the Celery worker in **Terminal 1**:
   ```bash
   source venv/bin/activate
   celery -A app.celery_app.celery worker --loglevel=info
   ```

   <p align="center">
     <img src="./images/celery-worker-start.png" alt="Celery worker starting up successfully" width="650">
   </p>

2. Start the Flask application in **Terminal 2** (port 5001):
   ```bash
   source venv/bin/activate
   python -m flask --app app.main run --host 0.0.0.0 --port 5001
   ```

   <p align="center">
     <img src="./images/flask-server-running.png" alt="Flask development server running on port 5001" width="650">
   </p>

3. Submit a task from **Terminal 3**:
   ```bash
   curl -X POST http://localhost:5001/send-email \
     -H "Content-Type: application/json" \
     -d '{"recipient": "user@example.com"}'
   ```

   <p align="center">
     <img src="./images/send-email-request.png" alt="curl POST to /send-email returning a task_id JSON response" width="650">
   </p>

4. Check the task status using the returned ID:
   ```bash
   curl http://localhost:5001/status/<TASK_ID>
   ```

   Immediately after submission:
   ```json
   {"task_id":"05323108-90de-4cce-8acb-cb0c847f2cf6","state":"PENDING","result":null}
   ```

   After the 5-second simulated delay completes:
   ```json
   {"task_id":"05323108-90de-4cce-8acb-cb0c847f2cf6","state":"SUCCESS","result":"Email sent to user@example.com"}
   ```

   <p align="center">
     <img src="./images/task-status-success.png" alt="curl status check output showing SUCCESS" width="650">
   </p>

---

### Experiment: Broker Resilience

Stop the Redis container while the Flask server and Celery worker are still running:
```bash
docker stop redis-broker
```
Submit a new task using the `/send-email` endpoint and observe the result.

Restore Redis and confirm that queued tasks are processed:
```bash
docker start redis-broker
```

---

## Conclusion

In this lab, you built a modular Flask and Celery application utilizing Docker for lightweight Redis infrastructure management. You implemented separated task definitions and asynchronous API routes to handle slow jobs seamlessly. This modular setup allows easy maintenance, straightforward unit testing, and effortless horizontal worker scaling in production environments.