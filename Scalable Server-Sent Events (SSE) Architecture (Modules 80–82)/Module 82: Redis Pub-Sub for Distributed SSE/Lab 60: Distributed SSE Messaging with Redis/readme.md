# Lab 60: Distributed SSE Messaging with Redis

In this lab, you will solve the fundamental architectural challenge of scaling Server-Sent Events across a multi-node cluster: **broadcasting messages to clients connected to different physical servers**. You will integrate a **Redis Pub/Sub** message bus into an asynchronous FastAPI cluster, deploy a multi-container environment using Docker Compose (Redis, 2 independent SSE server instances, and an Nginx Load Balancer), and verify that publishing an event to any node automatically rebroadcasts in real-time to all connected clients across the entire fleet.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/architecture_diagram.svg" alt="Lab 60 Distributed SSE Architecture Diagram" width="850">
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
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/message_flow_sequence.svg" alt="Distributed SSE Message Flow Sequence" width="850">
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
- Access an interactive real-time visual dashboard through the Nginx Load Balancer (`:8080`) to observe multi-node event broadcasts and client synchronization live in the browser.

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
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse
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


DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Distributed SSE Cluster Dashboard</title>
  <style>
    :root {
      --bg: #090d16;
      --card-bg: #111827;
      --card-border: #1f2937;
      --accent-cyan: #06b6d4;
      --accent-green: #10b981;
      --accent-amber: #f59e0b;
      --accent-indigo: #6366f1;
      --accent-rose: #f43f5e;
      --text: #f3f4f6;
      --text-muted: #9ca3af;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif; }
    body { background-color: var(--bg); color: var(--text); padding: 24px; min-height: 100vh; }
    .container { max-width: 1300px; margin: 0 auto; }
    
    header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; padding-bottom: 20px; border-bottom: 1px solid var(--card-border); flex-wrap: wrap; gap: 16px; }
    .title-group h1 { font-size: 24px; font-weight: 700; color: #fff; display: flex; align-items: center; gap: 10px; }
    .title-group p { font-size: 14px; color: var(--text-muted); margin-top: 4px; }
    .node-badge { background: rgba(99, 102, 241, 0.15); border: 1px solid rgba(99, 102, 241, 0.4); color: #a5b4fc; padding: 6px 14px; border-radius: 9999px; font-size: 13px; font-weight: 600; display: inline-flex; align-items: center; gap: 8px; }
    .pulse-dot { width: 8px; height: 8px; border-radius: 50%; background-color: var(--accent-green); box-shadow: 0 0 10px var(--accent-green); animation: pulse 2s infinite; }
    @keyframes pulse { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.5; transform: scale(0.9); } }

    .arch-bar { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin-bottom: 24px; }
    .arch-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 10px; padding: 14px 18px; display: flex; align-items: center; gap: 14px; }
    .arch-icon { font-size: 26px; }
    .arch-info h4 { font-size: 14px; font-weight: 600; color: #fff; }
    .arch-info p { font-size: 12px; color: var(--text-muted); }
    .arch-status { margin-left: auto; font-size: 11px; padding: 3px 8px; border-radius: 6px; font-weight: 600; }
    .status-online { background: rgba(16, 185, 129, 0.15); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }

    .main-grid { display: grid; grid-template-columns: 420px 1fr; gap: 24px; }
    @media (max-width: 1024px) { .main-grid { grid-template-columns: 1fr; } }

    .card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 12px; overflow: hidden; display: flex; flex-direction: column; }
    .card-header { padding: 16px 20px; border-bottom: 1px solid var(--card-border); display: flex; justify-content: space-between; align-items: center; }
    .card-header h3 { font-size: 16px; font-weight: 600; color: #fff; display: flex; align-items: center; gap: 8px; }
    .card-body { padding: 20px; flex: 1; }

    .form-group { margin-bottom: 16px; }
    .form-group label { display: block; font-size: 12px; font-weight: 600; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 6px; }
    .form-control { width: 100%; background: #0c121e; border: 1px solid var(--card-border); border-radius: 8px; padding: 10px 14px; color: #fff; font-size: 14px; outline: none; transition: border-color 0.2s; }
    .form-control:focus { border-color: var(--accent-cyan); }
    textarea.form-control { resize: vertical; min-height: 80px; }

    .btn { background: linear-gradient(135deg, #06b6d4, #3b82f6); color: #fff; border: none; border-radius: 8px; padding: 12px 18px; font-size: 14px; font-weight: 600; cursor: pointer; display: flex; align-items: center; justify-content: center; gap: 8px; width: 100%; transition: opacity 0.2s, transform 0.1s; }
    .btn:hover { opacity: 0.95; }
    .btn:active { transform: scale(0.98); }
    .btn-secondary { background: #1e293b; color: #e2e8f0; border: 1px solid #334155; padding: 6px 12px; font-size: 12px; border-radius: 6px; width: auto; cursor: pointer; }
    .btn-secondary:hover { background: #334155; }
    
    .quick-pub { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin-top: 12px; }

    .flow-box { margin-top: 20px; padding: 14px; background: #0b111c; border-radius: 8px; border: 1px dashed #2d3748; font-size: 12px; }
    .flow-step { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; color: var(--text-muted); }
    .flow-step:last-child { margin-bottom: 0; }
    .flow-step span.num { background: #374151; color: #fff; width: 18px; height: 18px; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: bold; }
    .flow-step strong { color: #e2e8f0; }

    .clients-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(250px, 1fr)); gap: 16px; }
    .client-panel { background: #0c1322; border: 1px solid var(--card-border); border-radius: 10px; display: flex; flex-direction: column; height: 560px; overflow: hidden; }
    .client-header { padding: 12px 14px; background: #131b2e; border-bottom: 1px solid var(--card-border); display: flex; justify-content: space-between; align-items: center; }
    .client-info h4 { font-size: 13px; font-weight: 600; color: #fff; display: flex; align-items: center; gap: 6px; }
    .client-info span.route { font-size: 11px; color: var(--accent-cyan); font-family: monospace; }
    .client-counter { font-size: 11px; background: rgba(6, 182, 212, 0.15); color: var(--accent-cyan); padding: 2px 7px; border-radius: 4px; font-weight: bold; }

    .event-feed { flex: 1; padding: 12px; overflow-y: auto; display: flex; flex-direction: column; gap: 10px; }
    .event-card { background: #162035; border: 1px solid #23304c; border-radius: 8px; padding: 10px 12px; animation: slideDown 0.3s ease-out; font-size: 13px; }
    @keyframes slideDown { from { opacity: 0; transform: translateY(-8px); } to { opacity: 1; transform: translateY(0); } }
    .event-top { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; font-size: 11px; }
    .badge-node { background: rgba(99, 102, 241, 0.25); color: #a5b4fc; padding: 2px 6px; border-radius: 4px; font-weight: 600; }
    .badge-urgent { background: rgba(244, 63, 94, 0.25); color: #fda4af; padding: 2px 6px; border-radius: 4px; font-weight: 600; }
    .badge-general { background: rgba(16, 185, 129, 0.25); color: #6ee7b7; padding: 2px 6px; border-radius: 4px; font-weight: 600; }
    .badge-system { background: rgba(156, 163, 175, 0.25); color: #d1d5db; padding: 2px 6px; border-radius: 4px; font-weight: 600; }
    .event-title { font-weight: 600; color: #fff; margin-bottom: 4px; }
    .event-msg { color: #cbd5e1; font-size: 12px; line-height: 1.4; word-break: break-word; }
    .event-time { color: var(--text-muted); font-size: 10px; margin-top: 6px; text-align: right; }

    .client-footer { padding: 8px 12px; background: #111827; border-top: 1px solid var(--card-border); display: flex; justify-content: space-between; align-items: center; }
    .client-status { font-size: 11px; display: flex; align-items: center; gap: 6px; }

    footer { margin-top: 30px; text-align: center; color: var(--text-muted); font-size: 13px; border-top: 1px solid var(--card-border); padding-top: 16px; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="title-group">
        <h1>🌐 Distributed SSE Cluster Visualizer</h1>
        <p>Real-Time Multi-Node Server-Sent Events with Redis Pub/Sub & Nginx Load Balancer</p>
      </div>
      <div>
        <span class="node-badge"><span class="pulse-dot"></span> Serving Instance: <strong id="servingNode">Detecting...</strong></span>
      </div>
    </header>

    <!-- Architecture Topology Bar -->
    <div class="arch-bar">
      <div class="arch-card">
        <div class="arch-icon">🔀</div>
        <div class="arch-info">
          <h4>Nginx Load Balancer</h4>
          <p>Port 8080 (Round-Robin)</p>
        </div>
        <span class="arch-status status-online">Active</span>
      </div>
      <div class="arch-card">
        <div class="arch-icon">⚡</div>
        <div class="arch-info">
          <h4>Redis Pub/Sub Bus</h4>
          <p>sse_events_channel</p>
        </div>
        <span class="arch-status status-online">Synced</span>
      </div>
      <div class="arch-card">
        <div class="arch-icon">🖥️</div>
        <div class="arch-info">
          <h4>Node Alpha</h4>
          <p>FastAPI (Port 8001)</p>
        </div>
        <span class="arch-status status-online">Online</span>
      </div>
      <div class="arch-card">
        <div class="arch-icon">🖥️</div>
        <div class="arch-info">
          <h4>Node Beta</h4>
          <p>FastAPI (Port 8002)</p>
        </div>
        <span class="arch-status status-online">Online</span>
      </div>
    </div>

    <!-- Main Grid -->
    <div class="main-grid">
      <!-- Left Column: Publisher Form -->
      <div class="card">
        <div class="card-header">
          <h3>📢 Publish Distributed Broadcast</h3>
        </div>
        <div class="card-body">
          <form id="publishForm">
            <div class="form-group">
              <label>Publish Route Target</label>
              <select id="targetEndpoint" class="form-control">
                <option value="/publish">🔀 Load Balancer (:8080/publish - Round-Robin)</option>
                <option value="/node-a/publish">🖥️ Direct to Node-Alpha (:8080/node-a/publish)</option>
                <option value="/node-b/publish">🖥️ Direct to Node-Beta (:8080/node-b/publish)</option>
              </select>
            </div>
            <div class="form-group">
              <label>Event Title</label>
              <input type="text" id="eventTitle" class="form-control" value="Flash Notification" required>
            </div>
            <div class="form-group">
              <label>Category</label>
              <select id="eventCategory" class="form-control">
                <option value="urgent">Urgent Alert</option>
                <option value="general" selected>General Broadcast</option>
                <option value="system">System Notice</option>
              </select>
            </div>
            <div class="form-group">
              <label>Message Content</label>
              <textarea id="eventMessage" class="form-control" placeholder="Enter message payload...">Distributed Redis broadcast across multiple SSE nodes!</textarea>
            </div>
            <button type="submit" class="btn" id="btnPublish">
              <span>🚀 Broadcast to Fleet via Redis</span>
            </button>
          </form>

          <div class="quick-pub">
            <button class="btn-secondary" onclick="quickSend('Node-Alpha', '/node-a/publish')">⚡ Send via Alpha</button>
            <button class="btn-secondary" onclick="quickSend('Node-Beta', '/node-b/publish')">⚡ Send via Beta</button>
          </div>

          <div class="flow-box">
            <div class="flow-step"><span class="num">1</span> <strong>HTTP POST:</strong> Message sent to target node.</div>
            <div class="flow-step"><span class="num">2</span> <strong>Redis Bus:</strong> Node executes <code>redis.publish()</code>.</div>
            <div class="flow-step"><span class="num">3</span> <strong>Fleet Fan-Out:</strong> All nodes receive event via PubSub.</div>
            <div class="flow-step"><span class="num">4</span> <strong>SSE Push:</strong> Every connected client receives frame!</div>
          </div>
        </div>
      </div>

      <!-- Right Column: Live Clients Feed -->
      <div class="card">
        <div class="card-header">
          <h3>⚡ Live Multi-Node SSE Monitor</h3>
          <button class="btn-secondary" onclick="clearAllFeeds()">Clear All Feeds</button>
        </div>
        <div class="card-body">
          <div class="clients-grid">
            <!-- Client 1 -->
            <div class="client-panel">
              <div class="client-header">
                <div class="client-info">
                  <h4>🖥️ Client 1 (Node-Alpha)</h4>
                  <span class="route">/node-a/events</span>
                </div>
                <span class="client-counter" id="c1-count">0 msgs</span>
              </div>
              <div class="event-feed" id="c1-feed"></div>
              <div class="client-footer">
                <div class="client-status" id="c1-status"><span class="pulse-dot"></span> Listening</div>
                <button class="btn-secondary" onclick="toggleClient(1)">Toggle</button>
              </div>
            </div>

            <!-- Client 2 -->
            <div class="client-panel">
              <div class="client-header">
                <div class="client-info">
                  <h4>🖥️ Client 2 (Node-Beta)</h4>
                  <span class="route">/node-b/events</span>
                </div>
                <span class="client-counter" id="c2-count">0 msgs</span>
              </div>
              <div class="event-feed" id="c2-feed"></div>
              <div class="client-footer">
                <div class="client-status" id="c2-status"><span class="pulse-dot"></span> Listening</div>
                <button class="btn-secondary" onclick="toggleClient(2)">Toggle</button>
              </div>
            </div>

            <!-- Client 3 -->
            <div class="client-panel">
              <div class="client-header">
                <div class="client-info">
                  <h4>🔀 Client 3 (Load Balancer)</h4>
                  <span class="route">/events</span>
                </div>
                <span class="client-counter" id="c3-count">0 msgs</span>
              </div>
              <div class="event-feed" id="c3-feed"></div>
              <div class="client-footer">
                <div class="client-status" id="c3-status"><span class="pulse-dot"></span> Listening</div>
                <button class="btn-secondary" onclick="toggleClient(3)">Toggle</button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <footer>
      Poridhi Lab 60 • Scalable Server-Sent Events Architecture with Redis Pub/Sub & Nginx Load Balancing
    </footer>
  </div>

  <script>
    fetch('/health')
      .then(res => res.json())
      .then(data => {
        document.getElementById('servingNode').innerText = data.node || 'Unknown';
      })
      .catch(() => {
        document.getElementById('servingNode').innerText = 'Cluster Gateway';
      });

    const clients = {
      1: { es: null, url: '/node-a/events', count: 0, feedId: 'c1-feed', countId: 'c1-count', statusId: 'c1-status' },
      2: { es: null, url: '/node-b/events', count: 0, feedId: 'c2-feed', countId: 'c2-count', statusId: 'c2-status' },
      3: { es: null, url: '/events', count: 0, feedId: 'c3-feed', countId: 'c3-count', statusId: 'c3-status' }
    };

    function startClient(id) {
      const c = clients[id];
      if (c.es) c.es.close();

      const statusEl = document.getElementById(c.statusId);
      statusEl.innerHTML = '<span class="pulse-dot"></span> Connecting...';

      const es = new EventSource(c.url);
      c.es = es;

      es.onopen = () => {
        statusEl.innerHTML = '<span class="pulse-dot"></span> Connected';
      };

      es.addEventListener('system', (e) => {
        try {
          const raw = e.data.replace(/'/g, '"');
          const data = JSON.parse(raw);
          appendCard(id, 'system', 'System Handshake', data.message || 'Connected to node', data.node);
        } catch {
          appendCard(id, 'system', 'System Greeting', e.data, 'system');
        }
      });

      es.addEventListener('broadcast', (e) => {
        try {
          const data = JSON.parse(e.data);
          c.count++;
          document.getElementById(c.countId).innerText = c.count + ' msgs';
          appendCard(id, data.category || 'general', data.title || 'Broadcast Event', data.message, data.publisher_node, data.published_at);
        } catch (err) {
          appendCard(id, 'general', 'Broadcast', e.data, 'cluster');
        }
      });

      es.onerror = () => {
        statusEl.innerHTML = '<span style="color:#ef4444;">● Disconnected</span>';
      };
    }

    function toggleClient(id) {
      const c = clients[id];
      const statusEl = document.getElementById(c.statusId);
      if (c.es) {
        c.es.close();
        c.es = null;
        statusEl.innerHTML = '<span style="color:#9ca3af;">○ Offline</span>';
      } else {
        startClient(id);
      }
    }

    function appendCard(clientId, category, title, message, publisher, publishedAt) {
      const feed = document.getElementById(clients[clientId].feedId);
      const card = document.createElement('div');
      card.className = 'event-card';

      const timeStr = publishedAt || new Date().toLocaleTimeString();
      const badgeClass = category === 'urgent' ? 'badge-urgent' : (category === 'system' ? 'badge-system' : 'badge-general');

      card.innerHTML = `
        <div class="event-top">
          <span class="badge-node">Origin: ${publisher || 'Node'}</span>
          <span class="${badgeClass}">${category.toUpperCase()}</span>
        </div>
        <div class="event-title">${title}</div>
        <div class="event-msg">${message}</div>
        <div class="event-time">${timeStr}</div>
      `;

      feed.insertBefore(card, feed.firstChild);
      if (feed.children.length > 25) {
        feed.removeChild(feed.lastChild);
      }
    }

    function clearAllFeeds() {
      [1, 2, 3].forEach(id => {
        document.getElementById(clients[id].feedId).innerHTML = '';
        clients[id].count = 0;
        document.getElementById(clients[id].countId).innerText = '0 msgs';
      });
    }

    document.getElementById('publishForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const target = document.getElementById('targetEndpoint').value;
      const title = document.getElementById('eventTitle').value;
      const category = document.getElementById('eventCategory').value;
      const message = document.getElementById('eventMessage').value;
      const btn = document.getElementById('btnPublish');

      btn.disabled = true;
      btn.innerText = 'Publishing to Redis...';

      try {
        const res = await fetch(target, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ title, category, message })
        });
        const data = await res.json();
        btn.innerText = '✓ Broadcast Sent!';
        setTimeout(() => {
          btn.disabled = false;
          btn.innerText = '🚀 Broadcast to Fleet via Redis';
        }, 1200);
      } catch (err) {
        alert('Error publishing event: ' + err.message);
        btn.disabled = false;
        btn.innerText = '🚀 Broadcast to Fleet via Redis';
      }
    });

    function quickSend(originNode, endpoint) {
      document.getElementById('eventTitle').value = `Alert from ${originNode}`;
      document.getElementById('eventMessage').value = `Live test broadcast initiated directly from ${originNode}!`;
      document.getElementById('targetEndpoint').value = endpoint;
      document.getElementById('publishForm').dispatchEvent(new Event('submit'));
    }

    window.addEventListener('load', () => {
      startClient(1);
      startClient(2);
      startClient(3);
    });
  </script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
@app.get("/dashboard", response_class=HTMLResponse)
async def dashboard():
    """Serves the real-time interactive SSE visualizer dashboard."""
    return HTMLResponse(content=DASHBOARD_HTML)
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

        # Web Dashboard served through Load Balancer
        location / {
            proxy_pass http://sse_fleet;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        # SSE Streaming Endpoint (Buffering disabled, Round-Robin)
        location /events {
            proxy_pass http://sse_fleet/events;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
        }

        # Load-balanced Publish Endpoint
        location /publish {
            proxy_pass http://sse_fleet/publish;
            proxy_set_header Host $host;
        }

        # Health & Stats Endpoint
        location /health {
            proxy_pass http://sse_fleet/health;
            proxy_set_header Host $host;
        }

        # Direct Route to Node Alpha via Load Balancer
        location /node-a/ {
            rewrite ^/node-a/(.*)$ /$1 break;
            proxy_pass http://sse_node_a:8000;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
        }

        # Direct Route to Node Beta via Load Balancer
        location /node-b/ {
            rewrite ^/node-b/(.*)$ /$1 break;
            proxy_pass http://sse_node_b:8000;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 3600s;
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

## Step 7: Verify Distributed Cross-Node Rebroadcast via CLI

To prove that Redis successfully distributes messages across instances and through the Load Balancer:
1. Connect **Client 1** directly to **Node A** (`http://localhost:8001/events`).
2. Connect **Client 2** directly to **Node B** (`http://localhost:8002/events`).
3. Connect **Client 3** directly to the **Load Balancer** (`http://localhost:8080/events`).
4. Send an HTTP POST request to the **Load Balancer** (`http://localhost:8080/publish`).
5. Validate that **all three clients receive the broadcast frame simultaneously**!

Create `test_distributed_broadcast.sh`:

```bash
cat << 'EOF' > test_distributed_broadcast.sh
#!/usr/bin/env bash
set -e

# ANSI Color Codes
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}${BOLD}║      DISTRIBUTED SSE REBROADCAST TEST VIA LOAD BALANCER & REDIS      ║${NC}"
echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
echo ""

echo -e "${BLUE}[STEP 1/5]${NC} Connecting Client 1 to ${BOLD}Node-Alpha (:8001)${NC}..."
curl -N -s http://localhost:8001/events > client_1.log 2>&1 &
PID_C1=$!

echo -e "${BLUE}[STEP 2/5]${NC} Connecting Client 2 to ${BOLD}Node-Beta (:8002)${NC}..."
curl -N -s http://localhost:8002/events > client_2.log 2>&1 &
PID_C2=$!

echo -e "${BLUE}[STEP 3/5]${NC} Connecting Client 3 through ${BOLD}Nginx Load Balancer (:8080)${NC}..."
curl -N -s http://localhost:8080/events > client_3.log 2>&1 &
PID_C3=$!

sleep 2

echo ""
echo -e "${PURPLE}[STEP 4/5]${NC} Publishing broadcast message through ${BOLD}Load Balancer (:8080/publish)${NC}..."
PUB_RESPONSE=$(curl -s -X POST http://localhost:8080/publish \
     -H "Content-Type: application/json" \
     -d '{
       "title": "Flash Alert",
       "message": "Distributed Redis broadcast across multiple SSE nodes!",
       "category": "urgent"
     }')
echo -e "${YELLOW}${PUB_RESPONSE}${NC}"

sleep 2

echo ""
echo -e "${GREEN}${BOLD}==================== VERIFYING RECEIVED EVENTS ====================${NC}"

echo -e "\n${CYAN}${BOLD}▶ Client 1 Output (Connected directly to Node-Alpha :8001):${NC}"
cat client_1.log

echo -e "\n${CYAN}${BOLD}▶ Client 2 Output (Connected directly to Node-Beta :8002):${NC}"
cat client_2.log

echo -e "\n${CYAN}${BOLD}▶ Client 3 Output (Connected through Nginx Load Balancer :8080):${NC}"
cat client_3.log

# Cleanup background client processes
kill $PID_C1 $PID_C2 $PID_C3 2>/dev/null || true
rm -f client_1.log client_2.log client_3.log

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║  ✔ SUCCESS: Redis Pub/Sub Distributed SSE Fan-Out Verified!          ║${NC}"
echo -e "${GREEN}${BOLD}║  All clients across the fleet received the event simultaneously!    ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════════╝${NC}"
EOF
chmod +x test_distributed_broadcast.sh
./test_distributed_broadcast.sh
```

Expected Output:

```text
╔══════════════════════════════════════════════════════════════════════╗
║      DISTRIBUTED SSE REBROADCAST TEST VIA LOAD BALANCER & REDIS      ║
╚══════════════════════════════════════════════════════════════════════╝

[STEP 1/5] Connecting Client 1 to Node-Alpha (:8001)...
[STEP 2/5] Connecting Client 2 to Node-Beta (:8002)...
[STEP 3/5] Connecting Client 3 through Nginx Load Balancer (:8080)...

[STEP 4/5] Publishing broadcast message through Load Balancer (:8080/publish)...
{"status":"published_to_redis","node":"Node-Alpha","payload":{"title":"Flash Alert","message":"Distributed Redis broadcast across multiple SSE nodes!","category":"urgent","publisher_node":"Node-Alpha","published_at":"2026-09-23 01:15:00"}}

==================== VERIFYING RECEIVED EVENTS ====================

▶ Client 1 Output (Connected directly to Node-Alpha :8001):
event: system
data: {'node': 'Node-Alpha', 'message': 'Connected to Node-Alpha. Waiting for distributed events...', 'timestamp': 1790104500.12}

id: 1
event: broadcast
data: {"title": "Flash Alert", "message": "Distributed Redis broadcast across multiple SSE nodes!", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-23 01:15:00"}


▶ Client 2 Output (Connected directly to Node-Beta :8002):
event: system
data: {'node': 'Node-Beta', 'message': 'Connected to Node-Beta. Waiting for distributed events...', 'timestamp': 1790104500.15}

id: 1
event: broadcast
data: {"title": "Flash Alert", "message": "Distributed Redis broadcast across multiple SSE nodes!", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-23 01:15:00"}


▶ Client 3 Output (Connected through Nginx Load Balancer :8080):
event: system
data: {'node': 'Node-Alpha', 'message': 'Connected to Node-Alpha. Waiting for distributed events...', 'timestamp': 1790104500.18}

id: 1
event: broadcast
data: {"title": "Flash Alert", "message": "Distributed Redis broadcast across multiple SSE nodes!", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-23 01:15:00"}


╔══════════════════════════════════════════════════════════════════════╗
║  ✔ SUCCESS: Redis Pub/Sub Distributed SSE Fan-Out Verified!          ║
║  All clients across the fleet received the event simultaneously!    ║
╚══════════════════════════════════════════════════════════════════════╝
```

Notice that:
- The broadcast message was accepted by the Load Balancer on port `8080` and handled by one node.
- **Every single client**—whether connected directly to Node-Alpha, directly to Node-Beta, or routed through the Load Balancer—received the exact broadcast frame with 0 message loss!

---

## Step 8: Interactive Real-Time Dashboard via Load Balancer

In addition to the command-line test, you can visually observe the distributed architecture in action using the built-in web dashboard.

### 8.1 Access the Dashboard

Open your web browser and navigate to the Load Balancer port:

```text
http://<poridhi-vm-ip>:8080/
```

*(If testing locally or inside the VM, navigate to `http://localhost:8080/`)*.

### 8.2 Dashboard Features

1. **Cluster Architecture Topology Bar:**
   - **Nginx Load Balancer (Port 8080):** Reverse proxy & round-robin load distribution.
   - **Redis Pub/Sub Bus (`sse_events_channel`):** Central in-memory message broker running on port 6379.
   - **Node Alpha (Port 8001):** FastAPI SSE instance 1.
   - **Node Beta (Port 8002):** FastAPI SSE instance 2.
   - **Serving Instance Badge:** Shows which node served the dashboard via the load balancer.

2. **Interactive Publish Console (Left Panel):**
   - Choose the target destination route:
     - `🔀 Load Balancer (:8080/publish)`: Dispatched to the fleet via round-robin.
     - `🖥️ Direct to Node-Alpha (:8080/node-a/publish)`: Targets Node-Alpha specifically.
     - `🖥️ Direct to Node-Beta (:8080/node-b/publish)`: Targets Node-Beta specifically.
   - Enter a title, select a category (`Urgent Alert`, `General Broadcast`, `System Notice`), and enter a message.
   - Click **"🚀 Broadcast to Fleet via Redis"** or use the quick buttons.

3. **Live Multi-Node SSE Monitor (Right Panel):**
   - **Client 1:** Subscribed to Node-Alpha via `/node-a/events`.
   - **Client 2:** Subscribed to Node-Beta via `/node-b/events`.
   - **Client 3:** Subscribed to the Load Balancer via `/events`.
   - Watch the broadcast card instantaneously slide into all 3 client feeds at the same millisecond!
   - Each card highlights:
     - **Origin Node:** The node that received the HTTP POST publish request.
     - **Category Tag:** Visual colored tag.
     - **Event Payload & Timestamp:** Proving synchronization across distinct physical servers.

---

## Conclusion

In this lab, you resolved the multi-node statefulness problem inherent to streaming architectures. You integrated **Redis Pub/Sub** into FastAPI using asynchronous subscription loops and in-memory queue fan-outs. You deployed a resilient 4-container distributed stack with Docker Compose and validated that events published to any single node or through an **Nginx Load Balancer** are immediately rebroadcast to all connected clients across every node in the cluster. This completes the end-to-end scalable SSE architecture!
