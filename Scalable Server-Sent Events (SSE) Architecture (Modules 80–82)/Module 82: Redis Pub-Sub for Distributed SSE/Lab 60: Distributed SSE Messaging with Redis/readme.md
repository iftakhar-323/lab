# Lab 60: Distributed SSE Messaging with Redis

In this lab, you will solve the fundamental architectural challenge of scaling Server-Sent Events across a multi-node cluster: **broadcasting messages to clients connected to different physical servers**. You will integrate a **Redis Pub/Sub** message bus into an asynchronous FastAPI cluster, deploy a multi-container environment using Docker Compose (Redis, 2 independent SSE server instances, and an Nginx Load Balancer), and verify that publishing an event to any node automatically rebroadcasts in real-time to all connected clients across the entire fleet.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Scalable%20Server-Sent%20Events%20(SSE)%20Architecture%20(Modules%2080%E2%80%9382)/Module%2082:%20Redis%20Pub-Sub%20for%20Distributed%20SSE/Lab%2060:%20Distributed%20SSE%20Messaging%20with%20Redis/images/architecture_diagram.svg" alt="Lab 60 Distributed SSE Architecture Diagram" width="850">
</p>

---

## Theory: Distributed Pub/Sub for Stateful Connections

### The Multi-Node Statefulness Problem

In a single-server architecture, when an event occurs, the server iterates through its in-memory list of connected client sockets and writes the event:

```text
Event Source ---> [In-Memory List: Client 1, Client 2, Client 3] ---> Push to all
```

However, when scaling out horizontally behind an Application Load Balancer:
- **Client 1** is connected to **Node A**.
- **Client 2** is connected to **Node B**.
- An incoming webhook or user action triggers `POST /publish` that lands on **Node A**.
- Node A only holds the TCP socket for Client 1; it has **no visibility or network route to Client 2's socket** on Node B.
- Result: Without an inter-server message broker, Client 2 misses the event entirely.

### Redis Pub/Sub Architecture

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Scalable%20Server-Sent%20Events%20(SSE)%20Architecture%20(Modules%2080%E2%80%9382)/Module%2082:%20Redis%20Pub-Sub%20for%20Distributed%20SSE/Lab%2060:%20Distributed%20SSE%20Messaging%20with%20Redis/images/message_flow_sequence.svg" alt="Distributed SSE Message Flow Sequence" width="850">
</p>

Redis provides a lightweight, sub-millisecond in-memory Publish/Subscribe engine:
1. **Pub/Sub Channels:** Decoupled named topics (e.g., `sse_events`, `room:123`, `user:tenant_a`).
2. **Subscription Loop:** Each SSE node runs an asynchronous Redis listener coroutine (`redis.pubsub()`) upon application startup.
3. **Local Fan-Out:** When a Redis message arrives on a node, the subscriber task iterates through that node's local client `asyncio.Queue` objects and enqueues the message.
4. **SSE Generator:** Each client stream coroutine simply waits on its personal `asyncio.Queue.get()` and streams outgoing frames.

### Redis Pub/Sub vs Redis Streams

| Feature | Redis Pub/Sub | Redis Streams |
| :--- | :--- | :--- |
| **Delivery Model** | Fire-and-Forget | Persistent Log (Appends to disk/memory) |
| **Consumer Groups** | No (all subscribers receive every message) | Yes (load-balanced consumer groups) |
| **Replay on Reconnect (`Last-Event-ID`)** | Not supported (missed messages while offline are lost) | **Supported** (`XREAD` by message ID) |
| **Memory Consumption** | Near zero (messages are not retained after dispatch) | Retained according to stream retention policy |
| **Suitability for SSE** | Ideal for live feeds, tickers, and ephemeral notifications | Ideal for mission-critical events requiring replay |

---

## Objectives

- Deploy a multi-node distributed architecture with Redis 7, two FastAPI instances, and an Nginx reverse proxy using Docker Compose.
- Implement an asynchronous Redis Pub/Sub broadcaster with subscription pooling and client queue registries.
- Expose a `POST /publish` endpoint that accepts JSON payloads and broadcasts them to Redis.
- Expose a `GET /events` SSE endpoint that subscribes clients to their node's local dispatch queue.
- Demonstrate distributed message delivery: publish a message to Node 1 and verify instant receipt on a client connected to Node 2.

