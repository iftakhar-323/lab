# Lab 5: Asynchronous Processing with Celery

## Overview

A modern web API must respond to HTTP requests almost instantly to avoid blocking client threads and exhausting server resources. When an API endpoint triggers long-running tasks like sending emails, generating PDFs, or processing media, handling them synchronously degrades performance under heavy load. Celery addresses this bottleneck by offloading time-consuming operations to independent background worker processes using a message broker like Redis. In this lab, you will learn the core Celery architecture, trace task lifecycles, and build an asynchronous Flask application.

<p align="center">
  <img src="./image/lab_5_final.drawio.svg" alt="Lab 5 Architecture Overview" width="100%">
</p>

---

## Step-by-Step Implementation

### Step 1: Environment Setup

1. Update packages and clear existing services on default ports (`6379`, `5000`):
   ```bash
   sudo apt update -y
   sudo fuser -k 6379/tcp || true
   sudo fuser -k 5000/tcp || true
   ```

2. Create project directory and virtual environment:
   ```bash
   mkdir -p celery-lab && cd celery-lab
   python3 -m venv venv
   source venv/bin/activate
   ```

3. Install requirements and launch Redis server:
   ```bash
   pip install flask celery redis
   sudo apt install -y redis-server
   sudo systemctl start redis-server
   redis-cli ping # Should return PONG
   ```

---

### Step 2: Understanding Task Execution Flow

#### Synchronous Flow (Without Celery)
The client waits while the API executes the task inline, keeping the request handler blocked until completion.

<p align="center">
  <img src="./image/without-celery-synchronous.gif" alt="Without Celery (Synchronous) request flow" width="100%">
</p>

#### Asynchronous Flow (With Celery)
The API queues the task in Redis and immediately returns an HTTP 202 response. Celery workers fetch and process the task in the background.

<p align="center">
  <img src="./image/with-celery-asynchronous.gif" alt="With Celery (Asynchronous) request flow" width="100%">
</p>

---

### Step 3: Create Application (`app.py`)

Create `app.py` inside `celery-lab`:

```python
import time
from flask import Flask, jsonify, request
from celery import Celery

app = Flask(__name__)

# Configure Redis as broker and result backend
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
    time.sleep(10)  # Simulate slow email service
    return f"Email sent to {to_email}"

@app.route('/send-email', methods=['POST'])
def send_email():
    data = request.get_json() or {}
    to_email = data.get('to')
    if not to_email:
        return jsonify({"error": "to field is required"}), 400

    task = send_email_task.delay(to_email)
    return jsonify({
        "message": "Email is being sent in the background",
        "task_id": task.id
    }), 202

@app.route('/task-status/<task_id>', methods=['GET'])
def task_status(task_id):
    task = send_email_task.AsyncResult(task_id)
    response = {"task_id": task_id, "status": task.status}
    if task.status == "SUCCESS":
        response["result"] = task.result
    return jsonify(response)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
```

---

### Step 4: Run Services and Verify

1. **Start Flask API** (Terminal 1):
   ```bash
   python3 app.py
   ```

2. **Start Celery Worker** (Terminal 2):
   ```bash
   celery -A app.celery worker --loglevel=info
   ```

3. **Submit Task & Check Status** (Terminal 3):
   ```bash
   # Submit asynchronous task
   curl -X POST http://127.0.0.1:5000/send-email \
     -H "Content-Type: application/json" \
     -d '{"to": "user@example.com"}'

   # Check task status using returned task_id
   curl http://127.0.0.1:5000/task-status/<TASK_ID>
   ```

<p align="center">
  <img src="./image/send-email-request.png" alt="Send POST request" width="650">
</p>

---

## Conclusion

In this lab, you successfully decoupled task execution from HTTP request handling by integrating Celery and Redis into a Flask application. You observed how offloading slow operations improves API throughput and learned how to query background task results via polling endpoints. This architecture provides the foundation for scalable, high-performance web applications under heavy traffic.