# Lab 5: Asynchronous Processing with Celery

## Introduction

Web APIs are expected to respond quickly. When a request triggers a task that takes several seconds or minutes to complete, such as sending an email, generating a PDF, or processing an image, keeping the client waiting for that task to finish creates a poor user experience and can exhaust server resources under load.

This lab introduces Celery, a distributed task queue used to run time-consuming operations outside the request-response cycle. You will examine why synchronous processing becomes a bottleneck, understand the core components of the Celery architecture, and identify use cases where offloading work to a background worker is the correct design decision.

This lab is intended for developers who have built a basic REST API (using Flask or a similar framework) and want to understand how to handle long-running tasks without blocking API responses.

## Learning Objectives

By the end of this lab you will be able to:

- Explain the difference between synchronous and asynchronous task execution in a web API
- Identify the three core components of the Celery architecture: broker, worker, and result backend
- Analyze a workflow diagram to trace how a task moves from creation to completion
- Determine when a task should be offloaded to Celery instead of processed inline

**Prerequisites:**
- Basic understanding of REST APIs and HTTP request/response cycles
- Familiarity with Python and Flask
- Basic understanding of processes and message queues (helpful but not required)

## Prologue

You join the platform engineering team at a company running a document processing service. The API currently accepts a file upload, generates a PDF report, and emails it to the user, all within a single HTTP request.

During a load test, the team discovers that report generation takes between 8 and 15 seconds. Under concurrent load, API workers become blocked waiting for these tasks to finish, request queues build up, and the service becomes unresponsive.

Your task is to redesign the request flow so that report generation runs in the background. The API should accept the request, schedule the work, and return an immediate response. The actual processing should happen separately, without blocking the client.

## Environment Setup

Install the required packages before proceeding.

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

Install Flask, Celery, and Redis client library:
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

### Opening Context

Before introducing Celery, it is necessary to understand the problem it solves. Every design decision in the Celery architecture exists to address a limitation of synchronous request handling.

### What You Will Build

In this section, you will trace the request lifecycle of a synchronous API and identify where the bottleneck occurs.

### Think First

<details>
<summary>Question 1: If a Flask API handles a request that takes 10 seconds to complete, what happens to other incoming requests during that time?</summary>

In a synchronous single-threaded worker, the worker process remains occupied for the full 10 seconds. Other requests routed to that worker must wait until it becomes free. With a limited number of worker processes, this quickly leads to request queuing and increased latency across the entire service.
</details>

<details>
<summary>Question 2: Why does adding more API server instances only partially solve this problem?</summary>

Adding more instances increases the number of concurrent long-running requests the system can handle, but it does not reduce the cost of any individual request. Resources are still tied up for the full duration of each task, and scaling API servers to absorb long-running work is significantly more expensive than scaling dedicated background workers.
</details>

### Understanding the Diagram

The diagram below shows the synchronous flow described in the prologue.

**Without Celery (Synchronous):**

<p align="center">
  <img src="image/without%20celery%20synchronours.drawio.svg" alt="Without Celery (Synchronous)">
</p>

```
User → Long Task (Email/PDF) → Flask API → Response (User waits)
```

**With Celery (Asynchronous):**

<p align="center">
  <img src="image/With%20Celery%20(Asynchronous).drawio.svg" alt="With Celery (Asynchronous)">
</p>

```
User → Flask API → Schedule Task → Response (Immediate)
                ↓
        Redis Broker → Celery Worker → Background Execution
```

In this flow, the user sends a request and the Flask API schedules the long-running task on the broker and returns an immediate response. The actual work is picked up and executed by a separate Celery worker process, so the client's connection does not stay open while the task runs.

**Compare the two flows:** in the synchronous diagram, `Response (User waits)` sits at the end of the chain — the user only gets a response after the entire chain finishes. In the asynchronous diagram, `Response (Immediate)` branches off early — the Flask API returns as soon as the task is queued, while the `Celery Worker → Background Execution` chain runs in parallel. The user's waiting time is no longer tied to the task duration.

### Checkpoint

- [ ] You can explain why a long-running task inside a request handler blocks other requests
- [ ] You can explain why horizontal scaling alone does not solve this problem
- [ ] You understand that the goal is to separate task execution from request handling