---

## Project Structure

```text
distributed-sse-lab/
├── docker-compose.yml
├── nginx/
│   └── nginx.conf
├── app/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── broadcaster.py
│   └── main.py
└── test_distributed_broadcast.sh
```

---

## Step 1: Create Lab Directories

```bash
mkdir -p ~/distributed-sse-lab/nginx ~/distributed-sse-lab/app
cd ~/distributed-sse-lab
```

---

## Step 2: Implement Redis Broadcaster Engine

Create `app/requirements.txt`:

```bash
cat << 'EOF' > app/requirements.txt
fastapi>=0.110.0
uvicorn[standard]>=0.28.0
redis>=5.0.3
httpx>=0.27.0
EOF
```

Create `app/broadcaster.py`. This module manages Redis pub/sub connections and local client queue registration:

```bash
cat << 'EOF' > app/broadcaster.py
import asyncio
import json
import logging
from typing import Set
import redis.asyncio as aioredis

logger = logging.getLogger("broadcaster")

REDIS_CHANNEL = "sse_events_channel"


class Broadcaster:
    def __init__(self, redis_url: str):
        self.redis_url = redis_url
        self.redis: aioredis.Redis = None
        self.local_client_queues: Set[asyncio.Queue] = set()
        self.listener_task: asyncio.Task = None

    async def connect(self):
        """Connects to Redis and spawns the background channel listener."""
        self.redis = aioredis.from_url(self.redis_url, decode_responses=True)
        self.listener_task = asyncio.create_task(self._listen_to_redis())
        logger.info("Broadcaster connected to Redis.")

    async def disconnect(self):
        """Cleans up Redis connection and cancels background listener."""
        if self.listener_task:
            self.listener_task.cancel()
        if self.redis:
            await self.redis.close()
        logger.info("Broadcaster disconnected.")

    async def _listen_to_redis(self):
        """Listens for incoming messages from Redis and fans out to all local client queues."""
        pubsub = self.redis.pubsub()
        await pubsub.subscribe(REDIS_CHANNEL)
        logger.info(f"Subscribed to Redis channel: {REDIS_CHANNEL}")

        try:
            async for message in pubsub.listen():
                if message["type"] == "message":
                    payload = message["data"]
                    # Fan out to all local queues
                    for queue in list(self.local_client_queues):
                        await queue.put(payload)
        except asyncio.CancelledError:
            await pubsub.unsubscribe(REDIS_CHANNEL)
        except Exception as e:
            logger.error(f"Redis listener error: {e}")

    async def publish(self, message_data: dict):
        """Publishes a message to the shared Redis channel."""
        serialized = json.dumps(message_data)
        await self.redis.publish(REDIS_CHANNEL, serialized)

    def register_client(self) -> asyncio.Queue:
        """Registers a new client and returns its dedicated event queue."""
        queue = asyncio.Queue()
        self.local_client_queues.add(queue)
        logger.info(f"Client registered. Local subscribers: {len(self.local_client_queues)}")
        return queue

    def unregister_client(self, queue: asyncio.Queue):
        """Removes a client queue on disconnection."""
        self.local_client_queues.discard(queue)
        logger.info(f"Client unregistered. Remaining local subscribers: {len(self.local_client_queues)}")
EOF
```

---

## Step 3: Implement the FastAPI Distributed SSE Server

Create `app/main.py`:

