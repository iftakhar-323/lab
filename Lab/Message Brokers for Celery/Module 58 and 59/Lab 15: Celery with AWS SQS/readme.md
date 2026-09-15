# Module 58 and 59 - Lab 15: Celery with Redis

You will build an asynchronous task processing pipeline using Celery as the task queue and Redis as the message broker and result backend. The architecture includes a Celery client to submit background jobs, a Redis server to queue tasks, and a Celery worker to execute them.

![Lab 15 Architecture Overview](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Untitled%20Diagram.drawio.svg)

## Concepts

| Term | Definition |
| --- | --- |
| Celery | A distributed task queue system for processing asynchronous jobs. |
| Message Broker | A service that accepts and queues messages for task execution. |
| Redis | An in-memory data store acting as the message broker and result backend. |
| Result Backend | A storage layer where task statuses and return values are saved. |
| Celery Worker | A background process that pulls tasks from the broker and executes them. |

The Celery client submits tasks to the Redis broker, which queues them in memory. The Celery worker continuously monitors the broker, retrieves pending tasks, and executes them asynchronously. Once execution finishes, the worker saves the task status and return value to the Redis result backend, allowing the client to retrieve the results later.

![Celery Workflow and Dead Letter Queue](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Untitled%20Diagram.drawio%20%286%29.svg)

## Objectives
- Build a Celery task queue using Redis as the broker.
- Configure Redis as the result backend for Celery tasks.
- Implement a background task to simulate a time-consuming process.
- Verify task execution and status retrieval via a Python REPL environment.

## What You Will Build

```text
celery-lab15/
└── tasks.py
```
You will configure a Python application that uses `tasks.py` to define Celery configurations and functions, connecting to a containerized Redis instance for queuing and result storage.

## Step 1: Create the lab directory
Run the following command:
```bash
mkdir celery-lab15
cd celery-lab15
```
**Explanation:**
- `mkdir celery-lab15` creates a dedicated directory for the project files.
- `cd celery-lab15` changes the working directory to the newly created folder.

## Step 2: Install required packages
Run the following command:
```bash
pip install celery redis
```
![Install Dependencies](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Screenshot%20from%202026-08-17%2020-40-58.png)

**Explanation:**
- `pip install celery redis` installs the Celery framework and the Redis client library required for Python to communicate with the Redis broker.

## Step 3: Start Redis via Docker
Run the following command:
```bash
docker run -d --name redis -p 6379:6379 redis:7
```
![Start Redis](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Screenshot%20from%202026-08-17%2020-41-12.png)

**Explanation:**
- `docker run` creates and starts a new Docker container.
- `-d` runs the container in detached mode in the background.
- `--name redis` assigns the name "redis" to the container.
- `-p 6379:6379` maps port 6379 of the host machine to port 6379 of the container.
- `redis:7` specifies the Redis image and version tag to use.

## Step 4: Verify Redis status
Run the following command:
```bash
docker exec -it redis redis-cli ping
```
![Verify Redis](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Screenshot%20from%202026-08-17%2020-41-25.png)

**Explanation:**
- `docker exec -it redis` executes a command interactively inside the running "redis" container.
- `redis-cli ping` uses the Redis command-line interface to send a ping command, testing the server connection.

## Step 5: Define the Celery application and tasks
Create a file named `tasks.py` with the following contents:
```python
from celery import Celery
import time

app = Celery(
    "lab15",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/1"
)

@app.task
def process_task(name):
    print(f"Processing task for {name}")
    time.sleep(5)
    print("Task completed")
    return f"Hello {name}, task completed successfully"
```
![Create tasks.py](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Screenshot%20from%202026-08-17%2020-41-44.png)

**Explanation:**
- `from celery import Celery` imports the core Celery application class.
- `import time` imports the time module to simulate a delay.
- `app = Celery("lab15", ...)` initializes a Celery application instance named "lab15".
- `broker="redis://localhost:6379/0"` configures the Redis database index 0 as the message broker.
- `backend="redis://localhost:6379/1"` configures the Redis database index 1 as the result backend.
- `@app.task` is a decorator that registers the `process_task` function as a Celery background task.
- `def process_task(name):` defines a function that takes a name parameter.
- `time.sleep(5)` pauses execution for 5 seconds to simulate a time-consuming workload.
- `return ...` sends a formatted completion message to the result backend.

## Verification

Run the following command to start the Celery worker in one terminal:
```bash
celery -A tasks.app worker --loglevel=info
```
![Start Celery Worker](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Screenshot%20from%202026-08-17%2020-41-58.png)

Expected output:
```text
 -------------- celery@hostname v5.x.x
...
[config]
.> app:         lab15:0x...
.> transport:   redis://localhost:6379/0
.> results:     redis://localhost:6379/1
...
[tasks]
  . tasks.process_task

[INFO/MainProcess] celery@hostname ready.
```

In a second terminal, run the following command to open the Python REPL:
```bash
python3
```

**Scenario 1: Submit and verify task execution**
Run the following command in the Python REPL:
```python
from tasks import process_task
result = process_task.delay("Bayajid")
print(result.id)
print(result.status)
print(result.get())
```
![Submit Task Python REPL](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab15/Screenshot%20from%202026-08-17%2020-40-37.png)

Expected output:
```text
d36e073e-cb7b-4c54-9597-313f9edd2c47
SUCCESS
Hello Bayajid, task completed successfully!
```

| # | Call | Status | Body snippet |
|---|---|---|---|
| 1 | `process_task.delay("Bayajid")` | SUCCESS | `Hello Bayajid, task completed successfully!` |

## Conclusion

You built an asynchronous task processing pipeline using Celery and Redis. You configured a Celery application to use Redis for both message brokering and result storage, implemented a background task, and verified the task execution lifecycle through a Python client.
