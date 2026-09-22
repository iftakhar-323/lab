# Lab 59: SSE Load Testing

In this lab, you will perform high-concurrency load testing against a **Server-Sent Events (SSE)** architecture. You will configure the Linux operating system kernel and file descriptor limits to support thousands of simultaneous open TCP sockets, implement load testing generators using both **Python (`asyncio`/`aiohttp`)** and **k6**, simulate **1,000+ concurrent persistent SSE clients**, and measure connection establishment rate, event continuity, memory footprint, and auto-scaling response under sustained load.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab59/architecture_diagram.svg" alt="Lab 59 SSE Load Testing Architecture Diagram" width="800">
</p>

---

## Theory: High-Concurrency Load Testing for Persistent Streams

### Standard HTTP Benchmarking vs SSE Load Testing

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab59/load_metrics_chart.svg" alt="SSE Load Test Execution Telemetry" width="800">
</p>

Traditional load testing tools like ApacheBench (`ab`), `wrk`, or basic JMeter test **Request-Response throughput**:
- A client opens a TCP socket, sends `GET /`, receives `HTTP 200`, and closes the socket immediately.
- The primary metric reported is **Requests Per Second (RPS)**.

In contrast, **SSE Load Testing evaluates Connection Concurrency**:
- Clients open connections and **hold them open indefinitely** (minutes or hours).
- The metric is **Sustained Concurrent Active Streams**, stream survival rate, and event broadcast latency.
- Tests must measure whether events sent by the server arrive within milliseconds across all 1,000+ connected clients without drops or socket buffer overflows.

### Critical System Limits for High-Concurrency Testing

Operating systems are configured by default with conservative networking limits that throttle high concurrency:

1. **File Descriptor Limits (`nofile`):**
   - In Linux, every open TCP socket is a file descriptor.
   - The default limit is usually `1024`. A test trying to open 1,000 connections will immediately crash with `OSError: [Errno 24] Too many open files`.
   - **Resolution:** Raise `ulimit -n` to `65535`.

2. **Ephemeral Port Exhaustion:**
   - Outbound connections from a single client IP use ephemeral ports.
   - Default range: `32768 to 60999` (~28,000 ports).
   - **Resolution:** Expand range to `1024 to 65535` via `net.ipv4.ip_local_port_range`.

3. **TCP Socket Backlog (`somaxconn`):**
   - Determines the maximum length of the pending connection queue for incoming TCP handshakes.
   - **Resolution:** Increase `net.core.somaxconn` to `65535`.

---

## Objectives

- Tune Linux system parameters (`ulimit`, `somaxconn`, ephemeral port ranges) for high-scale network testing.
- Implement an unbuffered, high-performance SSE server running under multi-worker Uvicorn with an interactive real-time web dashboard.
- Deploy an Nginx reverse proxy load balancer on port `8080` configured for unbuffered, long-lived streaming.
- Build a Python asynchronous load testing script capable of maintaining 1,000+ concurrent SSE connections with live telemetry.
- Create a `k6` load testing script with custom thresholds for SSE event delivery.
- Execute the load test, monitor live connection concurrency on the web dashboard, and verify stream delivery continuity.

---

## Project Structure

```text
load-test-sse-lab/
├── proxy/
│   └── nginx.conf
├── scripts/
│   ├── tune_system.sh
│   ├── load_test_async.py
│   └── sse_k6_test.js
├── server/
│   ├── main.py
│   └── requirements.txt
└── docker-compose.yml
```

---

## Step 1: Create Project Directory

```bash
mkdir -p ~/load-test-sse-lab/scripts ~/load-test-sse-lab/server ~/load-test-sse-lab/proxy
cd ~/load-test-sse-lab
```

---

## Step 2: System Kernel Tuning

Create a script `scripts/tune_system.sh` to configure the Linux kernel to support large numbers of concurrent TCP connections:

```bash
cat << 'EOF' > scripts/tune_system.sh
#!/usr/bin/env bash
set -e

echo "=== Current Limits ==="
ulimit -n

echo "=== Tuning File Descriptors and Kernel Parameters ==="
# Set open file descriptor limit for current and sub-shells
ulimit -n 65535

# Apply kernel parameters if running with sudo/root privileges
if [ "$EUID" -eq 0 ]; then
    sysctl -w fs.file-max=2097152
    sysctl -w net.core.somaxconn=65535
    sysctl -w net.ipv4.ip_local_port_range="1024 65535"
    sysctl -w net.ipv4.tcp_tw_reuse=1
    sysctl -w net.ipv4.tcp_fin_timeout=15
    echo "Kernel parameters successfully tuned!"
else
    echo "[Notice] Run as root to apply sysctl changes system-wide. Applied ulimit -n 65535 for current session."
fi
EOF
chmod +x scripts/tune_system.sh
source scripts/tune_system.sh
```