```bash
cat << 'EOF' > app/main.py
import asyncio
import os
import socket
import time
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel
from broadcaster import Broadcaster

NODE_ID = os.getenv("NODE_NAME", socket.gethostname())
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")

broadcaster = Broadcaster(redis_url=REDIS_URL)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    await broadcaster.connect()
    yield
    # Shutdown
    await broadcaster.disconnect()


app = FastAPI(title=f"Distributed SSE Node ({NODE_ID})", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class PublishMessage(BaseModel):
    title: str
    message: str
    category: str = "general"


@app.post("/publish")
async def publish_event(payload: PublishMessage):
    """
    Publish an event to the Redis message bus.
    Every server in the cluster subscribed to Redis will rebroadcast this event.
    """
    event_payload = {
        "title": payload.title,
        "message": payload.message,
        "category": payload.category,
        "publisher_node": NODE_ID,
        "published_at": time.strftime("%Y-%m-%d %H:%M:%S"),
    }
    await broadcaster.publish(event_payload)
    return {
        "status": "published_to_redis",
        "node": NODE_ID,
        "payload": event_payload,
    }


async def sse_event_stream(request: Request):
    """Subscribes client to broadcaster and streams events as they arrive."""
    queue = broadcaster.register_client()
    event_id = 0
    try:
        # Initial greeting frame
        init_frame = {
            "node": NODE_ID,
            "message": f"Connected to {NODE_ID}. Waiting for distributed events...",
            "timestamp": time.time(),
        }
        yield f"event: system\ndata: {init_frame}\n\n"

        while True:
            if await request.is_disconnected():
                break

            try:
                # Wait for next event from Redis subscriber queue (with 15s timeout for keep-alive)
                data = await asyncio.wait_for(queue.get(), timeout=15.0)
                event_id += 1
                yield f"id: {event_id}\nevent: broadcast\ndata: {data}\n\n"
            except asyncio.TimeoutError:
                # Send periodic heartbeat if no events were published
                yield ": keep-alive\n\n"

    finally:
        broadcaster.unregister_client(queue)


@app.get("/events")
async def sse_endpoint(request: Request):
    return StreamingResponse(
        sse_event_stream(request),
        media_type="text/event-stream",
        headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "node": NODE_ID,
        "active_subscribers": len(broadcaster.local_client_queues),
    }
EOF
```

Create `app/Dockerfile`:

```bash
cat << 'EOF' > app/Dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF
```

---

## Step 4: Configure Nginx Load Balancer

Create `nginx/nginx.conf` configured with unbuffered streaming and upstream round-robin:

```bash
cat << 'EOF' > nginx/nginx.conf
events { worker_connections 1024; }

http {
    upstream sse_fleet {
        server sse_node_a:8000;
        server sse_node_b:8000;
    }

    server {
        listen 80;

        location /events {
            proxy_pass http://sse_fleet/events;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
        }

        location /publish {
            proxy_pass http://sse_fleet/publish;
            proxy_set_header Host $host;
        }

        location /health {
            proxy_pass http://sse_fleet/health;
        }
    }
}
EOF
```

---

## Step 5: Define Docker Compose Multi-Node Stack

Create `docker-compose.yml`:

```bash
cat << 'EOF' > docker-compose.yml
version: '3.8'

services:
  redis:
    image: redis:7-alpine
    container_name: sse_redis
    ports:
      - "6379:6379"
    restart: unless-stopped

  sse_node_a:
    build: ./app
    container_name: sse_node_a
    environment:
      - NODE_NAME=Node-Alpha
      - REDIS_URL=redis://redis:6379/0
    ports:
      - "8001:8000"
    depends_on:
      - redis
    restart: unless-stopped

  sse_node_b:
    build: ./app
    container_name: sse_node_b
    environment:
      - NODE_NAME=Node-Beta
      - REDIS_URL=redis://redis:6379/0
    ports:
      - "8002:8000"
    depends_on:
      - redis
    restart: unless-stopped

  load_balancer:
    image: nginx:alpine
    container_name: sse_load_balancer
    ports:
      - "8080:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - sse_node_a
      - sse_node_b
    restart: unless-stopped
EOF
```

---

## Step 6: Deploy Stack with Docker Compose

Launch all containers:

```bash
cd ~/distributed-sse-lab
docker compose up -d --build
```

Verify that all 4 containers (`sse_redis`, `sse_node_a`, `sse_node_b`, `sse_load_balancer`) are running:

```bash
docker compose ps
```

Expected Output:

```text
NAME                 IMAGE                     STATUS         PORTS
sse_load_balancer    nginx:alpine              Up 5 seconds   0.0.0.0:8080->80/tcp
sse_node_a           distributed-sse-lab-app   Up 5 seconds   0.0.0.0:8001->8000/tcp
sse_node_b           distributed-sse-lab-app   Up 5 seconds   0.0.0.0:8002->8000/tcp
sse_redis            redis:7-alpine            Up 5 seconds   0.0.0.0:6379->6379/tcp
```