## Chapter 2: The Celery Architecture

### Opening Context

Celery solves the blocking problem by moving task execution out of the API process entirely. Instead of running a task directly, the API schedules the task and returns immediately. A separate process picks up the task and executes it independently.

### What You Will Build

You will identify the three core components of a Celery-based system and describe the responsibility of each.

### Think First

<details>
<summary>Question: If the API does not execute the task itself, how does the task get from the API to the process that will actually run it?</summary>

There must be an intermediary that receives the task from the API and holds it until a worker is available to process it. This intermediary is the message broker.
</details>

### Implementation: Identifying the Components

Study the architecture diagram below and complete the component table that follows.

**Celery Architecture:**

<p align="center">
  <img src="image/celery%20architecture.drawio.svg" alt="Celery Architecture">
</p>

```

```

Complete the table by filling in the responsibility of each component:

| Component | Responsibility |
|---|---|
| Flask API | ___ |
| Redis Broker (Queue) | ___ |
| Celery Worker | ___ |
| Result Backend | ___ |

<details>
<summary>Reveal completed table</summary>

| Component | Responsibility |
|---|---|
| Flask API | Receives the HTTP request, creates a task message, sends it to the broker, and returns an immediate response |
| Redis Broker (Queue) | Stores task messages until a worker is available to fetch and process them |
| Celery Worker | A separate process that continuously fetches tasks from the broker and executes them |
| Result Backend | Stores the outcome of a completed task so it can be retrieved later, independent of the original request |

</details>

### Understanding the Code

**Broker:** The broker is a message queue. It does not process tasks; it only holds them. Redis is a common choice for a broker because it is fast and simple to operate, though RabbitMQ is also widely used in production systems.

**Worker:** The worker is a separate long-running process from the API. It has no direct connection to the original HTTP request. It only knows about the task message it received from the broker.

**Result Backend:** The result backend is optional in some designs, but it is necessary whenever the client needs to check the status or outcome of a task after the initial response has been returned. Redis can serve as both broker and result backend, or two separate systems can be used.

### Matching Exercise

Match each term to its correct definition.

| Term | Definition |
|---|---|
| A. Broker | 1. Executes the task logic |
| B. Worker | 2. Stores task output for later retrieval |
| C. Result Backend | 3. Queues tasks between producer and consumer |

<details>
<summary>Reveal answers</summary>

A → 3, B → 1, C → 2
</details>

### Checkpoint

- [ ] You can name the three core components of the Celery architecture
- [ ] You can explain the responsibility of each component without referring back to the table
- [ ] You understand that the worker is a separate process from the API

## Chapter 3: Tracing the End-to-End Workflow

### Opening Context

With the individual components defined, this section traces a single task through the complete system, from the moment a user sends a request to the moment the task result becomes available.

### What You Will Build

You will trace the full path of a task and predict the state of the system at each step.

### Implementation: Tracing the Flow

Study the end-to-end workflow diagram:

<p align="center">
  <img src="image/End-to-End%20Workflow.drawio.svg" alt="End-to-End Workflow">
</p>

```
User → HTTP Request → Flask API → Create Celery Task
                                          ↓
Celery Worker ← Redis Broker Queue ← (task enqueued)
      ↓
Task Completed → Redis Result Backend → Execute Task (Email/PDF)
```

### Test and Verify

Predict the answer before revealing it.

**Question:** At the moment the Flask API returns its HTTP response to the user, has the email or PDF task been completed yet?

<details>
<summary>Reveal answer</summary>

No. The API returns a response as soon as the task has been created and placed on the broker queue. The actual execution (sending the email or generating the PDF) happens afterward, in the Celery worker process, independent of the API response.
</details>

**Question:** If the Celery worker process is stopped, what happens to a task that was already sent to the broker?

<details>
<summary>Reveal answer</summary>

The task remains in the broker's queue. It is not lost, but it will not be executed until a worker process is running and able to fetch it. This is one reason Redis (or another persistent broker) is used instead of holding tasks only in the API's memory.
</details>

### Comparing Synchronous and Asynchronous Flows

