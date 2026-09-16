# Module 53 - Lab 7: Celery Task Retries, Timeouts, and Task Status Tracking

## Overview

Distributed background tasks frequently encounter external service outages, network latency, or unexpected execution delays. To prevent silent failures and resource exhaustion, systems must implement automatic retries with exponential backoff, enforce soft and hard timeouts, and log every state transition. In this lab, you will build a resilient Flask and Celery pipeline backed by Redis that handles transient upstream errors, tracks lifecycle states, and exposes status diagnostics.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/lab_7_final.drawio.svg" alt="Lab 3 System Overview Diagram">
</p>

---

## 1. Core Concepts & Architecture

### Key Concepts

| Term | Meaning |
|---|---|
| PENDING | Task ID exists in the backend but no worker has picked it up yet, or the ID is unknown. |
| STARTED | A worker has picked up the task and begun execution. Requires `task_track_started=True`. |
| RETRY | The task raised an exception, caught by `autoretry_for` or explicit `self.retry()`, and rescheduled. |
| SUCCESS | Task function returned without raising an exception; result stored in result backend. |
| FAILURE | Task exhausted its retry budget or raised an unhandled exception. |
| `max_retries` | Upper bound on retry attempts before marking task as FAILURE. |
| `retry_backoff` | When `True`, delay before each retry grows exponentially. |
| `retry_backoff_max` | Ceiling on the backoff delay in seconds regardless of retry count. |
| `retry_jitter` | Adds random variance to backoff delay preventing synchronized retry spikes. |
| `soft_time_limit` | Seconds after which Celery raises `SoftTimeLimitExceeded` inside task allowing cleanup. |
| `time_limit` | Seconds after which Celery kills worker process running the task without cleanup. |

### Task Lifecycle Flow

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/Task%20Lifecycle.drawio.svg" alt="Task Lifecycle Diagram">
</p>

### Target Directory Structure

```text
celery-retry-lab/
├── requirements.txt
├── celery_app.py
├── tasks.py
├── app.py
└── logs/
    └── worker.log
```

---

## 2. Environment Setup & Prerequisites

1. Check the environment:
   ```bash
   python3 --version
   docker --version
   ```

   Expected output:
   ```text
   Python 3.12.x
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/check-environment.png" alt="Check Environment">
   </p>

2. Install required system packages:
   ```bash
   sudo apt update
   sudo apt install -y python3 python3-venv python3-pip curl
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/install-python-tools.png" alt="Install Python Tools">
   </p>

3. Start Redis container via Docker:
   ```bash
   docker rm -f redis 2>/dev/null || true
   docker run -d --name redis -p 6379:6379 redis:7-alpine
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/start-redis-docker.png" alt="Start Redis with Docker">
   </p>

   Verify the container is running:
   ```bash
   docker ps
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/verify-redis-docker-ps.png" alt="Verify Redis Container">
   </p>

   Verify Redis responsiveness:
   ```bash
   docker exec redis redis-cli ping
   ```

   Expected output:
   ```text
   PONG
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/verify-redis-ping.png" alt="Verify Redis Ping">
   </p>

4. Create project directory and virtual environment:
   ```bash
   mkdir -p ~/celery-retry-lab/logs
   cd ~/celery-retry-lab
   python3 -m venv venv
   source venv/bin/activate
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/create-project-venv.png" alt="Create Project and Virtual Environment">
   </p>

5. Create `requirements.txt` and install dependencies:
   ```bash
   cd ~/celery-retry-lab
   source venv/bin/activate

   cat << 'EOF' > requirements.txt
   flask==3.0.3
   celery==5.4.0
   redis==5.0.8
   EOF

   pip install -r requirements.txt
   ```

   <p align="center">
     <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/install-requirements.png" alt="Install Requirements">
   </p>

---

## 3. Step-by-Step Code Implementation

### Step 3.1: Configure Celery Application (`celery_app.py`)

Create `celery_app.py` using the following command:

```bash
cat > celery_app.py <<'EOF'
import logging
from celery import Celery
from celery.signals import task_prerun, task_postrun, task_failure, task_retry

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler("logs/worker.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger("celery_retry_lab")

celery_app = Celery(
    "celery_retry_lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/1",
    include=["tasks"],
)

celery_app.conf.update(
    task_track_started=True,
    result_extended=True,
    task_serializer="json",
    result_serializer="json",
    accept_content=["json"],
    timezone="UTC",
    enable_utc=True,
)


@task_prerun.connect
def log_task_prerun(task_id, task, *args, **kwargs):
    logger.info("task_id=%s name=%s state=STARTED", task_id, task.name)


@task_postrun.connect
def log_task_postrun(task_id, task, retval=None, state=None, *args, **kwargs):
    logger.info("task_id=%s name=%s state=%s result=%s", task_id, task.name, state, retval)


@task_retry.connect
def log_task_retry(request, reason, **kwargs):
    logger.warning("task_id=%s state=RETRY reason=%s", request.id, reason)


@task_failure.connect
def log_task_failure(task_id, exception, *args, **kwargs):
    logger.error("task_id=%s state=FAILURE exception=%s", task_id, repr(exception))
EOF
```