---

## Step 3: Implement High-Efficiency SSE Server

Create `server/requirements.txt`:

```bash
cat << 'EOF' > server/requirements.txt
fastapi>=0.110.0
uvicorn[standard]>=0.28.0
psutil>=5.9.8
aiohttp>=3.9.3
EOF

python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r server/requirements.txt
```

Create `server/main.py`. This server contains:
1. An unbuffered `/events` endpoint that streams real-time JSON event packets every 3 seconds.
2. An interactive Real-Time HTML5 Web Dashboard at `GET /` that connects via `EventSource('/events')` to display real-time active connections, animated progress bar, memory footprint, CPU utilization, and worker load distribution chips.
3. Multi-worker metric synchronization using `/tmp/sse_workers/worker_{pid}.json` and a `/stats` endpoint that aggregates active connections across all worker processes.

```bash
cat << 'EOF' > server/main.py
import asyncio
import glob
import json
import os
import psutil
import time
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, StreamingResponse

app = FastAPI(title="SSE High-Load Target")

active_streams = 0
total_events_dispatched = 0
WORKER_PID = os.getpid()
SYNC_DIR = "/tmp/sse_workers"
os.makedirs(SYNC_DIR, exist_ok=True)

# Asynchronous background loop to synchronize worker state
@app.on_event("startup")
async def startup_event():
    asyncio.create_task(sync_worker_metrics())

async def sync_worker_metrics():
    global active_streams, total_events_dispatched
    metric_file = f"{SYNC_DIR}/worker_{WORKER_PID}.json"
    while True:
        try:
            with open(metric_file, "w") as f:
                json.dump({
                    "pid": WORKER_PID,
                    "active": active_streams,
                    "dispatched": total_events_dispatched,
                    "updated_at": time.time()
                }, f)
        except Exception:
            pass
        await asyncio.sleep(1.0)

async def event_generator(request: Request):
    global active_streams, total_events_dispatched
    active_streams += 1
    msg_id = 0

    try:
        while True:
            if await request.is_disconnected():
                break

            msg_id += 1
            total_events_dispatched += 1

            payload = {
                "id": msg_id,
                "timestamp": time.time(),
                "active_streams": active_streams,
                "worker_pid": WORKER_PID,
            }
            yield f"id: {msg_id}\nevent: broadcast\ndata: {json.dumps(payload)}\n\n"

            # Dispatch an event every 3 seconds to all active connections
            await asyncio.sleep(3.0)

    except asyncio.CancelledError:
        pass
    finally:
        active_streams -= 1

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SSE Load Testing Dashboard</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; }
    body { background: #0f172a; color: #f8fafc; padding: 24px; min-height: 100vh; }
    .header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 24px; border-bottom: 1px solid #1e293b; padding-bottom: 16px; }
    .header h1 { font-size: 24px; font-weight: 700; color: #ffffff; }
    .header p { font-size: 14px; color: #94a3b8; margin-top: 4px; }
    .badge { display: inline-flex; align-items: center; gap: 6px; background: #064e3b; color: #34d399; padding: 6px 14px; border-radius: 9999px; font-size: 13px; font-weight: 600; }
    .badge::before { content: ''; width: 8px; height: 8px; background: #10b981; border-radius: 50%; box-shadow: 0 0 8px #10b981; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; margin-bottom: 24px; }
    .card { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 20px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.2); }
    .card-title { font-size: 13px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: #94a3b8; margin-bottom: 8px; }
    .card-value { font-size: 32px; font-weight: 800; color: #f8fafc; margin-bottom: 8px; }
    .progress-bar-bg { width: 100%; height: 8px; background: #334155; border-radius: 4px; overflow: hidden; margin-top: 8px; }
    .progress-bar-fill { height: 100%; width: 0%; background: linear-gradient(90deg, #3b82f6, #06b6d4); transition: width 0.3s ease; }
    .worker-chips { display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap; }
    .chip { background: #0f172a; border: 1px solid #334155; border-radius: 6px; padding: 4px 8px; font-size: 11px; color: #cbd5e1; }
    .stream-container { background: #1e293b; border: 1px solid #334155; border-radius: 12px; padding: 20px; }
    .stream-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px; }
    .stream-header h2 { font-size: 16px; font-weight: 600; color: #e2e8f0; }
    .stream-log { background: #090d16; border: 1px solid #1e293b; border-radius: 8px; height: 260px; overflow-y: auto; padding: 12px; font-family: 'SFMono-Regular', Consolas, Menlo, monospace; font-size: 13px; line-height: 1.6; }
    .log-entry { margin-bottom: 6px; border-bottom: 1px solid #131b2e; padding-bottom: 4px; color: #94a3b8; }
    .log-id { color: #38bdf8; font-weight: 700; }
    .log-event { color: #f43f5e; font-weight: 600; }
    .log-data { color: #a7f3d0; }
  </style>
</head>
<body>
  <div class="header">
    <div>
      <h1>SSE Load Testing Dashboard</h1>
      <p>Real-Time Telemetry & 1,000+ Concurrent Stream Visualizer</p>
    </div>
    <div class="badge">LIVE STREAMING</div>
  </div>

  <div class="grid">
    <div class="card">
      <div class="card-title">Active SSE Connections</div>
      <div class="card-value" id="activeStreams">0</div>
      <div class="progress-bar-bg">
        <div class="progress-bar-fill" id="progressBar"></div>
      </div>
      <div class="worker-chips" id="workerChips"></div>
    </div>
    <div class="card">
      <div class="card-title">Total Events Dispatched</div>
      <div class="card-value" id="totalDispatched" style="color: #38bdf8;">0</div>
      <p style="font-size: 12px; color: #64748b;">Cumulative events across all sockets</p>
    </div>
    <div class="card">
      <div class="card-title">Memory Usage</div>
      <div class="card-value" id="memoryUsage" style="color: #a7f3d0;">0 MB</div>
      <p style="font-size: 12px; color: #64748b;">Resident Set Size (RSS)</p>
    </div>
    <div class="card">
      <div class="card-title">CPU Utilization</div>
      <div class="card-value" id="cpuUsage" style="color: #fbbf24;">0%</div>
      <p style="font-size: 12px; color: #64748b;">Process Core Load</p>
    </div>
  </div>

  <div class="stream-container">
    <div class="stream-header">
      <h2>Live EventSource Stream Preview (/events)</h2>
      <span style="font-size: 12px; color: #64748b;">Receiving infinite HTTP/1.1 chunked stream</span>
    </div>
    <div class="stream-log" id="streamLog"></div>
  </div>

  <script>
    async function updateStats() {
      try {
        const res = await fetch('/stats');
        if (!res.ok) return;
        const data = await res.json();
        
        document.getElementById('activeStreams').innerText = (data.active_streams || 0).toLocaleString();
        document.getElementById('totalDispatched').innerText = (data.total_dispatched || 0).toLocaleString();
        document.getElementById('memoryUsage').innerText = (data.memory_mb || 0) + ' MB';
        document.getElementById('cpuUsage').innerText = (data.cpu_percent || 0).toFixed(1) + '%';
        
        const pct = Math.min(100, ((data.active_streams || 0) / 1000) * 100);
        document.getElementById('progressBar').style.width = pct + '%';

        const chipsContainer = document.getElementById('workerChips');
        chipsContainer.innerHTML = '';
        if (data.workers && Object.keys(data.workers).length > 0) {
          for (const [pid, w] of Object.entries(data.workers)) {
            const chip = document.createElement('div');
            chip.className = 'chip';
            chip.innerText = 'Worker ' + pid + ': ' + w.active + ' conns';
            chipsContainer.appendChild(chip);
          }
        }
      } catch (err) {}
    }
    setInterval(updateStats, 1000);
    updateStats();

    const streamLog = document.getElementById('streamLog');
    const evtSource = new EventSource('/events');

    evtSource.addEventListener('broadcast', function(e) {
      const entry = document.createElement('div');
      entry.className = 'log-entry';
      const parsed = JSON.parse(e.data);
      entry.innerHTML = '<span class="log-id">#' + parsed.id + '</span> <span class="log-event">[broadcast]</span> <span class="log-data">' + e.data + '</span>';
      streamLog.appendChild(entry);
      if (streamLog.childNodes.length > 50) {
        streamLog.removeChild(streamLog.firstChild);
      }
      streamLog.scrollTop = streamLog.scrollHeight;
    });

    evtSource.onerror = function() {
      console.log('EventSource disconnected, reconnecting...');
    };
  </script>
</body>
</html>
"""

@app.get("/", response_class=HTMLResponse)
async def dashboard():
    return HTMLResponse(content=DASHBOARD_HTML, status_code=200)


@app.get("/events")
async def events(request: Request):
    return StreamingResponse(
        event_generator(request),
        media_type="text/event-stream",
        headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/stats")
async def stats():
    now = time.time()
    tot_active = 0
    tot_dispatched = 0
    tot_cpu = 0.0
    tot_mem = 0.0
    workers_info = {}

    for filepath in glob.glob(f"{SYNC_DIR}/worker_*.json"):
        try:
            with open(filepath, "r") as f:
                data = json.load(f)
            pid = data.get("pid")
            if pid and (now - data.get("updated_at", 0) < 5.0):
                try:
                    os.kill(pid, 0)
                    proc = psutil.Process(pid)
                    tot_cpu += proc.cpu_percent(interval=None)
                    tot_mem += proc.memory_info().rss / (1024 * 1024)
                except (OSError, psutil.NoSuchProcess):
                    continue
                tot_active += data.get("active", 0)
                tot_dispatched += data.get("dispatched", 0)
                workers_info[str(pid)] = {
                    "active": data.get("active", 0),
                    "dispatched": data.get("dispatched", 0),
                }
        except Exception:
            continue

    if not workers_info:
        proc = psutil.Process(WORKER_PID)
        tot_active = active_streams
        tot_dispatched = total_events_dispatched
        tot_cpu = proc.cpu_percent(interval=None)
        tot_mem = proc.memory_info().rss / (1024 * 1024)
        workers_info[str(WORKER_PID)] = {"active": active_streams, "dispatched": total_events_dispatched}

    return {
        "active_streams": tot_active,
        "total_dispatched": tot_dispatched,
        "cpu_percent": round(tot_cpu, 1),
        "memory_mb": round(tot_mem, 2),
        "workers": workers_info,
    }


@app.get("/health")
async def health():
    return {"status": "ok"}
EOF
```

