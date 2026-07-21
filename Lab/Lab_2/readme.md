# Lab 6: Building a Flask API with Celery and Redis

**Module 52 | Asynchronous Processing with Celery**

## Introduction

Web applications often need to perform work that takes longer than a typical HTTP request should wait for, such as sending an email, generating a PDF report, or processing an uploaded file. Running this work directly inside a request handler blocks the client and wastes server resources during the wait.

This lab is intended for developers who have completed Lab 5 and understand the conceptual architecture of Celery, including the roles of the broker, the worker, and the result backend. This lab moves from theory to implementation by connecting a Flask API to Celery, using Redis as both the broker and the result backend.

By working through this lab, you gain the ability to offload long-running work from an API request and track its progress asynchronously, a pattern used in production systems that need to remain responsive under load.

![Celery Redis Architecture](./images/Celery%20Redis%20Architecture.drawio.svg)

## Learning Objectives

By the end of this lab you will be able to:

- Configure a Flask API to submit background tasks instead of executing them inline
- Install and configure `celery[redis]` in a Python project
- Connect Celery to Redis as both the message broker and the result backend
- Implement Celery tasks for operations such as sending an email and generating a PDF
- Verify asynchronous task execution using task IDs and status polling

### Prerequisites

- Lab 5 completed (Celery architecture: broker, worker, result backend)
- Working knowledge of Flask routes and request handling
- Python 3.10 or later installed
- Docker installed and running
- Basic familiarity with the command line

## Prologue

You join the backend team of a document processing platform. The current API generates invoice PDFs directly inside the request handler. During peak hours, PDF generation takes several seconds, and clients experience timeouts.

The engineering lead assigns you the task of moving this work into a background task queue. The goal is an API that accepts a request, immediately returns a task ID, and processes the actual work separately. The client should be able to check the task status using the returned ID.

The expected system consists of three components: a Flask API that accepts requests and queues tasks, a Redis instance that stores pending tasks and results, and a Celery worker that executes the tasks.

## Environment Setup

Update the system package index.

```bash
sudo apt update
```

Create a project directory and a virtual environment.

```bash
mkdir flask-celery-lab
cd flask-celery-lab
python3 -m venv venv
```

Activate the virtual environment.

```bash
source venv/bin/activate
```

Install the required packages.

```bash
pip install flask celery[redis]
```

Start a Redis instance using Docker. Redis is not assumed to be pre-installed.

```bash
docker run -d --name redis-broker -p 6379:6379 redis:7-alpine
```

Create the project structure.

```bash
mkdir flask-celery-lab/app
touch app/__init__.py app/celery_app.py app/tasks.py app/main.py
```

**Prediction question:** Before running the Redis container, predict what happens if port 6379 is already in use on your machine.

<details>
<summary>Reveal answer</summary>
Docker returns an error indicating that the port is already allocated, and the container fails to start. The port mapping must be changed, for example `-p 6380:6379`, and the broker URL updated to match.
</details>

## Chapter 1: Connecting Celery to Redis

### Opening Context

Celery does not process tasks by itself. It requires a message broker to hold pending tasks and, when results are needed, a result backend to store task outcomes. This chapter configures Redis to serve both roles.

![Redis broker vs backend](./images/Redis%20broker%20vs%20backend.drawio.svg)

### What You Will Build

A `celery_app.py` module that creates a Celery application instance configured to use Redis as both the broker and the backend. This instance is imported by both the Flask API and the worker process.

### Think First

Before writing any code, consider the following question.

**Question:** Redis can serve as both the broker and the backend at the same time. What is the difference between what Redis stores in each role?

<details>
<summary>Reveal answer</summary>
As a broker, Redis stores a queue of pending task messages waiting to be picked up by a worker, structured as a first-in-first-out list. As a backend, Redis stores the result of a completed task, indexed by task ID, so that a client can retrieve it later. The same Redis instance can perform both roles using different key namespaces, but in production these are often separated into different Redis databases or instances to isolate load.
</details>

### Implementation

Complete the Celery application configuration below. Replace each blank with the correct value.

```python
# app/celery_app.py
from celery import Celery

celery = Celery(
    "flask_celery_lab",
    broker=______________,   # Redis URL for the broker
    backend=______________,  # Redis URL for the result backend
)
```