> **Note:** `include=["tasks"]` is essential so that the Celery worker imports and registers the `call_upstream_service` task.

---

### Step 3.2: Implement Retrying Task (`tasks.py`)

Create `tasks.py` using the following command:

```bash
cat > tasks.py <<'EOF'
import logging
import random
import time

from celery.exceptions import SoftTimeLimitExceeded
from celery_app import celery_app

logger = logging.getLogger("celery_retry_lab")


class UpstreamServiceError(Exception):
    """Raised when the simulated upstream call fails."""


@celery_app.task(
    bind=True,
    autoretry_for=(UpstreamServiceError,),
    retry_backoff=True,
    retry_backoff_max=30,
    retry_jitter=True,
    max_retries=4,
    soft_time_limit=8,
    time_limit=12,
)
def call_upstream_service(self, payload: str, fail_probability: float = 0.7):
    """Simulate an unreliable upstream call that succeeds, fails, or hangs."""
    try:
        logger.info(
            "task_id=%s attempt=%s payload=%s", self.request.id, self.request.retries + 1, payload
        )
        time.sleep(1)

        if random.random() < fail_probability:
            raise UpstreamServiceError(f"upstream rejected payload '{payload}'")

        return {"payload": payload, "processed": True, "attempts": self.request.retries + 1}

    except SoftTimeLimitExceeded:
        logger.error("task_id=%s exceeded soft_time_limit, aborting cleanly", self.request.id)
        raise

    except UpstreamServiceError as exc:
        logger.warning(
            "task_id=%s attempt=%s failed: %s", self.request.id, self.request.retries + 1, exc
        )
        raise
EOF
```

---

### Step 3.3: Build Flask API (`app.py`)

Create `app.py` using the following command:

```bash
cat > app.py <<'EOF'
import logging

from celery.result import AsyncResult
from flask import Flask, jsonify, request

from celery_app import celery_app
from tasks import call_upstream_service

app = Flask(__name__)
logger = logging.getLogger("celery_retry_lab")


@app.post("/tasks")
def submit_task():
    body = request.get_json(silent=True) or {}
    payload = body.get("payload")
    fail_probability = body.get("fail_probability", 0.7)

    if not payload:
        return jsonify({"error": "field 'payload' is required"}), 400

    try:
        fail_probability = float(fail_probability)
        if not (0.0 <= fail_probability <= 1.0):
            raise ValueError
    except (ValueError, TypeError):
        return jsonify({"error": "field 'fail_probability' must be between 0.0 and 1.0"}), 400

    async_result = call_upstream_service.apply_async(
        args=[payload], kwargs={"fail_probability": fail_probability}
    )
    logger.info("task_id=%s state=PENDING submitted via API", async_result.id)

    return jsonify({"task_id": async_result.id, "state": "PENDING"}), 202


@app.get("/tasks/<task_id>")
def get_task_status(task_id):
    result = AsyncResult(task_id, app=celery_app)

    response = {"task_id": task_id, "state": result.state}

    if result.state == "PENDING":
        response["detail"] = "task ID unknown or not yet started"
    elif result.state == "STARTED":
        response["detail"] = "task is currently executing"
    elif result.state == "RETRY":
        response["detail"] = "task failed and is scheduled for retry"
    elif result.state == "SUCCESS":
        response["result"] = result.result
    elif result.state == "FAILURE":
        response["error"] = str(result.result)

    return jsonify(response), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF
```

---

### Step 3.4: Verify Files and Task Registration

Check all created files:

```bash
ls -l celery_app.py tasks.py app.py requirements.txt
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/check-all-files.png" alt="Check All Files">
</p>

Verify Celery task registration:

```bash
python -c "from celery_app import celery_app; print(sorted(celery_app.tasks.keys()))"
```

Expected output includes `tasks.call_upstream_service`:

```text
tasks.call_upstream_service
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/verify-task-registration.png" alt="Verify Task Registration">
</p>

---

## 4. Execution & Verification Scenarios

We will use three terminals.

### 1. Start Celery Worker (Terminal 1)

First go to the project directory:

```bash
cd ~/celery-retry-lab
source venv/bin/activate
```

Start the Celery worker:

```bash
celery -A celery_app.celery_app worker --loglevel=info
```

The worker should show:

```text
[tasks]
  . tasks.call_upstream_service

celery@... ready.
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/celery-worker-startup-new.png" alt="Celery Worker Startup">
</p>

**Keep this terminal open.**

---

### 2. Start Flask Server (Terminal 2)

Open another terminal:

```bash
cd ~/celery-retry-lab
source venv/bin/activate
```

Start Flask:

```bash
python app.py
```

You should see:

```text
* Running on http://127.0.0.1:5000
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/flask-server-startup-new.png" alt="Flask Server Startup">
</p>

**Keep this terminal open.**

---

### 3. API Verification Scenarios (Terminal 3)

Open a third terminal:

```bash
cd ~/celery-retry-lab
source venv/bin/activate
```

#### Scenario 1: Guaranteed Success (`fail_probability = 0.0`)

Submit a task:

```bash
RESPONSE=$(curl -s -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"payload":"order-1001","fail_probability":0.0}')

echo "$RESPONSE"
```

Expected:

```json
{"state":"PENDING","task_id":"..."}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-1-submit-task.png" alt="Submit Task Scenario 1">
</p>

Check task status:

```bash
TASK_ID=$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["task_id"])')
curl -s http://localhost:5000/tasks/$TASK_ID
```

Expected final state:

```json
{
  "result": {
    "attempts": 1,
    "payload": "order-1001",
    "processed": true
  },
  "state": "SUCCESS",
  "task_id": "..."
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-1-guaranteed-success-new.png" alt="Scenario 1 Guaranteed Success Terminal Output">
</p>

---

#### Scenario 2: Retry Then Success (`fail_probability = 0.7`)

Submit a retrying task:

```bash
RESPONSE=$(curl -s -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"payload":"order-1002","fail_probability":0.7}')

echo "$RESPONSE"
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-2-submit-task.png" alt="Scenario 2 Submit Task">
</p>

Check task status:

```bash
TASK_ID=$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["task_id"])')
curl -s http://localhost:5000/tasks/$TASK_ID
```

Status output showing eventual success after retries:

```json
{
  "state": "SUCCESS",
  "result": {
    "attempts": 2,
    "payload": "order-1002",
    "processed": true
  }
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-2-retry-success.png" alt="Scenario 2 Retry Then Success Terminal Output">
</p>

---

#### Scenario 3: Retries Exhausted (`fail_probability = 1.0`)

Submit a task that will exhaust all retries:

```bash
RESPONSE=$(curl -s -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"payload":"order-1003","fail_probability":1.0}')

TASK_ID=$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["task_id"])')
```

Check status after retries are exhausted:

```bash
curl -s http://localhost:5000/tasks/$TASK_ID
```

Expected output:

```json
{
  "error": "UpstreamServiceError(\"upstream rejected payload 'order-1003'\")",
  "state": "FAILURE",
  "task_id": "..."
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-3-retries-exhausted.png" alt="Scenario 3 Retries Exhausted Terminal Output">
</p>

---

#### Scenario 4: Invalid Request (Missing Payload)

```bash
curl -s -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{}'
```

Expected:

```json
{"error":"field 'payload' is required"}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-4-invalid-submission.png" alt="Scenario 4 Invalid Submission">
</p>

---

#### Scenario 5: Invalid Failure Probability

```bash
curl -s -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"payload":"order-1004","fail_probability":2.0}'
```

Expected:

```json
{"error":"field 'fail_probability' must be between 0.0 and 1.0"}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-5-invalid-probability.png" alt="Scenario 5 Invalid Probability">
</p>

---

#### Scenario 6: Unknown Task ID

```bash
curl -s http://localhost:5000/tasks/does-not-exist
```

Expected:

```json
{
  "state": "PENDING",
  "detail": "task ID unknown or not yet started",
  "task_id": "does-not-exist"
}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/scenario-6-unknown-task-id.png" alt="Scenario 6 Unknown Task ID">
</p>

---

#### View Worker Logs

View the latest worker logs:

```bash
cd ~/celery-retry-lab
tail -n 50 logs/worker.log
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Asynchronous%20Processing%20with%20Celery/Module%2053/image/view-worker-logs.png" alt="View Worker Logs">
</p>

---

## Conclusion

In this lab, you built a production-ready asynchronous task worker capable of handling transient external failures gracefully. You configured exponential backoff, random jitter, and execution time limits to protect downstream dependencies while keeping workers operational. Furthermore, signal-based event logging ensured comprehensive operational audit trails across all task execution states.