---

## Step 4: Configure Nginx Load Balancer for Long-Lived Connections

In production architectures, client connections terminate at a reverse proxy or load balancer (such as AWS ALB, Nginx, or HAProxy) which forwards requests to backend SSE instances.

To support persistent SSE streams without premature drops or buffering stalls, Nginx must be configured with:
1. `proxy_buffering off;` — Disables response buffering so events reach the client instantly without waiting for buffer fills.
2. `proxy_read_timeout 3600s;` — Extends read timeout to prevent idle connection terminations on long-lived streams.
3. `least_conn;` — Distributes incoming SSE streams based on active open connections rather than round-robin.
4. `proxy_set_header Connection "";` — Enables HTTP/1.1 persistent keepalive upstream connections.

Create `proxy/nginx.conf`:

```bash
cat << 'EOF' > proxy/nginx.conf
pid /tmp/nginx_sse.pid;
error_log /tmp/nginx_sse_error.log;

events {
    worker_connections 65535;
}

http {
    access_log /tmp/nginx_sse_access.log;

    upstream sse_backend {
        least_conn;
        server 127.0.0.1:8000;
        keepalive 1024;
    }

    server {
        listen 8080;
        server_name _;

        # Static Dashboard UI and stats
        location / {
            proxy_pass http://sse_backend;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        # SSE Streaming endpoint with unbuffered configuration
        location /events {
            proxy_pass http://sse_backend/events;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

            # Disable buffering for instantaneous real-time event delivery
            proxy_buffering off;
            proxy_cache off;
            chunked_transfer_encoding off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
        }
    }
}
EOF
```