**Hint:** Redis connection URLs follow the format `redis://<host>:<port>/<db_number>`. Use database 0 for the broker and database 1 for the backend to keep them logically separate.

<details>
<summary>Reveal solution</summary>

```python
# app/celery_app.py
from celery import Celery

celery = Celery(
    "flask_celery_lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/1",
)
```

</details>

### Understanding the Code

The `Celery` constructor takes a name that identifies the application, typically matching the module name. The `broker` argument tells Celery where to publish and consume task messages. The `backend` argument tells Celery where to store task state and return values.

**Concept question:** If the `backend` argument is omitted, what capability is lost?

<details>
<summary>Reveal answer</summary>
Without a backend, Celery can still queue and execute tasks, but the result and state of a task cannot be retrieved afterward. Calling `.get()` or checking `.status` on a task result raises an error, since there is nowhere to look up that information.
</details>

## Chapter 2: Defining Background Tasks

### Opening Context

A Celery task is a regular Python function decorated so that Celery can route calls to it through the broker instead of executing them in the caller's process.

### What You Will Build

Two Celery tasks: one that simulates sending an email, and one that simulates generating a PDF report. Both tasks include an artificial delay to represent real processing time.

### Think First

**Question:** A task function uses `time.sleep(5)` to simulate slow work. If this function is called directly as `send_email("user@example.com")` instead of `send_email.delay("user@example.com")`, what happens to the Flask request that called it?

<details>
<summary>Reveal answer</summary>
The Flask request thread blocks for the full 5 seconds, since the function executes synchronously inside the request handler. The client waiting on that request also waits 5 seconds. Calling `.delay()` instead hands the task to Celery, and the request handler returns immediately with a task ID.
</details>

### Implementation

Complete the task definitions.

```python
# app/tasks.py
import time
from app.celery_app import celery

@celery.___________  # decorator that registers this function as a Celery task
def send_email(recipient):
    time.sleep(5)  # simulate slow email delivery
    return f"Email sent to {recipient}"

@celery.task
def generate_pdf(document_id):
    time.____(8)  # simulate slow PDF rendering
    return f"PDF generated for document {document_id}"
```

<details>
<summary>Reveal solution</summary>

```python
# app/tasks.py
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
```

</details>

### Understanding the Code

The `@celery.task` decorator registers a function with the Celery application so it can be invoked asynchronously. Once registered, the function gains methods such as `.delay()` and `.apply_async()`, which submit the function call as a message to the broker instead of executing it immediately in the current process.

## Chapter 3: Submitting Tasks from Flask

### Opening Context

The Flask API is responsible for accepting client requests and submitting tasks to Celery. It does not execute the task logic itself.

![Task lifecycle](./images/Task%20lifecycle.drawio.svg)

### What You Will Build

A Flask application with two routes: one that queues an email task, and one that checks the status of a previously submitted task.

### Think First

**Question:** After calling `send_email.delay(recipient)`, the Flask route immediately has access to a task ID. At that moment, has the email actually been sent?

<details>
<summary>Reveal answer</summary>
No. The task has only been placed on the Redis queue. The email is sent only when a Celery worker process picks up the message and executes the function. Without a running worker, the task remains in the `PENDING` state indefinitely.
</details>

### Implementation

Complete the Flask routes.

```python
# app/main.py
from flask import Flask, jsonify, request
from app.tasks import send_email
from app.celery_app import celery

app = Flask(__name__)

@app.route("/send-email", methods=["POST"])
def trigger_email():
    recipient = request.json.get("recipient")
    task = send_email.___________(recipient)  # queue the task, do not call directly
    return jsonify({"task_id": task.id}), 202

@app.route("/status/<task_id>", methods=["GET"])
def check_status(task_id):
    result = celery.AsyncResult(task_id)
    return jsonify({
        "task_id": task_id,
        "state": result.____,   # current task state
        "result": result.result if result.ready() else None
    })
```

<details>
<summary>Reveal solution</summary>

```python
# app/main.py
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
```

</details>

### Understanding the Code

