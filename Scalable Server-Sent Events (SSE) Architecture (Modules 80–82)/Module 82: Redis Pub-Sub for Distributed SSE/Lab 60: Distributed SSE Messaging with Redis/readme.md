# Lab 60: Distributed SSE Messaging with Redis

In this lab, you will build a distributed Server-Sent Events (SSE) system backed by a Redis Pub/Sub message broker and fronted by an Nginx reverse proxy. You will deploy two asynchronous FastAPI server nodes, an Nginx load balancer exposing `/events` and `/publish`, and a central Redis 7 container using Docker Compose. When an event is published to any single node or through the load balancer, Redis distributes that message to all cluster nodes so every connected subscriber receives it in real time.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/architecture_diagram.svg" alt="Lab 60 Distributed SSE Architecture Diagram" width="850">
</p>

---

## Concepts

The table below defines the core components and architectural terms used in this lab:

| Term                                    | Description                                                                                                                                                                                      |
| :-------------------------------------- | :----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Server-Sent Events (SSE)**      | A unidirectional HTTP protocol where the server keeps an open HTTP connection and pushes text-formatted events to the client.                                                                    |
| **Multi-Node Statefulness**       | The architectural condition where long-lived TCP connections are held across separate server instances, preventing one server from pushing data directly to clients connected to another server. |
| **Redis Pub/Sub**                 | An in-memory publish/subscribe messaging engine that enables decoupled, sub-millisecond event broadcasting across independent server processes.                                                  |
| **Local Client Queue**            | An in-memory asynchronous queue (`asyncio.Queue`) allocated to each connected client on a specific server node to stage incoming Redis events.                                                 |
| **Reverse Proxy / Load Balancer** | An intermediary service (Nginx) that terminates client HTTP connections and distributes incoming traffic across backend nodes without buffering streams.                                         |

### How Distributed Pub/Sub Works

When a client connects to `GET /events`, the FastAPI application assigns the client a dedicated in-memory `asyncio.Queue` and streams events continuously over HTTP. Concurrently, each node runs a background subscriber task listening to a shared Redis channel (`sse_events_channel`). When any node receives a `POST /publish` request, it sends the payload to Redis. Redis forwards the payload to all node subscribers simultaneously. Each node receives the broadcast from Redis, iterates over its local client queues, and pushes the event frames out over each active SSE connection.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/message_flow_sequence.svg" alt="Distributed SSE Message Flow Sequence" width="850">
</p>

---

## Objectives

- Deploy a multi-container cluster consisting of Redis 7, two FastAPI instances, and an Nginx reverse proxy using Docker Compose.
- Implement an asynchronous Redis Pub/Sub broadcaster with subscription pooling and client queue registries.
- Expose a `POST /publish` endpoint that accepts JSON payloads and broadcasts them to the Redis message bus.
- Expose a `GET /events` SSE endpoint that streams live broadcast frames to connected clients without proxy buffering.
- Verify cross-node message delivery by publishing an event to one node and confirming instantaneous delivery to a client connected to a different node.
- Configure the Poridhi Load Balancer to access the interactive web dashboard for real-time cluster monitoring.

---

## What You Will Build

The directory structure below outlines the completed project:

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

Clients connect to Nginx on port 8080, which load-balances traffic across `sse_node_a` and `sse_node_b`, while `sse_redis` synchronizes broadcast events across both nodes through an asynchronous Pub/Sub message channel.

---

## Step 1: Create the Project Directory Structure

Create the project directory tree for application source code and Nginx proxy configuration:

```bash
mkdir -p ~/distributed-sse-lab/nginx ~/distributed-sse-lab/app
cd ~/distributed-sse-lab
```

**Explanation:**

- `~/distributed-sse-lab/nginx` stores configuration files for the Nginx reverse proxy and load balancer.
- `~/distributed-sse-lab/app` stores the FastAPI server code, Redis broadcaster engine, and Docker build context.

---

## Step 2: Define Application Dependencies

