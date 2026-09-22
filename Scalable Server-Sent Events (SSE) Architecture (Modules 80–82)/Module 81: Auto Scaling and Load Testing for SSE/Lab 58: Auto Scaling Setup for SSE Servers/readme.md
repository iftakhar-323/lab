# Lab 58: Auto Scaling Setup for SSE Servers

In this lab, you will architect, configure, and evaluate an **AWS Auto Scaling Group (ASG)** specifically engineered for persistent **Server-Sent Events (SSE)** workloads. You will learn why traditional CPU-utilization scaling policies fail for streaming servers, configure an EC2 Launch Template with an automated bootstrapping script, publish custom CloudWatch telemetry tracking active SSE connections, and implement a dynamic **Target Tracking Scaling Policy** based on `TargetConnectionCount` and custom connection metrics.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab58/architecture_diagram.svg" alt="Lab 58 Auto Scaling Architecture Diagram" width="800">
</p>

---

## Theory: Auto Scaling Dynamics for Persistent Streaming

### Why CPU-Based Auto Scaling Fails for SSE

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab58/scaling_dynamics.svg" alt="Scaling Metrics Comparison: CPU vs Connection Density" width="800">
</p>

Standard web APIs (such as CRUD REST endpoints) scale on **CPU Utilization** (e.g., target 70% CPU) because each request requires active computation (JSON serialization, DB queries, hashing). Once the request finishes in a few milliseconds, CPU drops.

SSE connections, in contrast, are **persistent, stateful TCP streams**:
1. **Low CPU Footprint:** Thousands of clients connected to an SSE endpoint and waiting for periodic events generate almost **zero CPU activity** between broadcast frames.
2. **Resource Bottleneck is RAM & File Descriptors:** Each connection consumes an open socket file descriptor and in-memory event buffers (approx. 20KB–50KB per socket). A server holding 15,000 idle SSE connections might only show 5% CPU usage while being moments away from running out of memory or exhausting the Linux socket limit.
3. **Delayed Scale-Out Risk:** Relying on CPU threshold will leave your cluster under-provisioned, resulting in TCP socket drops, rejected handshakes, and application crashes before CPU alerts ever fire.

### Recommended Scaling Metrics for SSE

To scale SSE fleets reliably, employ a combination of ALB connection metrics and custom application telemetry:

| Metric Name | Source | Purpose | Recommended Target Value |
| :--- | :--- | :--- | :--- |
| `ActiveConnectionCount` / `TargetConnectionCount` | AWS Application Load Balancer | Measures total active TCP connections across all registered targets. | 1,000 – 2,500 connections per instance (depending on instance RAM) |
| `ActiveSSEConnections` | Application (Custom CloudWatch Metric) | Exact count of clients currently reading `/events`. | 1,500 active streams per target |
| `TargetResponseTime` | AWS ALB | Detects when event delivery latency increases due to event-loop saturation. | > 250ms triggers scale-out |

### Scale-In Protection and Connection Draining

Scaling down (terminating instances) is dangerous for streaming workloads:
- If an instance holding 2,000 active SSE streams is abruptly terminated, all 2,000 clients will reconnect simultaneously.
- This creates a **thundering herd problem** that can crash the surviving instances.
- **Remedy:** Set `deregistration_delay.timeout_seconds` to a generous duration (e.g., 300–600 seconds) and enable ASG scale-in protection or gradual step scaling.

---

## Objectives

- Write an automated EC2 User Data script that configures Linux kernel file descriptor limits and deploys the FastAPI SSE server under `systemd`.
- Create an EC2 Launch Template specifying instance configuration, IAM instance profile, and security groups.
- Attach the Launch Template to an Auto Scaling Group linked to the ALB Target Group.
- Implement an asynchronous background worker in Python that publishes the `ActiveSSEConnections` metric to Amazon CloudWatch every 30 seconds.
- Configure a Target Tracking Scaling Policy targeting a fixed number of concurrent connections per instance.
- Simulate traffic spikes and verify the scaling lifecycle.

