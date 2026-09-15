# Production Task Management

You will build a production-style asynchronous task management system using a Flask API, Celery workers, and Redis. The API will handle long-running background jobs, manage task IDs, configure automatic retries, implement delayed jobs, and scale worker concurrency.

![Lab 16 Architecture Overview](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Untitled%20Diagram.drawio%20%286%29.svg)

## Concept section

| Term | Definition |
| --- | --- |
| **Task Broker** | A message queue that receives tasks from the API and routes them to workers. |
| **Result Backend** | A datastore used to save the state and results of completed tasks. |
| **Worker Concurrency** | The ability of a worker node to process multiple tasks simultaneously. |
| **Task Retries** | The mechanism to automatically retry a failed task, often with backoff delays. |

The Flask API receives client requests to process long-running tasks. Instead of blocking the request, the API delegates the task to the Celery worker via the Redis broker and immediately returns a task ID to the client. The Celery worker picks up the task from Redis, processes it in the background, and updates its status in the Redis result backend. The client can poll the API using the task ID to check the current status and final result.

## Objectives

- Build a Flask API to accept and track background tasks.
- Configure a Celery worker to process tasks asynchronously.
- Implement Redis as a message broker and result backend.
- Verify task execution, status tracking, and worker concurrency.

## What You Will Build

```text
lab16/
├── app.py
├── tasks.py
└── requirements.txt
```

The Flask application in `app.py` exposes REST endpoints to submit tasks and query their status, while `tasks.py` defines the Celery application and the background jobs to be executed.

## Step 1: Create the project directory

Run the following command:

```bash
mkdir -p ~/lab16 && cd ~/lab16
```

![Create Directory](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image.png)

**Explanation:**
- `mkdir -p ~/lab16`: Creates the target directory for the project files.
- `cd ~/lab16`: Changes the current working directory to the newly created folder.

## Step 2: Start the Redis broker

Run the following command to start the container:

```bash
docker run -d --name lab16-redis -p 6379:6379 redis:7
```

![Start Redis](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(2).png)

Run the following command to verify the container is running:

```bash
docker ps
```

![Verify Redis Status](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(3).png)

Run the following command to test connectivity:

```bash
docker exec -it lab16-redis redis-cli ping
```

![Test Redis Connectivity](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(4).png)

**Explanation:**
- `docker run -d`: Runs the container in detached mode.
- `--name lab16-redis`: Assigns a specific name to the container for easy reference.
- `-p 6379:6379`: Maps the host port 6379 to the container port 6379.
- `redis:7`: Specifies the Redis image version to use.
- `docker ps`: Lists running containers to ensure Redis started correctly.
- `docker exec ... ping`: Pings the Redis server inside the container to verify connectivity.

## Step 3: Set up the Python virtual environment

Run the following command to install the virtual environment package:

```bash
sudo apt update
sudo apt install -y python3.12-venv
```

![Install Virtualenv Package](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(5).png)

Run the following command to create and activate the virtual environment:

```bash
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
```

![Setup Virtualenv](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(6).png)

**Explanation:**
- `sudo apt update`: Updates the local package index.
- `sudo apt install -y python3.12-venv`: Installs the required virtual environment package.
- `python3 -m venv venv`: Creates an isolated Python environment in the `venv` directory.
- `source venv/bin/activate`: Activates the virtual environment.
- `pip install --upgrade pip`: Ensures the package installer is updated to the latest version.

## Step 4: Install dependencies

Run the following command to install the required packages:

```bash
pip install Flask Celery redis
```

![Install Packages](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(7).png)

Run the following command to verify the installed packages and python version:

```bash
python --version
pip show Flask Celery redis
```

![Verify Packages](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(8).png)

Run the following command to verify the files and redis status before running the application:

```bash
ls -la
docker ps
docker exec lab16-redis redis-cli ping
```

![Verify Environment Setup](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20(9).png)

**Explanation:**
- `pip install Flask`: Installs the Flask web framework.
- `pip install Celery`: Installs the Celery distributed task queue system.
- `pip install redis`: Installs the Redis client library for Python.

## Step 5: Create the Celery tasks file

Create a file named `tasks.py` with the following contents:

```python
import os
import time

from celery import Celery


REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = os.getenv("REDIS_PORT", "6379")

BROKER_URL = f"redis://{REDIS_HOST}:{REDIS_PORT}/0"
RESULT_BACKEND = f"redis://{REDIS_HOST}:{REDIS_PORT}/1"


celery = Celery(
    "lab16",
    broker=BROKER_URL,
    backend=RESULT_BACKEND
)


@celery.task(
    bind=True,
    autoretry_for=(Exception,),
    retry_backoff=True,
    retry_kwargs={"max_retries": 3}
)
def long_running_task(self, duration=10):
    print(f"Starting task: {self.request.id}")
    print(f"Task will run for {duration} seconds")

    time.sleep(duration)

    result = {
        "task_id": self.request.id,
        "message": "Long-running task completed successfully",
        "duration": duration
    }

    print(f"Completed task: {self.request.id}")

    return result
```

**Explanation:**
- `BROKER_URL`: Defines the Redis database 0 to be used as the message broker.
- `RESULT_BACKEND`: Defines the Redis database 1 to store the outcomes of tasks.
- `celery = Celery(...)`: Initializes the Celery application instance with the broker and backend configurations.
- `@celery.task(...)`: Decorates the function to register it as an asynchronous task.
- `bind=True`: Passes the task instance as the first argument (`self`), allowing access to context variables like `self.request.id`.
- `autoretry_for=(Exception,)`: Configures the task to automatically retry upon encountering any exception.
- `retry_backoff=True`: Implements exponential backoff delays between retry attempts.
- `retry_kwargs={"max_retries": 3}`: Limits the maximum number of retry attempts to 3.