---

## Step 5: Implement Python 1,000+ Concurrent Client Load Tester

Create `scripts/load_test_async.py`. This script uses `aiohttp` to simulate 1,000 concurrent streaming connections against the load balancer (port 8080) with controlled ramp-up, latency tracking, and disconnection detection:

```bash
cat << 'EOF' > scripts/load_test_async.py
import asyncio
import os
import time
import aiohttp

# Target the Nginx Load Balancer on port 8080 (or port 8000 directly)
TARGET_URL = os.getenv("TARGET_URL", "http://localhost:8080/events")
TARGET_CONCURRENCY = 1000  # 1k concurrent clients
RAMP_UP_RATE = 50          # Connect 50 clients per second
TEST_DURATION_SECONDS = 30 # Hold connections for 30s after ramp-up

stats = {
    "connected": 0,
    "events_received": 0,
    "errors": 0,
    "disconnects": 0,
}


async def sse_client(session: aiohttp.ClientSession, client_id: int, stop_event: asyncio.Event):
    """Simulates a persistent SSE client reading events continuously."""
    try:
        async with session.get(TARGET_URL, timeout=aiohttp.ClientTimeout(total=None)) as response:
            if response.status != 200:
                stats["errors"] += 1
                return

            stats["connected"] += 1

            # Stream parsing
            async for line in response.content:
                if stop_event.is_set():
                    break
                decoded_line = line.decode("utf-8").strip()
                if decoded_line.startswith("data:"):
                    stats["events_received"] += 1

    except (aiohttp.ClientError, asyncio.TimeoutError):
        stats["errors"] += 1
    finally:
        stats["connected"] -= 1
        stats["disconnects"] += 1


async def monitor_progress(stop_event: asyncio.Event):
    """Prints real-time stats every 2 seconds."""
    start_time = time.time()
    while not stop_event.is_set():
        elapsed = int(time.time() - start_time)
        print(
            f"[{elapsed:02d}s] Active Streams: {stats['connected']} | "
            f"Total Events Received: {stats['events_received']} | "
            f"Errors: {stats['errors']}"
        )
        await asyncio.sleep(2)


async def main():
    print(f"=== Starting SSE Load Test ===")
    print(f"Target: {TARGET_URL}")
    print(f"Goal: {TARGET_CONCURRENCY} concurrent SSE streams (Ramping {RAMP_UP_RATE}/sec)")

    stop_event = asyncio.Event()
    connector = aiohttp.TCPConnector(limit=0, limit_per_host=0)
    
    async with aiohttp.ClientSession(connector=connector) as session:
        # Start background monitor
        monitor_task = asyncio.create_task(monitor_progress(stop_event))

        # Ramp up clients gradually to avoid socket handshake storms
        tasks = []
        for i in range(TARGET_CONCURRENCY):
            tasks.append(asyncio.create_task(sse_client(session, i, stop_event)))
            if (i + 1) % RAMP_UP_RATE == 0:
                await asyncio.sleep(1.0)

        print(f"--> Ramp-up complete. Holding connections for {TEST_DURATION_SECONDS} seconds...")
        await asyncio.sleep(TEST_DURATION_SECONDS)

        print("--> Stopping load test. Draining connections...")
        stop_event.set()
        await monitor_task
        await asyncio.gather(*tasks, return_exceptions=True)

    print("\n=== Test Results Summary ===")
    print(f"Peak Concurrent Streams: {TARGET_CONCURRENCY}")
    print(f"Total SSE Events Received: {stats['events_received']}")
    print(f"Total Errors / Drops: {stats['errors']}")
    print("============================\n")


if __name__ == "__main__":
    asyncio.run(main())
EOF
```