---

## Project Structure

```text
asg-sse-lab/
├── aws/
│   ├── user_data.sh
│   ├── launch_template.json
│   ├── create_asg.sh
│   └── configure_scaling_policy.sh
├── app/
│   ├── main.py
│   ├── metrics_reporter.py
│   └── requirements.txt
└── test_scaling_metric.py
```

---

## Step 1: Create Lab Directory Structure

```bash
mkdir -p ~/asg-sse-lab/aws ~/asg-sse-lab/app
cd ~/asg-sse-lab
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab58/01_create_directory.png" alt="Create Lab Directory Structure" width="700">
</p>

---

## Step 2: Implement FastAPI Application with CloudWatch Telemetry

Create `app/requirements.txt`:

```bash
cat << 'EOF' > app/requirements.txt
fastapi>=0.110.0
uvicorn[standard]>=0.28.0
boto3>=1.34.0
psutil>=5.9.8
httpx>=0.27.0
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab58/02_create_requirements.png" alt="Create Requirements File" width="700">
</p>

Create `app/main.py` with an embedded connection tracker and background CloudWatch reporter:

```bash
cat << 'EOF' > app/main.py
import asyncio
import json
import logging
import os
import socket
import time
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse
import boto3

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("sse_asg_server")

INSTANCE_ID = os.getenv("INSTANCE_ID", socket.gethostname())
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

active_connections = 0

# CloudWatch client (will authenticate via EC2 IAM Instance Profile in AWS)
cloudwatch = None
try:
    cloudwatch = boto3.client("cloudwatch", region_name=AWS_REGION)
except Exception as e:
    logger.warning(f"CloudWatch client initialization bypassed (Local Mode): {e}")


async def push_metrics_loop():
    """Background task pushing active SSE connection counts to CloudWatch every 30s."""
    while True:
        try:
            logger.info(f"[{INSTANCE_ID}] Telemetry: Active SSE Connections = {active_connections}")
            if cloudwatch:
                cloudwatch.put_metric_data(
                    Namespace="SSE/ApplicationFleet",
                    MetricData=[
                        {
                            "MetricName": "ActiveSSEConnections",
                            "Dimensions": [
                                {"Name": "InstanceId", "Value": INSTANCE_ID},
                            ],
                            "Value": float(active_connections),
                            "Unit": "Count",
                            "StorageResolution": 60,
                        },
                    ],
                )
        except Exception as e:
            if "Unable to locate credentials" in str(e):
                logger.info(f"[{INSTANCE_ID}] Local environment: CloudWatch credentials not present (local telemetry active).")
            else:
                logger.error(f"Failed to publish metrics to CloudWatch: {e}")
        await asyncio.sleep(30)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: spawn background metrics reporter
    metric_task = asyncio.create_task(push_metrics_loop())
    yield
    # Shutdown
    metric_task.cancel()


app = FastAPI(title="SSE ASG Backend", lifespan=lifespan)


async def sse_stream(request: Request):
    global active_connections
    active_connections += 1
    stream_id = 0
    try:
        while True:
            if await request.is_disconnected():
                break
            stream_id += 1
            payload = {
                "instance": INSTANCE_ID,
                "msg_id": stream_id,
                "active_connections": active_connections,
                "timestamp": time.time(),
            }
            yield f"id: {stream_id}\nevent: update\ndata: {json.dumps(payload)}\n\n"
            await asyncio.sleep(3.0)
    finally:
        active_connections -= 1


@app.get("/events")
async def events(request: Request):
    return StreamingResponse(
        sse_stream(request),
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
        "instance_id": INSTANCE_ID,
        "active_connections": active_connections,
    }
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab58/03_create_main_py.png" alt="Create FastAPI Main App" width="700">
</p>

---

## Step 3: EC2 User Data Bootstrapping Script

When EC2 instances launch inside an Auto Scaling Group, they execute a User Data script. This script:
1. Tunes Linux kernel limits (`fs.file-max`, `nofile`) to allow thousands of concurrent TCP sockets.
2. Installs Python dependencies.
3. Configures and starts the FastAPI service under `systemd`.

Create `aws/user_data.sh`:

```bash
cat << 'EOF' > aws/user_data.sh
#!/bin/bash
set -ex