Create a file named `app/requirements.txt` with the following contents:

```bash
cat << 'EOF' > app/requirements.txt
fastapi>=0.110.0
uvicorn[standard]>=0.28.0
redis>=5.0.3
httpx>=0.27.0
EOF
```

**Explanation:**

- `fastapi>=0.110.0` provides the modern asynchronous web framework used to expose SSE streams and JSON endpoints.
- `uvicorn[standard]>=0.28.0` provides an ASGI web server with event loop optimizations.
- `redis>=5.0.3` includes `redis.asyncio` for non-blocking asynchronous interaction with the Redis message bus.
- `httpx>=0.27.0` provides an asynchronous HTTP client used for server-side testing and request handling.

---

## Step 3: Implement the Redis Broadcaster Engine

Create a file named `app/broadcaster.py` with the following contents:

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
        """Listens for incoming messages from Redis and fans out to local client queues."""
        pubsub = self.redis.pubsub()
        await pubsub.subscribe(REDIS_CHANNEL)
        logger.info(f"Subscribed to Redis channel: {REDIS_CHANNEL}")

        try:
            async for message in pubsub.listen():
                if message["type"] == "message":
                    payload = message["data"]
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

**Explanation:**

- `aioredis.from_url(self.redis_url, decode_responses=True)` establishes an asynchronous Redis client that does not block FastAPI coroutines.
- `asyncio.create_task(self._listen_to_redis())` runs the Redis listener coroutine in the background for the duration of the server process.
- `pubsub.subscribe(REDIS_CHANNEL)` binds this server node to the shared cluster channel `sse_events_channel`.
- `self.local_client_queues` maintains references to all `asyncio.Queue` objects for clients connected to this specific node.
- `queue.put(payload)` fans out incoming Redis messages to every connected local client queue.
- `register_client` creates and stores a dedicated queue for each newly connected SSE client.
- `unregister_client` discards the queue when a client disconnects, preventing memory leaks.

---

## Step 4: Implement the FastAPI Server and Dashboard

