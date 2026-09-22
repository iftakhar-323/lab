# Lab 57: ALB Configuration for Long-Lived Connections

In this lab, you will configure an **AWS Application Load Balancer (ALB)** and production reverse proxy layer specifically tuned for long-lived **Server-Sent Events (SSE)** connections. You will learn why default load balancer settings terminate SSE streams after 60 seconds with `504 Gateway Timeout`, how to configure the ALB idle timeout to `3600` seconds (1 hour), how to configure target group deregistration delays for graceful connection draining, and how to emulate and test this exact architecture locally in your Poridhi environment using an Nginx reverse proxy stack.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab57/architecture_diagram.svg" alt="Lab 57 ALB Architecture Diagram" width="800">
</p>

---

## Theory: Long-Lived HTTP Connections and Load Balancers

### The 60-Second Idle Timeout Problem

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab57/idle_timeout_comparison.svg" alt="ALB Idle Timeout Comparison: 60s vs 3600s" width="800">
</p>

By default, an AWS Application Load Balancer (ALB) enforces an **idle timeout of 60 seconds**.
- If no data packets traverse the connection between the client and ALB, or between the ALB and the backend target within 60 seconds, the ALB closes the TCP socket and returns an `HTTP 504 Gateway Timeout` to the client.
- For transactional APIs (REST/GraphQL), 60 seconds is more than generous.
- However, Server-Sent Events (SSE) maintain an open HTTP connection for minutes or hours. In scenarios where events occur intermittently (e.g., waiting for a long-running batch job, periodic stock alerts, or off-peak hours), an unmodified ALB will sever the client connection repeatedly.

### Solution: ALB Idle Timeout Tuning

AWS ALB allows configuring the connection idle timeout up to **4,000 seconds**.
For long-lived streaming architectures, setting:

```bash
idle_timeout.timeout_seconds = 3600
```

guarantees that connections remain open for up to 1 hour even during prolonged quiet periods. In addition, backend applications should emit lightweight keep-alive heartbeat comments (e.g., `: ping\n\n`) every 15–30 seconds.

### Target Group Deregistration Delay (Connection Draining)

When an instance in an Auto Scaling Group (ASG) or Target Group is marked for termination (due to scale-in or rolling updates), the ALB initiates **deregistration delay**:
- **Default value**: 300 seconds (5 minutes).
- The ALB stops forwarding new connections to the deregistering instance.
- Existing long-lived connections (such as SSE streams) are permitted to remain open until the deregistration delay elapses, allowing the application to drain streams gracefully before the underlying host is terminated.

### Health Check Isolation

In an SSE architecture, target group health checks must never point to the streaming endpoint (`/events`):
- Pointing health checks to `/events` will cause the health checker to hang waiting for the stream to close, resulting in health check timeouts and marking healthy nodes as `Unhealthy`.
- Always configure health checks to probe a dedicated, fast-returning lightweight endpoint like `/health` returning `200 OK`.

---

## Objectives

- Understand the lifecycle of persistent streaming connections traversing an ALB.
- Provision and configure an AWS Application Load Balancer with an HTTP listener.
- Update ALB attributes to increase the idle timeout from 60 seconds to 3600 seconds.
- Create an ALB Target Group with appropriate health check parameters and deregistration delays.
- Deploy an identical production Nginx reverse proxy stack in your Poridhi environment to emulate ALB streaming behavior locally.
- Validate that long-lived SSE connections remain connected and unbuffered through the proxy without dropping.

---

## Project Structure

```text
alb-sse-lab/
├── aws/
│   ├── create_alb.sh
│   └── alb_cloudformation.yaml
├── proxy/
│   ├── nginx.conf
│   └── docker-compose.yml
├── app/
│   ├── main.py
│   └── requirements.txt
└── test_stream.sh
```

---

## Step 1: Set Up Lab Directory

Create the lab directory structure:

```bash
mkdir -p ~/alb-sse-lab/aws ~/alb-sse-lab/proxy ~/alb-sse-lab/app
cd ~/alb-sse-lab
```

---