| Aspect | Without Celery (Synchronous) | With Celery (Asynchronous) |
|---|---|---|
| Request duration | Equal to task duration | Near-instant |
| Task execution location | Inside the API request handler | Separate worker process |
| API availability during task | Blocked | Free to handle other requests |
| Result retrieval | Returned directly in the response | Retrieved separately via result backend |

### Checkpoint

- [ ] You can trace a task from HTTP request to task completion using the diagram
- [ ] You can explain what happens to a task if no worker is currently running
- [ ] You can articulate the difference in API response time between the two approaches

## Chapter 4: Identifying Use Cases

### Opening Context

Celery is not appropriate for every operation. Understanding when to use it is as important as understanding how it works.

### Scenario Questions

For each scenario, determine whether the task should be handled synchronously (inline in the API) or asynchronously (offloaded to Celery).

**Scenario 1:** A user submits a form, and the API needs to validate the input and return a confirmation message. Validation takes a few milliseconds.

<details>
<summary>Reveal answer</summary>

Synchronous. The operation is fast and the client needs the validation result immediately to know whether the form was accepted.
</details>

**Scenario 2:** A user uploads a video file, and the API needs to transcode it into multiple resolutions before it can be streamed.

<details>
<summary>Reveal answer</summary>

Asynchronous. Video transcoding can take minutes. The API should accept the upload, schedule the transcoding task, and return a response indicating the video is processing.
</details>

**Scenario 3:** A user requests a password reset, and the API needs to send an email containing a reset link.

<details>
<summary>Reveal answer</summary>

Asynchronous. Sending an email depends on an external mail server and network latency, both of which are outside the API's control. Offloading this prevents the request from blocking on an external dependency.
</details>

**Scenario 4:** A user requests their current account balance, which is a simple database lookup.

<details>
<summary>Reveal answer</summary>

Synchronous. A simple, fast database read does not benefit from the overhead of task queuing and should be returned directly.
</details>

### Experiment

Intentionally misconfigure the system to observe a failure mode.

1. Stop the Celery worker process while keeping the Flask API and Redis running.
2. Send a request to an endpoint that creates a Celery task (for example, an email-sending endpoint).
3. Observe the API response time.

**Observation:** The API still returns a fast response, because the task was successfully placed on the broker queue. However, the task itself (sending the email) never executes, since no worker is available to fetch it.

4. Restart the Celery worker.
5. Observe that the previously queued task is picked up and executed shortly after the worker restarts.

Restore the worker to a running state before continuing.

### Checkpoint

- [ ] You can distinguish between tasks suited for synchronous handling and those suited for asynchronous handling
- [ ] You have observed that tasks queue in the broker even if no worker is running
- [ ] You understand that a fast API response does not guarantee the underlying task has completed

## Epilogue

You have examined why synchronous processing of long-running operations creates bottlenecks in a web API, and how Celery addresses this by separating task creation from task execution. You traced a task through the full architecture, from the Flask API, through the Redis broker, to the Celery worker, and finally to the result backend.

The company's document processing service can now accept a request, schedule report generation as a background task, and return an immediate response to the user, resolving the load test failure identified in the prologue.

## The Principles

- A web API should return a response as quickly as possible; long-running work does not belong inside a request handler.
- The broker decouples task creation from task execution, allowing workers to process tasks independently of the API's lifecycle.
- Tasks placed on the broker are not lost if a worker is temporarily unavailable; they wait in the queue.
- A result backend is only necessary when a task's outcome must be retrieved after the original request has completed.
- Not every operation should be offloaded; fast, low-latency operations are typically better handled synchronously.

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| Task appears to never complete | Celery worker is not running | Start the worker process and confirm it connects to the broker |
| `redis-cli ping` returns no response | Redis server is not running | Start the Redis service and verify its process status |
| API returns a response but no result is ever stored | No result backend configured | Confirm the Celery app is configured with a result backend URL |
| Worker starts but does not fetch any tasks | Worker is not subscribed to the correct queue name | Verify the queue name used by the API matches the queue the worker is consuming from |

## Next Steps

Continue to the following module to implement the Celery producer and consumer in code, defining a task function, configuring the Celery application, and connecting it to a Flask API endpoint.

## Additional Resources

- Celery official documentation: https://docs.celeryq.dev
- Redis documentation: https://redis.io/docs
- Flask documentation: https://flask.palletsprojects.com
