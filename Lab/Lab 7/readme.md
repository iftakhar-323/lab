# Lab 7: Celery Task Retries, Timeouts, and Task Status Tracking

## Overview

Distributed background tasks frequently encounter external service outages, network latency, or unexpected execution delays. To prevent silent failures and resource exhaustion, systems must implement automatic retries with exponential backoff, enforce soft and hard timeouts, and log every state transition. In this lab, you will build a resilient Flask and Celery pipeline backed by Redis that handles transient upstream errors, tracks lifecycle states, and exposes status diagnostics.

<p align="center">
  <img src="./image/lab_7_final.drawio.svg" alt="Lab 7 System Overview Diagram" width="100%">
</p>

---

## Step-by-Step Implementation

### Step 1: Project & Dependency Setup

1. Create directory and virtual environment:
   ```bash
   mkdir -p celery-retry-lab/logs && cd celery-retry-lab
   python3 -m venv venv
   source venv/bin/activate
   ```

2. Create `requirements.txt` and install packages:
   ```bash
   cat << 'EOF' > requirements.txt
   flask==3.0.3
   celery==5.4.0
   redis==5.0.8
   EOF
   pip install -r requirements.txt
   ```

---

### Step 2: Configure Celery & Event Signals (`celery_app.py`)

Create `celery_app.py` to enable task state tracking (`task_track_started=True`) and structured signal logging:

```python
import logging
from celery import Celery
from celery.signals import task_prerun, task_postrun, task_failure, task_retry

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.FileHandler("logs/worker.log"), logging.StreamHandler()],
)
logger = logging.getLogger("celery_retry_lab")

celery_app = Celery(
    "celery_retry_lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/1",
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
```

---

### Step 3: Implement Retrying Task (`tasks.py`)

Create `tasks.py` with automatic retry logic, jitter, backoff ceiling, and soft execution timeouts:

```python
import logging
import random
import time
from celery.exceptions import SoftTimeLimitExceeded
from celery_app import celery_app

logger = logging.getLogger("celery_retry_lab")

class UpstreamServiceError(Exception):
    """Raised when upstream service call fails."""

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
    try:
        logger.info("task_id=%s attempt=%s", self.request.id, self.request.retries + 1)
        time.sleep(1)

        if random.random() < fail_probability:
            raise UpstreamServiceError(f"upstream rejected payload '{payload}'")

        return {"payload": payload, "processed": True, "attempts": self.request.retries + 1}

    except SoftTimeLimitExceeded:
        logger.error("task_id=%s soft time limit exceeded", self.request.id)
        raise
    except UpstreamServiceError as exc:
        logger.warning("task_id=%s attempt failed: %s", self.request.id, exc)
        raise
```

---

### Step 4: Build Flask API (`app.py`)

Create `app.py` exposing job submission and detailed status retrieval:

```python
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

    async_result = call_upstream_service.apply_async(
        args=[payload], kwargs={"fail_probability": fail_probability}
    )
    return jsonify({"task_id": async_result.id, "state": "PENDING"}), 202

@app.get("/tasks/<task_id>")
def get_task_status(task_id):
    result = AsyncResult(task_id, app=celery_app)
    response = {"task_id": task_id, "state": result.state}

    if result.state == "SUCCESS":
        response["result"] = result.result
    elif result.state == "FAILURE":
        response["error"] = str(result.result)

    return jsonify(response), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

---

### Step 5: Test Execution & Failure Scenarios

1. Launch worker and Flask API:
   ```bash
   celery -A celery_app.celery_app worker --loglevel=info # Terminal 1
   python app.py                                           # Terminal 2
   ```

2. Test Scenario 1: Guaranteed Success (`fail_probability = 0.0`):
   ```bash
   curl -s -X POST http://localhost:5000/tasks \
     -H "Content-Type: application/json" \
     -d '{"payload": "order-1001", "fail_probability": 0.0}'
   ```

3. Test Scenario 2: Retries Exhausted (`fail_probability = 1.0`):
   ```bash
   curl -s -X POST http://localhost:5000/tasks \
     -H "Content-Type: application/json" \
     -d '{"payload": "order-1003", "fail_probability": 1.0}'
   ```

<p align="center">
  <img src="./image/scenario-2-retry-success.png" alt="Retry Then Success" width="650">
</p>

---

## Conclusion

In this lab, you built a production-ready asynchronous task worker capable of handling transient external failures gracefully. You configured exponential backoff, random jitter, and execution time limits to protect downstream dependencies while keeping workers operational. Furthermore, signal-based event logging ensured comprehensive operational audit trails across all task execution states.