The `202 Accepted` status code is used instead of `200 OK` because the request has been accepted for processing, but the work is not yet complete. `celery.AsyncResult(task_id)` reconstructs a result handle from a task ID, allowing state to be queried from any process, not only the one that submitted the task, because state is stored in the shared Redis backend.

**Matching exercise:** Match each Celery task state to its meaning.

| State | Meaning |
|---|---|
| PENDING | ? |
| STARTED | ? |
| SUCCESS | ? |
| FAILURE | ? |

<details>
<summary>Reveal answers</summary>

| State | Meaning |
|---|---|
| PENDING | Task has been queued but has not yet been picked up by a worker |
| STARTED | A worker has begun executing the task |
| SUCCESS | The task completed and the return value is available |
| FAILURE | The task raised an exception during execution |

</details>

## Test and Verify

Start the Celery worker in one terminal.

```bash
celery -A app.celery_app.celery worker --loglevel=info
```

**Prediction question:** Before starting the Flask server, predict what happens if a request is sent to `/send-email` while the worker above is not running.

<details>
<summary>Reveal answer</summary>
The Flask route still returns a `202` response with a task ID, since queuing a task only requires the broker, not the worker. The task remains in the `PENDING` state in Redis until a worker becomes available to process it.
</details>

Start the Flask application in a second terminal.

```bash
python -m flask --app app.main run
```

Submit a task.

```bash
curl -X POST http://localhost:5000/send-email \
  -H "Content-Type: application/json" \
  -d '{"recipient": "user@example.com"}'
```

**Predict the response fields and status code before running the command above.**

<details>
<summary>Reveal expected output</summary>

```json
{"task_id": "3f2504e0-4f89-11d3-9a0c-0305e82c3301"}
```

Status code: `202`

</details>

Check the task status using the returned ID.

```bash
curl http://localhost:5000/status/3f2504e0-4f89-11d3-9a0c-0305e82c3301
```

**Predict the state field if this command is run immediately after submission, versus 6 seconds later.**

<details>
<summary>Reveal expected behavior</summary>
Immediately after submission, the state is typically `PENDING` or `STARTED`, and `result` is `null`. After the 5-second simulated delay in `send_email` completes, the state becomes `SUCCESS` and `result` contains the returned message.
</details>

## Checkpoint

Verify the following before moving on.

- [ ] Redis container is running and accessible on the configured port
- [ ] Celery worker starts without connection errors
- [ ] `/send-email` returns a task ID with status `202`
- [ ] `/status/<task_id>` reflects state transitions from `PENDING` to `SUCCESS`
- [ ] The Flask process remains responsive while a task is still executing

## Experiment

Stop the Redis container while the Flask server and Celery worker are still running.

```bash
docker stop redis-broker
```

Submit a new task using the `/send-email` endpoint and observe the result.

**Question:** Does the Flask route return an error immediately, or does it hang? Restore Redis and confirm your observation.

```bash
docker start redis-broker
```

## Epilogue

This lab connected a Flask API to Celery using Redis as both the broker and the result backend, and implemented tasks that execute independently of the request-response cycle. The API now returns immediately while work continues in the background, and clients can poll for status using a task ID.

This lab did not address what happens when a task fails partway through, how to retry failed tasks automatically, or how to enforce timeouts on tasks that run too long. These concerns are addressed in Lab 7.

## Troubleshooting

| Problem | Likely Cause | Resolution |
|---|---|---|
| `Error 111 connecting to localhost:6379` | Redis container is not running | Run `docker ps` to confirm the container status, then `docker start redis-broker` |
| Task stays in `PENDING` indefinitely | No Celery worker is running, or the worker points to a different broker URL | Confirm the worker process is active and that `broker` in `celery_app.py` matches the Redis port |
| `KeyError` on `request.json` | Request was sent without a JSON body or without the `Content-Type: application/json` header | Confirm the header is set and the body is valid JSON |
| Worker logs show tasks but Flask never receives a task ID | Flask route is calling the task function directly instead of using `.delay()` | Review Chapter 3 and confirm `.delay()` is used |

## Next Steps

Lab 7 extends this setup with task retries, timeouts, and structured error handling, along with a dedicated endpoint for tracking task state transitions in more detail.

## Additional Resources

- Celery official documentation: First Steps with Celery
- Redis documentation: Data Types
- Flask documentation: Handling JSON requests