## Step 2: Implement the FastAPI SSE Backend

Create `app/requirements.txt`:

```bash
cat << 'EOF' > app/requirements.txt
fastapi>=0.110.0
uvicorn[standard]>=0.28.0
EOF
```

Create `app/main.py`:

```bash
cat << 'EOF' > app/main.py
import asyncio
import json
import time
import socket
from fastapi import FastAPI, Request
from fastapi.responses import StreamingResponse

app = FastAPI(title="ALB SSE Backend")

INSTANCE_HOSTNAME = socket.gethostname()


async def event_stream(request: Request):
    """Streams SSE events with instance metadata and keep-alives."""
    event_counter = 0
    try:
        while True:
            if await request.is_disconnected():
                print(f"[{INSTANCE_HOSTNAME}] Client disconnected.")
                break

            event_counter += 1
            payload = {
                "event_id": event_counter,
                "node": INSTANCE_HOSTNAME,
                "timestamp": time.strftime("%H:%M:%S"),
                "status": "STREAMING",
            }

            yield f"id: {event_counter}\nevent: message\ndata: {json.dumps(payload)}\n\n"

            # Send heartbeat every 20 seconds
            await asyncio.sleep(5.0)

    except asyncio.CancelledError:
        print(f"[{INSTANCE_HOSTNAME}] Stream cancelled.")


@app.get("/events")
async def get_events(request: Request):
    return StreamingResponse(
        event_stream(request),
        media_type="text/event-stream",
        headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache, no-transform",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.get("/health")
async def health():
    """Fast health check for load balancer target group probes."""
    return {"status": "ok", "node": INSTANCE_HOSTNAME}
EOF
```

---

## Step 3: AWS CLI Configuration for Application Load Balancer

In an AWS environment, you configure the ALB using the AWS CLI. Here are the exact commands used to deploy the ALB, set up the Target Group, and update the idle timeout to 3600 seconds.

Create `aws/create_alb.sh`:

```bash
cat << 'EOF' > aws/create_alb.sh
#!/usr/bin/env bash
set -e

VPC_ID="vpc-0123456789abcdef0" # Replace with your VPC ID
SUBNET_A="subnet-0a1b2c3d4e5f"   # Replace with Subnet A
SUBNET_B="subnet-0f5e4d3c2b1a"   # Replace with Subnet B
SEC_GROUP="sg-0987654321fedcba0" # Replace with Security Group ID

echo "=== 1. Creating Target Group for SSE Servers ==="
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --name sse-backend-tg \
    --protocol HTTP \
    --port 8000 \
    --vpc-id $VPC_ID \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path /health \
    --health-check-interval-seconds 15 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text)

echo "Target Group Created: $TARGET_GROUP_ARN"

echo "=== 2. Configuring Target Group Deregistration Delay (300 seconds) ==="
aws elbv2 modify-target-group-attributes \
    --target-group-arn $TARGET_GROUP_ARN \
    --attributes Key=deregistration_delay.timeout_seconds,Value=300

echo "=== 3. Creating Application Load Balancer ==="
ALB_ARN=$(aws elbv2 create-load-balancer \
    --name sse-alb \
    --subnets $SUBNET_A $SUBNET_B \
    --security-groups $SEC_GROUP \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text)

echo "ALB Created: $ALB_ARN"

echo "=== 4. Modifying ALB Idle Timeout to 3600s (CRITICAL FOR SSE) ==="
aws elbv2 modify-load-balancer-attributes \
    --load-balancer-arn $ALB_ARN \
    --attributes Key=idle_timeout.timeout_seconds,Value=3600

echo "=== 5. Creating HTTP Listener (Port 80) Forwarding to Target Group ==="
LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn $ALB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
    --query 'Listeners[0].ListenerArn' \
    --output text)

echo "Listener Created: $LISTENER_ARN"
echo "=== ALB Setup Complete! ==="
EOF
chmod +x aws/create_alb.sh
```

---

## Step 4: AWS CloudFormation Template

For reproducible Infrastructure as Code, create `aws/alb_cloudformation.yaml`:

```bash
cat << 'EOF' > aws/alb_cloudformation.yaml
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Application Load Balancer configured for Scalable SSE with 3600s Idle Timeout'

Parameters:
  VpcId:
    Type: AWS::EC2::VPC::Id
    Description: VPC ID for ALB and Target Group
  SubnetIds:
    Type: List<AWS::EC2::Subnet::Id>
    Description: At least two public subnets in different AZs
  SecurityGroupId:
    Type: AWS::EC2::SecurityGroup::Id
    Description: Security Group allowing port 80/443 inbound

Resources:
  SseTargetGroup:
    Type: AWS::ElasticLoadBalancingV2::TargetGroup
    Properties:
      Name: sse-alb-tg
      Port: 8000
      Protocol: HTTP
      VpcId: !Ref VpcId
      TargetType: instance
      HealthCheckProtocol: HTTP
      HealthCheckPath: /health
      HealthCheckIntervalSeconds: 15
      HealthCheckTimeoutSeconds: 5
      HealthyThresholdCount: 2
      UnhealthyThresholdCount: 3
      TargetGroupAttributes:
        - Key: deregistration_delay.timeout_seconds
          Value: '300'

  SseApplicationLoadBalancer:
    Type: AWS::ElasticLoadBalancingV2::LoadBalancer
    Properties:
      Name: sse-app-alb
      Scheme: internet-facing
      Type: application
      Subnets: !Ref SubnetIds
      SecurityGroups:
        - !Ref SecurityGroupId
      LoadBalancerAttributes:
        - Key: idle_timeout.timeout_seconds
          Value: '3600'  # 1 hour idle timeout for long-lived SSE streams

  HttpListener:
    Type: AWS::ElasticLoadBalancingV2::Listener
    Properties:
      LoadBalancerArn: !Ref SseApplicationLoadBalancer
      Port: 80
      Protocol: HTTP
      DefaultActions:
        - Type: forward
          TargetGroupArn: !Ref SseTargetGroup

Outputs:
  AlbDnsName:
    Description: ALB Public DNS Name
    Value: !GetAtt SseApplicationLoadBalancer.DNSName
  TargetGroupArn:
    Description: Target Group ARN for Auto Scaling Group
    Value: !Ref SseTargetGroup
EOF
```

---

## Step 5: Local ALB Emulation with Nginx and Docker Compose

To test this architecture directly inside the Poridhi lab environment without requiring AWS credentials, deploy an **Nginx Reverse Proxy** configured with the identical parameters as the AWS ALB (`proxy_read_timeout 3600s`, unbuffered chunking, target group round-robin).

Create `proxy/nginx.conf`:

```bash
cat << 'EOF' > proxy/nginx.conf
events {
    worker_connections 2048;
}

http {
    upstream sse_backend_tg {
        # Target Group backends
        server app1:8000 max_fails=3 fail_timeout=10s;
        server app2:8000 max_fails=3 fail_timeout=10s;
        keepalive 64;
    }

    server {
        listen 80;
        server_name localhost;

        # Health check endpoint routing
        location /health {
            proxy_pass http://sse_backend_tg/health;
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_connect_timeout 5s;
            proxy_read_timeout 10s;
        }

        # SSE Streaming endpoint routing with 3600s idle timeout
        location /events {
            proxy_pass http://sse_backend_tg/events;
            
            # Use HTTP/1.1 for upstream keepalive
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;

            # CRITICAL ALB EMULATION SETTINGS:
            # 1. Disable response buffering so chunks are forwarded immediately
            proxy_buffering off;
            proxy_cache off;
            chunked_transfer_encoding on;

            # 2. Set timeout to 3600 seconds (1 hour) matching ALB idle_timeout
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            proxy_connect_timeout 10s;

            # 3. Disable TCP delay
            tcp_nodelay on;
        }
    }
}
EOF
```

Create `proxy/docker-compose.yml` to spin up 2 backend SSE instances and the Nginx load balancer:

```bash
cat << 'EOF' > proxy/docker-compose.yml
version: '3.8'

services:
  app1:
    image: python:3.11-slim
    container_name: sse_node_1
    hostname: sse-node-1
    working_dir: /app
    volumes:
      - ../app:/app
    command: >
      sh -c "pip install -q -r requirements.txt &&
             uvicorn main:app --host 0.0.0.0 --port 8000"
    restart: unless-stopped

  app2:
    image: python:3.11-slim
    container_name: sse_node_2
    hostname: sse-node-2
    working_dir: /app
    volumes:
      - ../app:/app
    command: >
      sh -c "pip install -q -r requirements.txt &&
             uvicorn main:app --host 0.0.0.0 --port 8000"
    restart: unless-stopped

  load_balancer:
    image: nginx:alpine
    container_name: sse_alb_proxy
    ports:
      - "8080:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      - app1
      - app2
    restart: unless-stopped
EOF
```

---

## Step 6: Deploy and Verify the Cluster

Start the containers using Docker Compose:

```bash
cd ~/alb-sse-lab/proxy
docker compose up -d
```

> [!NOTE]
> Wait approximately 10–15 seconds after running `docker compose up -d` for the backend containers to download dependencies (`fastapi`, `uvicorn`) and start the Uvicorn processes. You can monitor startup progress by running:
> ```bash
> docker compose logs -f app1 app2
> ```
> Once you see `Application startup complete`, proceed to test the endpoints.

Check the status of all three services:

```bash
docker compose ps
```

Expected Output:

```text
NAME            IMAGE              COMMAND                  SERVICE         CREATED         STATUS         PORTS
sse_alb_proxy   nginx:alpine       "/docker-entrypoint.…"   load_balancer   4 seconds ago   Up 3 seconds   0.0.0.0:8080->80/tcp
sse_node_1      python:3.11-slim   "sh -c 'pip install …"   app1            4 seconds ago   Up 3 seconds   
sse_node_2      python:3.11-slim   "sh -c 'pip install …"   app2            4 seconds ago   Up 3 seconds   
```

Test health check resolution across targets:

```bash
curl -i http://localhost:8080/health
```

Expected Output:

```text
HTTP/1.1 200 OK
Server: nginx/1.25.4
Content-Type: application/json
Content-Length: 35
Connection: keep-alive

{"status":"ok","node":"sse-node-1"}
```

---

## Step 7: Validate Persistent Streaming and Load Balancing

Create a verification script `test_stream.sh`:

```bash
cat << 'EOF' > ~/alb-sse-lab/test_stream.sh
#!/usr/bin/env bash
echo "Connecting to SSE endpoint through Load Balancer on port 8080..."
echo "Receiving first 4 frames unbuffered:"
echo "---------------------------------------------------------"
curl -N -s --max-time 15 http://localhost:8080/events | head -n 16
echo "---------------------------------------------------------"
echo "Streaming verification complete!"
EOF
chmod +x ~/alb-sse-lab/test_stream.sh
~/alb-sse-lab/test_stream.sh
```

Expected Output:

```text
Connecting to SSE endpoint through Load Balancer on port 8080...
Receiving first 4 frames unbuffered:
---------------------------------------------------------
id: 1
event: message
data: {"event_id": 1, "node": "sse-node-1", "timestamp": "12:05:01", "status": "STREAMING"}

id: 2
event: message
data: {"event_id": 2, "node": "sse-node-1", "timestamp": "12:05:06", "status": "STREAMING"}

id: 3
event: message
data: {"event_id": 3, "node": "sse-node-1", "timestamp": "12:05:11", "status": "STREAMING"}
---------------------------------------------------------
Streaming verification complete!
```

---

## Conclusion

In this lab, you learned the critical configuration requirements for deploying Server-Sent Events behind an AWS Application Load Balancer. You discovered how the default 60-second idle timeout causes unexpected drops, configured the ALB idle timeout attribute to `3600` seconds via the AWS CLI and CloudFormation, isolated target group health checks on `/health`, and deployed a local Nginx load-balanced target group replicating this production architecture. In the next module, you will configure an **Auto Scaling Group** to dynamically scale the SSE fleet based on active connection load.
