# Lab 5: Asynchronous Processing with Celery

## Introduction

A web API is expected to respond quickly. When a request triggers a task that takes several seconds or minutes to complete, such as sending an email, generating a PDF, or processing an image, keeping the client waiting for that task creates a poor user experience and exhausts server resources under load.

This lab covers Celery, a distributed task queue used to run time-consuming operations outside the request-response cycle. It explains why synchronous processing becomes a bottleneck, the core components of the Celery architecture, and the criteria for deciding when a task should run in the background instead of inline.

This lab is written for developers who have already built a basic REST API (Flask or similar) and need to move a slow operation out of the request handler.

## Learning Objectives

By the end of this lab you will be able to:

- Explain the difference between synchronous and asynchronous task execution in a web API
- Identify the three core components of the Celery architecture: broker, worker, and result backend
- Trace a task from creation to completion using the workflow diagram
- Determine when a task should be offloaded to Celery instead of processed inline

**Prerequisites:**
- Basic understanding of REST APIs and HTTP request/response cycles
- Familiarity with Python and Flask
- Basic understanding of processes and message queues (helpful but not required)

## Environment Setup

Update system packages:
```bash
sudo apt update
```

Create a virtual environment:
```bash
python3 -m venv venv
```

Activate the virtual environment:
```bash
source venv/bin/activate
```

Install Flask, Celery, and the Redis client library:
```bash
pip install flask celery redis
```

Install and start Redis (used as the broker and result backend for this lab):
```bash
sudo apt install redis-server
sudo systemctl start redis-server
```

Verify Redis is running:
```bash
redis-cli ping
```

Expected output:
```
PONG
```

Create a working directory:
```bash
mkdir celery-lab && cd celery-lab
```

## Chapter 1: Why Synchronous Processing Fails Under Load

### Context

In a synchronous single-threaded worker, the worker process stays occupied for the full duration of a long-running task. Other requests routed to that worker wait until it becomes free. With a limited number of worker processes, this produces request queuing and increased latency across the entire service.

Adding more API server instances only partially addresses this. It increases the number of concurrent long-running requests the system can absorb, but it does not reduce the cost of any individual request. Resources stay tied up for the full task duration, and scaling API servers to absorb long-running work is significantly more expensive than scaling dedicated background workers.

### Comparing the Two Flows

**Without Celery (Synchronous):**

<div align="center">
<img alt="Without Celery (Synchronous) request flow" src="image/without celery synchronours.gif" />
</div>

```text
The client sends a request.
The Flask API performs the long task (such as sending an email or generating a PDF) immediately.
The client waits until the task finishes.
Only after the task completes does the API send a response back to the client.
```

**With Celery (Asynchronous):**

<div align="center">
<img alt="With Celery (Asynchronous) request flow" src="image/With Celery (Asynchronouss).gif" />
</div>

```text
The client sends a request to the Flask API.
The Flask API creates a background task and places it in the Redis queue.
The API immediately returns a response to the client without waiting.
A Celery worker picks up the task from the Redis queue and executes the long-running task (e.g., sending an email or generating a PDF) in the background.
```

In the synchronous diagram, `Response (User waits)` sits at the end of the chain — the client only gets a response after the entire chain finishes. In the asynchronous diagram, `Response (Immediate)` branches off early — the Flask API returns as soon as the task is queued, while the `Celery Worker → Background Execution` chain runs in parallel. The client's waiting time is no longer tied to the task duration.

### Self-Assessment

- [ ] You can explain why a long-running task inside a request handler blocks other requests
- [ ] You can explain why horizontal scaling alone does not solve this problem
- [ ] You understand that the goal is to separate task execution from request handling

## Chapter 2: The Celery Architecture

### Context

Celery solves the blocking problem by moving task execution out of the API process entirely. Instead of running a task directly, the API schedules the task and returns immediately. A separate process picks up the task and executes it independently.

Since the API does not execute the task itself, an intermediary is required to receive the task from the API and hold it until a worker is available to process it. This intermediary is the message broker.

### The Architecture Diagram

<div align="center">
<img alt="Celery Architecture" src="image/celery architecture.gif" />
</div>

| Component | Responsibility |
|---|---|
| Flask API | Receives the HTTP request, creates a task message, sends it to the broker, and returns an immediate response |
| Redis Broker (Queue) | Stores task messages until a worker is available to fetch and process them |
| Celery Worker | A separate process that continuously fetches tasks from the broker and executes them |
| Result Backend | Stores the outcome of a completed task so it can be retrieved later, independent of the original request |