# 1. Update OS and tune kernel limits for high-concurrency TCP streams
echo "* soft nofile 65535" >> /etc/security/limits.conf
echo "* hard nofile 65535" >> /etc/security/limits.conf
sysctl -w fs.file-max=2097152
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sysctl -p

# 2. Install Python, Pip, Git
apt-get update -y
apt-get install -y python3-pip python3-venv

# 3. Retrieve EC2 Instance ID from Instance Metadata Service (IMDSv2)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AWS_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# 4. Set up application directory
mkdir -p /opt/sse-app
cd /opt/sse-app

# Copy application files (in production, pull from S3 or Git repository)
cat << 'APP_EOF' > /opt/sse-app/main.py
# Application code injected here
APP_EOF

# 5. Create virtualenv and install dependencies
python3 -m venv /opt/sse-app/venv
/opt/sse-app/venv/bin/pip install --upgrade pip
/opt/sse-app/venv/bin/pip install fastapi uvicorn[standard] boto3 psutil

# 6. Create systemd service
cat << SYSTEMD_EOF > /etc/systemd/system/sse-app.service
[Unit]
Description=Scalable FastAPI SSE Service
After=network.target

[Service]
User=root
WorkingDirectory=/opt/sse-app
Environment="INSTANCE_ID=${INSTANCE_ID}"
Environment="AWS_REGION=${AWS_REGION}"
LimitNOFILE=65535
ExecStart=/opt/sse-app/venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000 --workers 4
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

# 7. Enable and start service
systemctl daemon-reload
systemctl enable sse-app
systemctl start sse-app
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab58/04_create_user_data.png" alt="Create EC2 User Data Script" width="700">
</p>

---

## Step 4: Create Launch Template and Auto Scaling Group

Create `aws/create_asg.sh`:

```bash
cat << 'EOF' > aws/create_asg.sh
#!/usr/bin/env bash
set -e

AMI_ID="ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS AMI (Example for us-east-1)
INSTANCE_TYPE="t3.medium"
KEY_NAME="my-ssh-key"
SECURITY_GROUP="sg-0987654321fedcba0"
TARGET_GROUP_ARN="arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/sse-backend-tg/12345678"
SUBNETS="subnet-0a1b2c3d4e5f,subnet-0f5e4d3c2b1a"

echo "=== 1. Encoding User Data Script ==="
USER_DATA_BASE64=$(base64 -w 0 aws/user_data.sh)

echo "=== 2. Creating EC2 Launch Template ==="
aws ec2 create-launch-template \
    --launch-template-name sse-launch-template \
    --version-description "Initial SSE Template" \
    --launch-template-data "{
        \"ImageId\": \"$AMI_ID\",
        \"InstanceType\": \"$INSTANCE_TYPE\",
        \"SecurityGroupIds\": [\"$SECURITY_GROUP\"],
        \"UserData\": \"$USER_DATA_BASE64\",
        \"IamInstanceProfile\": {\"Name\": \"CloudWatchAgentServerRole\"}
    }"

echo "=== 3. Creating Auto Scaling Group ==="
aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name sse-asg \
    --launch-template "LaunchTemplateName=sse-launch-template,Version=\$Latest" \
    --min-size 2 \
    --max-size 8 \
    --desired-capacity 2 \
    --vpc-zone-identifier "$SUBNETS" \
    --target-group-arns "$TARGET_GROUP_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 300 \
    --default-cooldown 180

echo "=== Auto Scaling Group Provisioned Successfully! ==="
EOF
chmod +x aws/create_asg.sh
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab58/05_create_asg_script.png" alt="Create Launch Template and Auto Scaling Group" width="700">
</p>

---

## Step 5: Configure Target Tracking Scaling Policy

Configure a scaling policy that automatically adds or removes EC2 instances to maintain an average of **1,000 active connections per target**.

Create `aws/configure_scaling_policy.sh`:

```bash
cat << 'EOF' > aws/configure_scaling_policy.sh
#!/usr/bin/env bash
set -e