Create a file named `app/main.py` with the following contents:

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
    await broadcaster.connect()
    yield
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
                data = await asyncio.wait_for(queue.get(), timeout=15.0)
                event_id += 1
                yield f"id: {event_id}\nevent: broadcast\ndata: {data}\n\n"
            except asyncio.TimeoutError:
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
    .title-group h1 { font-size: 22px; font-weight: 700; color: #fff; }
    .title-group p { font-size: 13px; color: var(--text-muted); margin-top: 4px; }
    .node-badge { background: rgba(99, 102, 241, 0.15); border: 1px solid rgba(99, 102, 241, 0.4); color: #a5b4fc; padding: 6px 14px; border-radius: 9999px; font-size: 13px; font-weight: 600; display: inline-flex; align-items: center; gap: 8px; }
    .pulse-dot { width: 8px; height: 8px; border-radius: 50%; background-color: var(--accent-green); }

    .arch-bar { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin-bottom: 24px; }
    .arch-card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 10px; padding: 14px 18px; display: flex; align-items: center; gap: 14px; }
    .arch-info h4 { font-size: 14px; font-weight: 600; color: #fff; }
    .arch-info p { font-size: 12px; color: var(--text-muted); }
    .arch-status { margin-left: auto; font-size: 11px; padding: 3px 8px; border-radius: 6px; font-weight: 600; }
    .status-online { background: rgba(16, 185, 129, 0.15); color: #34d399; border: 1px solid rgba(16, 185, 129, 0.3); }

    .main-grid { display: grid; grid-template-columns: 420px 1fr; gap: 24px; }
    @media (max-width: 1024px) { .main-grid { grid-template-columns: 1fr; } }

    .card { background: var(--card-bg); border: 1px solid var(--card-border); border-radius: 12px; overflow: hidden; display: flex; flex-direction: column; }
    .card-header { padding: 16px 20px; border-bottom: 1px solid var(--card-border); display: flex; justify-content: space-between; align-items: center; }
    .card-header h3 { font-size: 15px; font-weight: 600; color: #fff; }
    .card-body { padding: 20px; flex: 1; }

    .form-group { margin-bottom: 16px; }
    .form-group label { display: block; font-size: 12px; font-weight: 600; color: var(--text-muted); text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 6px; }
    .form-control { width: 100%; background: #0c121e; border: 1px solid var(--card-border); border-radius: 8px; padding: 10px 14px; color: #fff; font-size: 14px; outline: none; }
    .form-control:focus { border-color: var(--accent-cyan); }
    textarea.form-control { resize: vertical; min-height: 80px; }

    .btn { background: #0284c7; color: #fff; border: none; border-radius: 8px; padding: 12px 18px; font-size: 14px; font-weight: 600; cursor: pointer; width: 100%; }
    .btn:hover { background: #0369a1; }
    .btn-secondary { background: #1e293b; color: #e2e8f0; border: 1px solid #334155; padding: 6px 12px; font-size: 12px; border-radius: 6px; cursor: pointer; }
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
    .client-info h4 { font-size: 13px; font-weight: 600; color: #fff; }
    .client-info span.route { font-size: 11px; color: var(--accent-cyan); font-family: monospace; }
    .client-counter { font-size: 11px; background: rgba(6, 182, 212, 0.15); color: var(--accent-cyan); padding: 2px 7px; border-radius: 4px; font-weight: bold; }

    .event-feed { flex: 1; padding: 12px; overflow-y: auto; display: flex; flex-direction: column; gap: 10px; }
    .event-card { background: #162035; border: 1px solid #23304c; border-radius: 8px; padding: 10px 12px; font-size: 13px; }
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
        <h1>Distributed SSE Cluster Visualizer</h1>
        <p>Real-Time Multi-Node Server-Sent Events with Redis Pub/Sub and Nginx Load Balancer</p>
      </div>
      <div>
        <span class="node-badge"><span class="pulse-dot"></span> Serving Instance: <strong id="servingNode">Detecting...</strong></span>
      </div>
    </header>

    <div class="arch-bar">
      <div class="arch-card">
        <div class="arch-info">
          <h4>Nginx Load Balancer</h4>
          <p>Port 8080 (Round-Robin)</p>
        </div>
        <span class="arch-status status-online">Active</span>
      </div>
      <div class="arch-card">
        <div class="arch-info">
          <h4>Redis Pub/Sub Bus</h4>
          <p>sse_events_channel</p>
        </div>
        <span class="arch-status status-online">Synced</span>
      </div>
      <div class="arch-card">
        <div class="arch-info">
          <h4>Node Alpha</h4>
          <p>FastAPI (Port 8001)</p>
        </div>
        <span class="arch-status status-online">Online</span>
      </div>
      <div class="arch-card">
        <div class="arch-info">
          <h4>Node Beta</h4>
          <p>FastAPI (Port 8002)</p>
        </div>
        <span class="arch-status status-online">Online</span>
      </div>
    </div>

    <div class="main-grid">
      <div class="card">
        <div class="card-header">
          <h3>Publish Distributed Broadcast</h3>
        </div>
        <div class="card-body">
          <form id="publishForm">
            <div class="form-group">
              <label>Publish Route Target</label>
              <select id="targetEndpoint" class="form-control">
                <option value="/publish">Load Balancer (:8080/publish - Round-Robin)</option>
                <option value="/node-a/publish">Direct to Node-Alpha (:8080/node-a/publish)</option>
                <option value="/node-b/publish">Direct to Node-Beta (:8080/node-b/publish)</option>
              </select>
            </div>
            <div class="form-group">
              <label>Event Title</label>
              <input type="text" id="eventTitle" class="form-control" value="System Notification" required>
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
              <textarea id="eventMessage" class="form-control" placeholder="Enter message payload...">Distributed Redis broadcast across multiple SSE nodes</textarea>
            </div>
            <button type="submit" class="btn" id="btnPublish">
              <span>Broadcast to Fleet via Redis</span>
            </button>
          </form>

          <div class="quick-pub">
            <button class="btn-secondary" onclick="quickSend('Node-Alpha', '/node-a/publish')">Send via Alpha</button>
            <button class="btn-secondary" onclick="quickSend('Node-Beta', '/node-b/publish')">Send via Beta</button>
          </div>

          <div class="flow-box">
            <div class="flow-step"><span class="num">1</span> <strong>HTTP POST:</strong> Message sent to target node.</div>
            <div class="flow-step"><span class="num">2</span> <strong>Redis Bus:</strong> Node executes <code>redis.publish()</code>.</div>
            <div class="flow-step"><span class="num">3</span> <strong>Fleet Fan-Out:</strong> All nodes receive event via PubSub.</div>
            <div class="flow-step"><span class="num">4</span> <strong>SSE Push:</strong> Every connected client receives frame.</div>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-header">
          <h3>Live Multi-Node SSE Monitor</h3>
          <button class="btn-secondary" onclick="clearAllFeeds()">Clear All Feeds</button>
        </div>
        <div class="card-body">
          <div class="clients-grid">
            <div class="client-panel">
              <div class="client-header">
                <div class="client-info">
                  <h4>Client 1 (Node-Alpha)</h4>
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

            <div class="client-panel">
              <div class="client-header">
                <div class="client-info">
                  <h4>Client 2 (Node-Beta)</h4>
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

            <div class="client-panel">
              <div class="client-header">
                <div class="client-info">
                  <h4>Client 3 (Load Balancer)</h4>
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
      Poridhi Lab 60 - Scalable Server-Sent Events Architecture with Redis Pub/Sub and Nginx Load Balancing
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
        statusEl.innerHTML = '<span style="color:#ef4444;">Disconnected</span>';
      };
    }

    function toggleClient(id) {
      const c = clients[id];
      const statusEl = document.getElementById(c.statusId);
      if (c.es) {
        c.es.close();
        c.es = null;
        statusEl.innerHTML = '<span style="color:#9ca3af;">Offline</span>';
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
        btn.innerText = 'Broadcast Sent';
        setTimeout(() => {
          btn.disabled = false;
          btn.innerText = 'Broadcast to Fleet via Redis';
        }, 1200);
      } catch (err) {
        alert('Error publishing event: ' + err.message);
        btn.disabled = false;
        btn.innerText = 'Broadcast to Fleet via Redis';
      }
    });

    function quickSend(originNode, endpoint) {
      document.getElementById('eventTitle').value = `Alert from ${originNode}`;
      document.getElementById('eventMessage').value = `Live test broadcast initiated directly from ${originNode}`;
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

**Explanation:**

- `@asynccontextmanager lifespan` establishes the asynchronous Redis connection when the FastAPI application starts up and terminates it gracefully during shutdown.
- `app.add_middleware(CORSMiddleware, ...)` configures Cross-Origin Resource Sharing so browser clients can connect from any origin.
- `POST /publish` accepts the JSON message payload conforming to `PublishMessage`, appends metadata (`publisher_node`, `published_at`), and pushes the message to Redis.
- `GET /events` returns a `StreamingResponse` using `sse_event_stream`. It sets `Cache-Control: no-cache` and `X-Accel-Buffering: no` to instruct reverse proxies not to buffer the stream.
- `asyncio.wait_for(queue.get(), timeout=15.0)` waits for new messages in the client queue and sends `: keep-alive\n\n` comments when no messages arrive within 15 seconds.
- `GET /health` returns JSON reporting current node health, node name, and the count of active local client connections.
- `GET /` and `GET /dashboard` serve the visual HTML dashboard containing multi-client real-time monitors and event publishing forms.

---

## Step 5: Create the Application Container Dockerfile

Create a file named `app/Dockerfile` with the following contents:

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

**Explanation:**

- `FROM python:3.11-slim` provides a lightweight Linux environment with Python 3.11.
- `COPY requirements.txt .` and `RUN pip install --no-cache-dir` install dependencies separately from source code to leverage Docker layer caching.
- `COPY . .` copies `main.py` and `broadcaster.py` into `/app`.
- `EXPOSE 8000` documents the container network port.
- `CMD ["uvicorn", "main:app", ...]` defines the entrypoint command to start the asynchronous web server listening on all network interfaces.

---

## Step 6: Configure the Nginx Load Balancer

Create a file named `nginx/nginx.conf` with the following contents:

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

        # Health and Stats Endpoint
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

**Explanation:**

- `upstream sse_fleet` declares the backend pool with `sse_node_a:8000` and `sse_node_b:8000` for round-robin balancing.
- `proxy_buffering off` disables response buffering so individual SSE event chunks are forwarded to clients immediately.
- `proxy_cache off` prevents intermediate response caching of dynamic streaming data.
- `proxy_read_timeout 3600s` increases the timeout to one hour so long-lived idle SSE streams are not terminated prematurely.
- `location /node-a/` and `location /node-b/` use URL rewrites to route requests directly to a specific backend node through Nginx port 80 without requiring additional ports to be exposed externally.

---

## Step 7: Define the Docker Compose Multi-Node Stack

Create a file named `docker-compose.yml` with the following contents:

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

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/01_create_docker_compose.png" alt="Create Docker Compose Multi-Node Stack" width="850">
</p>

**Explanation:**

- `redis` runs the official Redis 7 Alpine image as the central in-memory message broker.
- `sse_node_a` and `sse_node_b` build independent containers from `./app`, passing environment variables `NODE_NAME` and `REDIS_URL` to identify instances.
- `load_balancer` runs Nginx on port 8080, mounting the local `nginx/nginx.conf` file as read-only.
- `depends_on` defines service startup order so backend nodes wait for Redis, and the load balancer waits for backend nodes.

---

## Step 8: Deploy the Stack with Docker Compose

Launch the multi-container stack in detached mode:

```bash
cd ~/distributed-sse-lab
docker compose up -d --build
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/02_docker_compose_build.png" alt="Deploy Multi-Container Stack with Docker Compose" width="850">
</p>

Verify that all four containers are running:

```bash
docker compose ps
```

Expected Output:

```text
NAME                IMAGE                            COMMAND                  SERVICE         CREATED         STATUS         PORTS
sse_load_balancer   nginx:alpine                     "/docker-entrypoint.…"   load_balancer   5 seconds ago   Up 4 seconds   0.0.0.0:8080->80/tcp
sse_node_a          distributed-sse-lab-sse_node_a   "uvicorn main:app --…"   sse_node_a      5 seconds ago   Up 4 seconds   0.0.0.0:8001->8000/tcp
sse_node_b          distributed-sse-lab-sse_node_b   "uvicorn main:app --…"   sse_node_b      5 seconds ago   Up 4 seconds   0.0.0.0:8002->8000/tcp
sse_redis           redis:7-alpine                   "docker-entrypoint.s…"   redis           5 seconds ago   Up 5 seconds   0.0.0.0:6379->6379/tcp
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/03_docker_compose_ps.png" alt="Verify Docker Compose Running Containers" width="850">
</p>

**Explanation:**

- `docker compose up -d --build` compiles the Docker image from `./app` and starts the containers in the background.
- `docker compose ps` verifies that each container is active and mapped to its assigned host port.

---

## Verification

### Scenario 1: Verify Node Health and Cluster Connectivity

Query the `/health` endpoint through the Nginx Load Balancer:

```bash
curl -s -i http://localhost:8080/health
```

Expected Output:

```text
HTTP/1.1 200 OK
Server: nginx/1.31.6
Date: Tue, 22 Sep 2026 19:23:14 GMT
Content-Type: application/json
Content-Length: 63
Connection: keep-alive

{"status":"healthy","node":"Node-Alpha","active_subscribers":0}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/04_health_check_node_a.png" alt="Health Check Response from Node-Alpha" width="850">
</p>

Repeat the request to observe round-robin distribution:

```bash
curl -s http://localhost:8080/health
```

Expected Output:

```json
{"status":"healthy","node":"Node-Beta","active_subscribers":0}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/05_health_check_node_b.png" alt="Round-Robin Health Check Response from Node-Beta" width="850">
</p>

### Scenario 2: Verify Cross-Node Distributed Message Delivery

To verify that publishing an event to one server reaches subscribers on other servers via Redis, create and run an automated test script.

Create a file named `test_distributed_broadcast.sh` with the following contents:

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

echo "=== 3. Starting Client 3 connected to Load Balancer (:8080) in background ==="
curl -N -s http://localhost:8080/events > client_3.log 2>&1 &
PID_C3=$!

sleep 2

echo "=== 4. Publishing message to Load Balancer (:8080/publish) ==="
curl -s -X POST http://localhost:8080/publish \
     -H "Content-Type: application/json" \
     -d '{
       "title": "System Alert",
       "message": "Distributed Redis broadcast across multiple SSE nodes",
       "category": "urgent"
     }'

sleep 2

echo ""
echo "=== 5. Inspecting Client 1 (Node-Alpha) Received Events ==="
cat client_1.log

echo ""
echo "=== 6. Inspecting Client 2 (Node-Beta) Received Events ==="
cat client_2.log

echo ""
echo "=== 7. Inspecting Client 3 (Load Balancer) Received Events ==="
cat client_3.log

# Cleanup background processes
kill $PID_C1 $PID_C2 $PID_C3 2>/dev/null || true
rm -f client_1.log client_2.log client_3.log
echo ""
echo "Distributed rebroadcast test passed."
EOF
chmod +x test_distributed_broadcast.sh
./test_distributed_broadcast.sh
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/06_create_test_broadcast_script.png" alt="Create Distributed Broadcast Test Script" width="850">
</p>

Expected Output:

```text
=== 1. Starting Client 1 connected to Node-Alpha (:8001) in background ===
=== 2. Starting Client 2 connected to Node-Beta (:8002) in background ===
=== 3. Starting Client 3 connected to Load Balancer (:8080) in background ===
=== 4. Publishing message to Load Balancer (:8080/publish) ===
{"status":"published_to_redis","node":"Node-Alpha","payload":{"title":"System Alert","message":"Distributed Redis broadcast across multiple SSE nodes","category":"urgent","publisher_node":"Node-Alpha","published_at":"2026-09-23 01:15:00"}}

=== 5. Inspecting Client 1 (Node-Alpha) Received Events ===
event: system
data: {'node': 'Node-Alpha', 'message': 'Connected to Node-Alpha. Waiting for distributed events...', 'timestamp': 1790104500.12}

id: 1
event: broadcast
data: {"title": "System Alert", "message": "Distributed Redis broadcast across multiple SSE nodes", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-23 01:15:00"}


=== 6. Inspecting Client 2 (Node-Beta) Received Events ===
event: system
data: {'node': 'Node-Beta', 'message': 'Connected to Node-Beta. Waiting for distributed events...', 'timestamp': 1790104500.15}

id: 1
event: broadcast
data: {"title": "System Alert", "message": "Distributed Redis broadcast across multiple SSE nodes", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-23 01:15:00"}


=== 7. Inspecting Client 3 (Load Balancer) Received Events ===
event: system
data: {'node': 'Node-Alpha', 'message': 'Connected to Node-Alpha. Waiting for distributed events...', 'timestamp': 1790104500.18}

id: 1
event: broadcast
data: {"title": "System Alert", "message": "Distributed Redis broadcast across multiple SSE nodes", "category": "urgent", "publisher_node": "Node-Alpha", "published_at": "2026-09-23 01:15:00"}


Distributed rebroadcast test passed.
```

### Scenario 3: Verify Error Handling for Invalid Payloads (Failure Case)

Send an HTTP POST request to `/publish` with a missing required field (`message`):

```bash
curl -s -i -X POST http://localhost:8080/publish \
     -H "Content-Type: application/json" \
     -d '{"title": "Incomplete Payload"}'
```

Expected Output:

```text
HTTP/1.1 422 Unprocessable Entity
Server: nginx/1.31.6
Date: Tue, 22 Sep 2026 19:23:50 GMT
Content-Type: application/json
Content-Length: 118
Connection: keep-alive

{"detail":[{"type":"missing","loc":["body","message"],"msg":"Field required","input":{"title":"Incomplete Payload"}}]}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/07_validation_missing_field.png" alt="Validation Error for Missing Message Field" width="850">
</p>

Send a request with an empty body:

```bash
curl -s -i -X POST http://localhost:8080/publish \
     -H "Content-Type: application/json" \
     -d ''
```

Expected Output:

```text
HTTP/1.1 422 Unprocessable Entity
Server: nginx/1.31.6
Date: Tue, 22 Sep 2026 19:24:02 GMT
Content-Type: application/json
Content-Length: 82
Connection: keep-alive

{"detail":[{"type":"missing","loc":["body"],"msg":"Field required","input":null}]}
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/08_validation_empty_body.png" alt="Validation Error for Empty Body" width="850">
</p>

### Scenario 4: Access and Verify via Poridhi Load Balancer

To access the interactive visual dashboard from your browser outside the Poridhi VM, expose port `8080` using the Poridhi Load Balancer:

1. In the terminal, find the primary private IP address of the VM:

   ```bash
   hostname -I | awk '{print $1}'
   ```

   Expected Output:

   ```text
   10.62.31.128
   ```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/09_find_vm_ip.png" alt="Find VM Private IP" width="700">
</p>

2. Open the Poridhi interface header and click **Load Balancer**.
3. Enter the configuration:

   - **Enter IP:** Paste the private IP obtained from `hostname -I | awk '{print $1}'`.
   - **Enter Port:** `8080`.
4. Click **Expose**. Poridhi generates a public URL (for example: `http://<lab-id>-8080.lb.poridhi.io`).
5. Open the generated URL in your web browser.
6. Verify the following on the dashboard:

   - The top status bar displays **Nginx Load Balancer**, **Redis Pub/Sub Bus**, **Node Alpha**, and **Node Beta** in online state.
   - All three client monitors (**Client 1**, **Client 2**, and **Client 3**) show **Connected**.
   - Under **Publish Distributed Broadcast**, submit an event. Observe that the event card immediately appears in all three client logs simultaneously.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab60/10_live_dashboard.png" alt="Real-Time Distributed SSE Visualizer Dashboard" width="850">
</p>

### Verification Summary

| # | Call | Status | Body snippet |
| :--- | :--- | :--- | :--- |
| 1 | `GET /health` | `200 OK` | `{"status":"healthy","node":"Node-Beta",...}` |
| 2 | `POST /publish` (valid payload) | `200 OK` | `{"status":"published_to_redis","node":"Node-Alpha",...}` |
| 3 | `GET /events` (SSE stream) | `200 OK` | `event: broadcast\ndata: {"title":"System Alert",...}` |
| 4 | `POST /publish` (missing `message`) | `422 Unprocessable Entity` | `{"detail":[{"type":"missing","loc":["body","message"]...}]}` |
| 5 | `POST /publish` (empty body) | `422 Unprocessable Entity` | `{"detail":[{"type":"missing","loc":["body"]...}]}` |
| 6 | `GET /` (dashboard) | `200 OK` | `<!DOCTYPE html><html lang="en">...` |

---

## Conclusion

In this lab, you built a distributed Server-Sent Events architecture using FastAPI, Redis 7 Pub/Sub, and Nginx. You resolved the multi-node statefulness problem by subscribing each node to a shared Redis channel and fanning out received messages to local client queues. You verified that messages published to any single node or through the load balancer are delivered instantaneously to all connected subscribers across the cluster.