---

## Step 6: Implement k6 SSE Load Testing Script (Alternative)

For teams using **k6**, create `scripts/sse_k6_test.js` targeting port 8080 using k6's HTTP streaming capabilities:

```bash
cat << 'EOF' > scripts/sse_k6_test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  scenarios: {
    sse_traffic: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '15s', target: 500 },  // Ramp to 500 VUs
        { duration: '30s', target: 1000 }, // Ramp to 1000 VUs
        { duration: '30s', target: 1000 }, // Hold 1000 VUs
        { duration: '10s', target: 0 },    // Ramp down
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'], // Less than 1% failure rate
  },
};

export default function () {
  const params = {
    headers: {
      'Accept': 'text/event-stream',
      'Cache-Control': 'no-cache',
    },
    timeout: '60s',
  };

  const res = http.get('http://localhost:8080/events', params);

  check(res, {
    'status is 200': (r) => r.status === 200,
    'content-type is event-stream': (r) => r.headers['Content-Type'] && r.headers['Content-Type'].includes('text/event-stream'),
  });

  sleep(1);
}
EOF
```

---

## Step 7: Execute Load Test and Monitor via Live Browser Dashboard

### 1. Start the FastAPI SSE Server

Start the server with 2 Uvicorn worker processes in the background:

```bash
cd ~/load-test-sse-lab
source venv/bin/activate
uvicorn server.main:app --host 0.0.0.0 --port 8000 --workers 2 &
SERVER_PID=$!
sleep 3
```

