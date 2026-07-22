# Lab 7: Celery Task Retries, Timeouts, and Error Handling

## Introduction

Celery tasks run in separate worker processes and cannot rely on the HTTP request lifecycle for feedback. When a task fails, hangs, or needs to be retried, the worker must handle those conditions itself, without depending on the client that originally submitted the task.

This lab covers the failure-handling mechanisms Celery provides: automatic retries with backoff, soft and hard timeouts, and structured error reporting. You will examine diagrams that show how a task moves between states, how retries are scheduled, and how timeouts interrupt work that takes too long.

## Diagrams

### Retry and Backoff Flow

<p align="center">
  <img src="./image/Celery%20Retry%20%26%20Backoff%20Flow.drawio.svg" alt="Celery Retry and Backoff Flow">
</p>

This diagram shows how a failed task is re-queued with an increasing delay between attempts. After each failure, the worker waits for the backoff interval before re-executing the task, up to a configured maximum number of retries.

### Task States with Retry Loop

<p align="center">
  <img src="./image/Celery%20Task%20States%20with%20Retry%20Loop.drawio.svg" alt="Celery Task States with Retry Loop">
</p>

This diagram traces the full state machine for a single task: PENDING → STARTED → SUCCESS, or PENDING → STARTED → RETRY → STARTED → … → SUCCESS / FAILURE. The retry loop re-enters the STARTED state each time the task is re-executed.

## Concepts Covered

- **autoretry_for** — automatic retry when a task raises a specific exception
- **retry_backoff** — exponential delay between retry attempts
- **retry_backoff_max** — upper bound on the backoff delay
- **max_retries** — hard cap on the number of retry attempts
- **soft_time_limit** — raises SoftTimeLimitExceeded inside the task so it can clean up
- **time_limit** — hard kill enforced by the worker if the task exceeds the limit
- **Task states** — PENDING, STARTED, RETRY, SUCCESS, FAILURE, REVOKED

## Next Steps

The next lab builds on this foundation by introducing Flower, the Celery monitoring dashboard, and showing how to inspect task state, retries, and failures through a web UI.