ASG_NAME="sse-asg"
TARGET_GROUP_RESOURCE_LABEL="app/sse-alb/50dc6c495c0c9188/targetgroup/sse-backend-tg/73e2d6bc24d8a067"

echo "=== Applying Target Tracking Scaling Policy based on ALB Request/Connection Count ==="
aws autoscaling put-scaling-policy \
    --auto-scaling-group-name $ASG_NAME \
    --policy-name sse-connection-target-tracking \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration "{
        \"PredefinedMetricSpecification\": {
            \"PredefinedMetricType\": \"ALBRequestCountPerTarget\",
            \"ResourceLabel\": \"$TARGET_GROUP_RESOURCE_LABEL\"
        },
        \"TargetValue\": 1000.0,
        \"ScaleOutCooldown\": 60,
        \"ScaleInCooldown\": 300
    }"

echo "Scaling policy successfully attached to ASG!"
EOF
chmod +x aws/configure_scaling_policy.sh
```

---

## Step 6: Test Local Simulation and Metric Verification

To verify that the application correctly counts active connections and cleans up upon disconnection in the Poridhi environment:

1. Start the FastAPI server locally:

```bash
cd ~/asg-sse-lab
python3 -m venv venv
source venv/bin/activate
pip install -r app/requirements.txt
uvicorn app.main:app --host 0.0.0.0 --port 8000 &
SERVER_PID=$!
sleep 3
```

2. Run `test_scaling_metric.py` to open multiple concurrent SSE streams and observe the connection counter:

```bash
cat << 'EOF' > test_scaling_metric.py
import asyncio
import httpx

URL = "http://localhost:8000/events"
CONCURRENT_CLIENTS = 15

async def sse_client(client_id):
    async with httpx.AsyncClient(timeout=30.0) as client:
        try:
            async with client.stream("GET", URL) as response:
                print(f"[Client {client_id}] Connected. Status: {response.status_code}")
                count = 0
                async for line in response.aiter_lines():
                    if line.startswith("data:"):
                        count += 1
                    if count >= 3:
                        break
        except Exception as e:
            print(f"[Client {client_id}] Error: {e}")

async def main():
    print(f"Opening {CONCURRENT_CLIENTS} concurrent SSE connections...")
    tasks = [sse_client(i) for i in range(CONCURRENT_CLIENTS)]
    await asyncio.gather(*tasks)
    print("All client streams finished.")

    # Check health endpoint for active connection count
    async with httpx.AsyncClient() as client:
        r = await client.get("http://localhost:8000/health")
        print("Final Health Status:", r.json())

if __name__ == "__main__":
    asyncio.run(main())
EOF

python3 test_scaling_metric.py
```

Expected Output:

```text
Opening 15 concurrent SSE connections...
[Client 0] Connected. Status: 200
[Client 1] Connected. Status: 200
[Client 2] Connected. Status: 200
...
All client streams finished.
Final Health Status: {'status': 'healthy', 'instance_id': '...', 'active_connections': 0}
```

Terminate the background server:

```bash
kill $SERVER_PID
```

---

## Conclusion

In this lab, you established an auto-scaling strategy optimized for persistent Server-Sent Events. You configured an EC2 Launch Template with Linux socket tuning and an automated User Data script, implemented application-level connection tracking, configured target tracking scaling policies based on connection density, and verified graceful connection draining during scale-in events. In the next lab, you will generate heavy load to simulate **1,000+ concurrent SSE clients** and validate scaling responsiveness.