## Step 6: Create the Flask API

Create a file named `app.py` with the following contents:

```python
from flask import Flask, jsonify, request
from celery.result import AsyncResult

from tasks import celery, long_running_task


app = Flask(__name__)


@app.route("/", methods=["GET"])
def home():
    return jsonify({
        "message": "Lab 16 Production Task Management API",
        "status": "running"
    })


@app.route("/tasks", methods=["POST"])
def create_task():
    data = request.get_json(silent=True) or {}

    duration = data.get("duration", 10)

    try:
        duration = int(duration)
    except (TypeError, ValueError):
        return jsonify({
            "error": "duration must be an integer"
        }), 400

    if duration < 1:
        return jsonify({
            "error": "duration must be greater than 0"
        }), 400

    task = long_running_task.delay(duration)

    return jsonify({
        "task_id": task.id,
        "status": "PENDING",
        "message": "Task accepted successfully"
    }), 202


@app.route("/tasks/<task_id>", methods=["GET"])
def get_task_status(task_id):
    task = AsyncResult(task_id, app=celery)

    response = {
        "task_id": task_id,
        "status": task.status
    }

    if task.status == "PENDING":
        response["message"] = "Task is waiting or running"

    elif task.status == "STARTED":
        response["message"] = "Task is currently running"

    elif task.status == "SUCCESS":
        response["message"] = "Task completed successfully"
        response["result"] = task.result

    elif task.status == "FAILURE":
        response["message"] = "Task failed"
        response["error"] = str(task.result)

    elif task.status == "RETRY":
        response["message"] = "Task is being retried"

    return jsonify(response)


if __name__ == "__main__":
    app.run(
        host="0.0.0.0",
        port=5000,
        debug=True
    )
```

**Explanation:**
- `@app.route("/tasks", methods=["POST"])`: Defines an endpoint to submit new background tasks.
- `long_running_task.delay(duration)`: Sends the task to the Celery queue instead of executing it synchronously.
- `return jsonify(...), 202`: Immediately returns a 202 Accepted response with the task ID, avoiding blocking the client.
- `@app.route("/tasks/<task_id>", methods=["GET"])`: Defines an endpoint to retrieve the current state of a specific task.
- `task = AsyncResult(task_id, app=celery)`: Retrieves the task metadata from the result backend using the provided task ID.
- `response["result"] = task.result`: Attaches the final computed output of the task to the response if execution was successful.

## Verification section

Run the following commands across multiple terminal sessions to verify the setup.

Run the following command in Terminal 1 to start the Flask API:

```bash
python app.py
```

Expected output:
```
 * Serving Flask app 'app'
 * Debug mode: on
 * Running on all addresses (0.0.0.0)
 * Running on http://127.0.0.1:5000
```

![Start Flask API](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20%2810%29.png)

Run the following command in Terminal 2 to start the Celery Worker:

```bash
cd ~/lab16 && source venv/bin/activate
celery -A tasks.celery worker --loglevel=info --concurrency=4
```

Expected output:
```
 -------------- celery@hostname v5.4.0
--- ***** ----- 
-- ******* ---- Linux-xxx
- *** --- * --- 
- ** ---------- [config]
- ** ---------- .> app:         lab16:0x...
- ** ---------- .> transport:   redis://localhost:6379/0
- ** ---------- .> results:     redis://localhost:6379/1
- *** --- * --- .> concurrency: 4 (prefork)
-- ******* ---- 
--- ***** ----- [queues]
 -------------- .> celery           exchange=celery(direct) key=celery
```

![Start Celery Worker](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20%2811%29.png)

**Scenario 1: API Health Check**

Run the following command in Terminal 3:

```bash
curl http://localhost:5000/
```

Expected output:
```json
{
  "message": "Lab 16 Production Task Management API",
  "status": "running"
}
```

**Scenario 2: Submit a Task**

Run the following command in Terminal 3:

```bash
curl -X POST http://localhost:5000/tasks \
  -H "Content-Type: application/json" \
  -d '{"duration":20}'
```

Expected output:
```json
{
  "message": "Task accepted successfully",
  "status": "PENDING",
  "task_id": "a1b2c3d4-e5f6-7890-abcd-1234567890ab"
}
```

**Scenario 3: Check Task Status**

Run the following command in Terminal 3 using the task ID from the previous step:

```bash
curl http://localhost:5000/tasks/a1b2c3d4-e5f6-7890-abcd-1234567890ab
```

Expected output (while running):
```json
{
  "message": "Task is waiting or running",
  "status": "PENDING",
  "task_id": "a1b2c3d4-e5f6-7890-abcd-1234567890ab"
}
```

Expected output (after 20 seconds):
```json
{
  "message": "Task completed successfully",
  "result": {
    "duration": 20,
    "message": "Long-running task completed successfully",
    "task_id": "a1b2c3d4-e5f6-7890-abcd-1234567890ab"
  },
  "status": "SUCCESS",
  "task_id": "a1b2c3d4-e5f6-7890-abcd-1234567890ab"
}
```

![Full API Test and Task Checking](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab16/Pasted%20image%20%2812%29.png)

| # | Call | Status | Body snippet |
| --- | --- | --- | --- |
| 1 | `GET /` | 200 OK | `{"status": "running"}` |
| 2 | `POST /tasks` | 202 Accepted | `{"status": "PENDING"}` |
| 3 | `GET /tasks/<task_id>` | 200 OK | `{"status": "SUCCESS"}` |

## Conclusion

You successfully built a robust production-grade Celery pipeline. You replaced synchronous wait times with background queues, learned to track statuses with an API, and explored production concepts like worker concurrency and automatic retries.
