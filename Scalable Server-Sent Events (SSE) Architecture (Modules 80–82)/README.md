# Scalable Server-Sent Events (SSE) Architecture (Modules 80–82)

Welcome to the **Scalable Server-Sent Events (SSE) Architecture** track. This series of hands-on labs guides you through designing, building, tuning, scaling, and load-testing high-performance persistent streaming architectures in the Poridhi cloud environment and AWS.

---

## Architecture Overview

```mermaid
flowchart TD
    subgraph Clients ["Client Layer"]
        C1["Web Browser Clients (EventSource)"]
        C2["Mobile / IoT Clients"]
        C3["Load Generators (k6 / asyncio)"]
    end

    subgraph Edge ["Edge & Ingress Tier"]
        ALB["AWS Application Load Balancer / Nginx<br/>- Idle Timeout: 3600 seconds<br/>- Unbuffered Streaming (`X-Accel-Buffering: no`)<br/>- Health Checks: `/health` (HTTP 200)"]
    end

    subgraph Fleet ["Compute & Auto Scaling Fleet (ASG)"]
        subgraph InstanceA ["Node A (FastAPI)"]
            AppA["FastAPI /events Stream"]
            SubA["Redis Pub/Sub Subscriber"]
            QueuesA["Local Client Queues"]
        end

        subgraph InstanceB ["Node B (FastAPI)"]
            AppB["FastAPI /events Stream"]
            SubB["Redis Pub/Sub Subscriber"]
            QueuesB["Local Client Queues"]
        end

        CW["CloudWatch Metrics<br/>(ActiveSSEConnections & TargetConnectionCount)"]
    end

    subgraph Messaging ["Distributed Message Bus"]
        Redis[("Redis 7 In-Memory Pub/Sub<br/>Channel: 'sse_events_channel'")]
    end

    Clients --> ALB
    ALB --> InstanceA
    ALB --> InstanceB
    InstanceA -->|"PutMetricData"| CW
    InstanceB -->|"PutMetricData"| CW
    InstanceA <--> Redis
    InstanceB <--> Redis
```

---

## Course Modules and Labs

| Module | Lab | Title | Key Topics & Deliverables |
| :--- | :--- | :--- | :--- |
| **Module 80** | [Lab 56](file:///home/iftakhar/Poridhi/Lab/Scalable%20Server-Sent%20Events%20%28SSE%29%20Architecture%20%28Modules%2080%E2%80%9382%29/Module%2080:%20Scalable%20SSE%20Architecture%20with%20ALB/Lab%2056:%20SSE%20Server%20Implementation/readme.md) | **SSE Server Implementation** | - SSE vs WebSockets comparison and trade-offs<br/>- Asynchronous FastAPI streaming server (`/events`)<br/>- Response headers: `Content-Type: text/event-stream`, `X-Accel-Buffering: no`<br/>- Heartbeat pings and browser `EventSource` dashboard |
| **Module 80** | [Lab 57](file:///home/iftakhar/Poridhi/Lab/Scalable%20Server-Sent%20Events%20%28SSE%29%20Architecture%20%28Modules%2080%E2%80%9382%29/Module%2080:%20Scalable%20SSE%20Architecture%20with%20ALB/Lab%2057:%20ALB%20Configuration%20for%20Long-Lived%20Connections/readme.md) | **ALB Configuration for Long-Lived Connections** | - Resolving 60s idle timeout drops (`504 Gateway Timeout`)<br/>- Configuring AWS ALB `idle_timeout.timeout_seconds = 3600`<br/>- Target Group deregistration delay (connection draining)<br/>- Isolating health check probes (`/health`) from streaming paths<br/>- Production Nginx load balancer emulation stack |
| **Module 81** | [Lab 58](file:///home/iftakhar/Poridhi/Lab/Scalable%20Server-Sent%20Events%20%28SSE%29%20Architecture%20%28Modules%2080%E2%80%9382%29/Module%2081:%20Auto%20Scaling%20and%20Load%20Testing%20for%20SSE/Lab%2058:%20Auto%20Scaling%20Setup%20for%20SSE%20Servers/readme.md) | **Auto Scaling Setup for SSE Servers** | - Why CPU-based scaling fails for streaming connections<br/>- EC2 Launch Template with Linux socket tuning in User Data<br/>- Publishing custom `ActiveSSEConnections` to CloudWatch<br/>- Target Tracking scaling policy on `TargetConnectionCount` |
| **Module 81** | [Lab 59](file:///home/iftakhar/Poridhi/Lab/Scalable%20Server-Sent%20Events%20%28SSE%29%20Architecture%20%28Modules%2080%E2%80%9382%29/Module%2081:%20Auto%20Scaling%20and%20Load%20Testing%20for%20SSE/Lab%2059:%20SSE%20Load%20Testing/readme.md) | **SSE Load Testing** | - Tuning OS socket limits (`ulimit -n 65535`, `somaxconn`)<br/>- Simulating 1,000+ concurrent persistent streams with Python `asyncio`<br/>- k6 load testing script with custom streaming thresholds<br/>- Monitoring event continuity, RAM footprint, and scale-out dynamics |
| **Module 82** | [Lab 60](file:///home/iftakhar/Poridhi/Lab/Scalable%20Server-Sent%20Events%20%28SSE%29%20Architecture%20%28Modules%2080%E2%80%9382%29/Module%2082:%20Redis%20Pub-Sub%20for%20Distributed%20SSE/Lab%2060:%20Distributed%20SSE%20Messaging%20with%20Redis/readme.md) | **Distributed SSE Messaging with Redis** | - Multi-node statefulness dilemma behind load balancers<br/>- Redis Pub/Sub asynchronous message bus integration<br/>- FastAPI in-memory subscriber fan-out to local client queues<br/>- End-to-end multi-node broadcast verification with Docker Compose |

---

## Lab Prerequisites & Tools

The labs in this track utilize standard tools pre-installed in the Poridhi environment:
- **Python 3.10+** (`fastapi`, `uvicorn`, `redis`, `boto3`, `httpx`, `aiohttp`)
- **Docker & Docker Compose** (for multi-container cluster emulation)
- **Nginx** (for reverse proxy and load balancer simulation)
- **AWS CLI** (for AWS ALB and Auto Scaling configuration scripts)
- **k6 / curl** (for unbuffered load testing and streaming verification)