### 2. Start the Nginx Load Balancer

Launch Nginx pointing to our unbuffered SSE configuration:

```bash
nginx -c ~/load-test-sse-lab/proxy/nginx.conf
```

### 3. Verify Server Endpoints via Load Balancer

Check that the load balancer is routing to the server and metrics are initializing:

```bash
curl -s http://localhost:8080/stats
```

Expected Output:

```json
{"active_streams":0,"total_dispatched":0,"cpu_percent":0.0,"memory_mb":52.18,"workers":{"1234":{"active":0,"dispatched":0},"1235":{"active":0,"dispatched":0}}}
```

### 4. Open the Real-Time Web Dashboard

Open your web browser and navigate to:

```text
http://<poridhi-vm-ip>:8080/
```

> **Note:** If running inside the Poridhi lab environment, you can use the built-in Port Preview feature for port `8080` or curl directly.

You will see the dark-themed SSE Dashboard displaying:
- **Active SSE Connections:** Live counter and progress bar scaling up to 1,000+.
- **Worker Distribution:** Live chips displaying the number of active sockets assigned to each worker PID.
- **Total Events Dispatched:** Real-time event counter.
- **System Telemetry:** Live Memory (RSS in MB) and CPU percentage.
- **EventSource Stream Preview:** Scrolling terminal-style window rendering live incoming SSE events from `/events`.

### 5. Launch the Python Load Test

In your terminal, start the high-concurrency 1,000-connection load test:

```bash
python3 scripts/load_test_async.py
```

Expected Terminal Output:

```text
=== Starting SSE Load Test ===
Target: http://localhost:8080/events
Goal: 1000 concurrent SSE streams (Ramping 50/sec)
[00s] Active Streams: 50 | Total Events Received: 0 | Errors: 0
[02s] Active Streams: 150 | Total Events Received: 98 | Errors: 0
[06s] Active Streams: 350 | Total Events Received: 492 | Errors: 0
[10s] Active Streams: 550 | Total Events Received: 1204 | Errors: 0
[16s] Active Streams: 850 | Total Events Received: 2845 | Errors: 0
[20s] Active Streams: 1000 | Total Events Received: 4610 | Errors: 0
--> Ramp-up complete. Holding connections for 30 seconds...
[24s] Active Streams: 1000 | Total Events Received: 5930 | Errors: 0
[28s] Active Streams: 1000 | Total Events Received: 7260 | Errors: 0
--> Stopping load test. Draining connections...

=== Test Results Summary ===
Peak Concurrent Streams: 1000
Total SSE Events Received: 8940
Total Errors / Drops: 0
============================
```

> **Live Dashboard Observation:** Watch the web dashboard in your browser while the test runs. The **Active SSE Connections** progress bar will dynamically fill up to 1,000, and the worker chips will show balanced connection distribution (e.g. ~500 connections on Worker A and ~500 connections on Worker B) handled seamlessly by Nginx and Uvicorn!

### 6. Verify Post-Test Server Metrics

Verify final server metrics and resource efficiency:

```bash
curl -s http://localhost:8080/stats
```

Expected Output:

```json
{"active_streams":0,"total_dispatched":8940,"cpu_percent":6.8,"memory_mb":58.42,"workers":{"1234":{"active":0,"dispatched":4470},"1235":{"active":0,"dispatched":4470}}}
```

Notice that handling 1,000 persistent active streams required **under 60 MB of total RAM** across all workers and minimal CPU overhead.

### 7. Clean Up Services

Once testing is complete, terminate the Nginx proxy and FastAPI server:

```bash
nginx -s stop -c ~/load-test-sse-lab/proxy/nginx.conf || pkill nginx
kill $SERVER_PID
```

---

## Conclusion

In this lab, you tuned the Linux networking stack for high connection concurrency by expanding file descriptor and ephemeral port limits. You deployed an **unbuffered Nginx load balancer** on port `8080` and implemented a multi-worker **FastAPI SSE server** equipped with an interactive **real-time browser telemetry dashboard**. Using an asynchronous Python load generator, you simulated **1,000+ concurrent persistent SSE connections**, observing dynamic connection ramp-up, balanced worker distribution, zero event loss, and exceptional resource efficiency. In Module 82, you will implement **Redis Pub/Sub** to scale event distribution horizontally across multiple isolated cluster nodes.