### Understanding the Components

**Broker:** The broker is a message queue. It does not process tasks; it only holds them. Redis is a common choice for a broker because it is fast and simple to operate, though RabbitMQ is also widely used in production systems.

**Worker:** The worker is a separate long-running process from the API. It has no direct connection to the original HTTP request. It only knows about the task message it received from the broker.

**Result Backend:** The result backend is optional in some designs, but it is necessary whenever the client needs to check the status or outcome of a task after the initial response has been returned. Redis can serve as both broker and result backend, or two separate systems can be used.

### Self-Assessment

- [ ] You can name the three core components of the Celery architecture
- [ ] You can explain the responsibility of each component
- [ ] You understand that the worker is a separate process from the API

## Chapter 3: Tracing the End-to-End Workflow

### Context

With the individual components defined, this section traces a single task through the complete system, from the moment a client sends a request to the moment the task result becomes available.

### The Workflow Diagram

<div align="center">
<img alt="End-to-End Workflow" src="image/End-to-End Workflow.gif" />
</div>

At the moment the Flask API returns its HTTP response, the underlying task (sending the email or generating the PDF) has not been completed yet. The API returns a response as soon as the task has been created and placed on the broker queue. The actual execution happens afterward, in the Celery worker process, independent of the API response.

If the Celery worker process is stopped, a task that was already sent to the broker is not lost. It remains in the broker's queue and is not executed until a worker process is running and able to fetch it. This is one reason Redis (or another persistent broker) is used instead of holding tasks only in the API's memory.

### Comparing Synchronous and Asynchronous Flows

| Aspect | Without Celery (Synchronous) | With Celery (Asynchronous) |
|---|---|---|
| Request duration | Equal to task duration | Near-instant |
| Task execution location | Inside the API request handler | Separate worker process |
| API availability during task | Blocked | Free to handle other requests |
| Result retrieval | Returned directly in the response | Retrieved separately via result backend |

### Self-Assessment

- [ ] You can trace a task from HTTP request to task completion using the diagram
- [ ] You can explain what happens to a task if no worker is currently running
- [ ] You can articulate the difference in API response time between the two approaches

## Chapter 4: Deciding When to Use Celery

### Context

Celery is not appropriate for every operation. Deciding when to use it is as important as understanding how it works.

### Guideline

Offload a task to Celery when it depends on an external, slow, or unreliable resource — a mail server, a transcoding pipeline, a third-party API — or when it takes more than a few hundred milliseconds to complete. Keep a task synchronous when it is fast (a validation check, a simple database read) and the client needs the result immediately to proceed.

| Task type | Handling | Reason |
|---|---|---|
| Form validation | Synchronous | Fast; client needs the result immediately to know whether the form was accepted |
| Video transcoding | Asynchronous | Can take minutes; API should accept the upload and return a processing status |
| Password reset email | Asynchronous | Depends on an external mail server and network latency outside the API's control |
| Account balance lookup | Synchronous | Simple, fast database read; queuing overhead is not justified |

### Verifying Broker Behavior

Run the following sequence to confirm that queued tasks survive a stopped worker:

```bash
# 1. Stop the Celery worker process, keep Flask API and Redis running
# 2. Send a request to an endpoint that creates a Celery task
curl -X POST http://127.0.0.1:5000/send-email \
  -H "Content-Type: application/json" \
  -d "{\"to\": \"user@example.com\"}"
```

Expected result: the API still returns a fast response, because the task was placed on the broker queue. The task itself does not execute yet, since no worker is available to fetch it.

```bash
# 3. Restart the Celery worker
celery -A app.celery worker --loglevel=info
```

Expected result: the previously queued task is picked up and executed shortly after the worker restarts. Restore the worker to a running state before continuing.

### Self-Assessment

- [ ] You can distinguish between tasks suited for synchronous handling and those suited for asynchronous handling
- [ ] You have observed that tasks queue in the broker even if no worker is running
- [ ] You understand that a fast API response does not guarantee the underlying task has completed

## The Principles

- A web API should return a response as quickly as possible; long-running work does not belong inside a request handler.
- The broker decouples task creation from task execution, allowing workers to process tasks independently of the API's lifecycle.
- Tasks placed on the broker are not lost if a worker is temporarily unavailable; they wait in the queue.
- A result backend is only necessary when a task's outcome must be retrieved after the original request has completed.
- Not every operation should be offloaded; fast, low-latency operations are typically better handled synchronously.