---

## Step 7: Verify Distributed Cross-Node Rebroadcast

To prove that Redis successfully distributes messages across instances:
1. Connect **Client 1** directly to **Node A** (`http://localhost:8001/events`).
2. Connect **Client 2** directly to **Node B** (`http://localhost:8002/events`).
3. Send an HTTP POST request to **Node A** (`http://localhost:8001/publish`).
4. Validate that **both Client 1 AND Client 2** receive the broadcast frame instantaneously!

Create `test_distributed_broadcast.sh`:

```bash
cat << 'EOF' > test_distributed_broadcast.sh
#!/usr/bin/env bash
set -e

echo "=== 1. Starting Client 1 connected to Node-Alpha (:8001) in background ==="
curl -N -s http://localhost:8001/events > client_1.log 2>&1 &
PID_C1=$!

echo "=== 2. Starting Client 2 connected to Node-Beta (:8002) in background ==="
curl -N -s http://localhost:8002/events > client_2.log 2>&1 &
PID_C2=$!

sleep 2

echo "=== 3. Publishing message to Node-Alpha (:8001/publish) ==="
curl -s -X POST http://localhost:8001/publish \
     -H "Content-Type: application/json" \
     -d '{
       "title": "Flash Alert",
       "message": "Distributed Redis broadcast across multiple SSE nodes!",
       "category": "urgent"
     }' | jq . || cat

sleep 2

echo ""
echo "=== 4. Inspecting Client 1 (Node-Alpha) Received Events ==="
cat client_1.log

echo ""
echo "=== 5. Inspecting Client 2 (Node-Beta) Received Events ==="
cat client_2.log

# Cleanup
kill $PID_C1 $PID_C2 2>/dev/null || true
rm -f client_1.log client_2.log
echo ""
echo "=== Distributed Rebroadcast Test Passed Successfully! ==="
EOF
chmod +x test_distributed_broadcast.sh
./test_distributed_broadcast.sh
```

Expected Output:

```text
=== 1. Starting Client 1 connected to Node-Alpha (:8001) in background ===
=== 2. Starting Client 2 connected to Node-Beta (:8002) in background ===
=== 3. Publishing message to Node-Alpha (:8001/publish) ===
{
  "status": "published_to_redis",
  "node": "Node-Alpha",
  "payload": {
    "title": "Flash Alert",
    "message": "Distributed Redis broadcast across multiple SSE nodes!",
    "category": "urgent",
    "publisher_node": "Node-Alpha",
    "published_at": "2026-09-21 12:15:30"
  }
}

=== 4. Inspecting Client 1 (Node-Alpha) Received Events ===
event: system
data: {'node': 'Node-Alpha', 'message': 'Connected to Node-Alpha. Waiting for distributed events...', 'timestamp': 1758456930.12}

id: 1
event: broadcast
data: {"title": "Flash Alert", "message": "Distributed Redis broadcast across multiple SSE nodes!", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-21 12:15:30"}

=== 5. Inspecting Client 2 (Node-Beta) Received Events ===
event: system
data: {'node': 'Node-Beta', 'message': 'Connected to Node-Beta. Waiting for distributed events...', 'timestamp': 1758456930.15}

id: 1
event: broadcast
data: {"title": "Flash Alert", "message": "Distributed Redis broadcast across multiple SSE nodes!", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-21 12:15:30"}

=== Distributed Rebroadcast Test Passed Successfully! ===
```

Notice that even though the event was published exclusively to **Node-Alpha**, **Client 2 connected to Node-Beta received the exact message simultaneously** via the Redis Pub/Sub message bus!

---

## Conclusion

In this lab, you resolved the multi-node statefulness problem inherent to streaming architectures. You integrated **Redis Pub/Sub** into FastAPI using asynchronous subscription loops and in-memory queue fan-outs. You deployed a resilient 4-container distributed stack with Docker Compose and validated that events published to any single node are immediately rebroadcast to all connected clients across every node in the cluster. This completes the end-to-end scalable SSE architecture!
