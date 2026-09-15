# Module 61 - Lab 23: Deploy RabbitMQ and Flower on a remote server

You will deploy a remote task processing environment using Docker Compose. The setup includes a RabbitMQ message broker, a Celery worker to execute background jobs, and a Flower dashboard to monitor the task queue in real-time. Finally, you will expose the local Flower interface to the public internet securely using a Cloudflare Quick Tunnel.

![Lab 23 Architecture Overview](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/23.drawio.svg)

## Concepts

| Term | Definition |
| --- | --- |
| RabbitMQ | A robust message broker that receives, stores, and routes tasks to workers. |
| Flower | A web-based tool for monitoring and administrating Celery clusters. |
| Cloudflare Tunnel | A secure connection that exposes local services to the internet without opening inbound firewall ports. |

## Objectives

- Build a `docker-compose.yml` to orchestrate RabbitMQ, Celery Worker, and Flower.
- Implement a background Celery task in Python.
- Configure Cloudflare Tunnel to expose the Flower dashboard.
- Verify the successful execution of tasks via the command line and Flower UI.

## What You Will Build

```text
lab23-rabbitmq-flower/
├── docker-compose.yml
└── worker/
    └── tasks.py
```
You will build a multi-container environment where a Python worker executes background tasks delivered through RabbitMQ, while Flower monitors the task lifecycle.

## Step 1: Create the lab directories

Run the following commands:

```bash
mkdir -p ~/lab23-rabbitmq-flower/worker
cd ~/lab23-rabbitmq-flower
```

![Create Directory](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image.png)

**Explanation:**
- `mkdir -p .../worker`: Creates the project directory and a nested `worker` directory for the Celery tasks.
- `cd ...`: Changes into the project root directory.

## Step 2: Define the Docker Compose configuration

Create a file named `docker-compose.yml` with the following contents:

```bash
cat > docker-compose.yml <<'EOF'
services:

  rabbitmq:
    image: rabbitmq:3-management
    container_name: lab23-rabbitmq
    hostname: rabbitmq
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: celery
      RABBITMQ_DEFAULT_PASS: celery123
    ports:
      - "5672:5672"
      - "15672:15672"
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq

  worker:
    image: python:3.11-slim
    container_name: lab23-worker
    working_dir: /app
    command: >
      sh -c "pip install -q celery &&
      celery -A tasks worker --loglevel=info"
    environment:
      CELERY_BROKER_URL: amqp://celery:celery123@rabbitmq:5672//
    volumes:
      - ./worker:/app
    depends_on:
      - rabbitmq

  flower:
    image: mher/flower:2.0
    container_name: lab23-flower
    restart: unless-stopped
    command:
      - "celery"
      - "--broker=amqp://celery:celery123@rabbitmq:5672//"
      - "flower"
      - "--port=5555"
    ports:
      - "5555:5555"
    depends_on:
      - rabbitmq

volumes:
  rabbitmq_data:
EOF
```

![Create Docker Compose](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(2).png)

**Explanation:**
- `rabbitmq`: Runs the RabbitMQ server with the management plugin enabled, mapping required ports and setting default credentials.
- `flower`: Runs the Flower monitoring tool, connecting to the RabbitMQ broker, and mapping port 5555.
- `worker`: Uses a lightweight Python image to install Celery at runtime and start a worker process that looks for a `tasks` module.
- `volumes: rabbitmq_data`: Defines a persistent storage volume so messages are not lost upon container restart.

## Step 3: Create the Celery tasks file

Run the following command to create the task definitions inside the `worker` directory:

```bash
cat > worker/tasks.py <<'EOF'
import time
from celery import Celery

app = Celery(
    "tasks",
    broker="amqp://celery:celery123@rabbitmq:5672//",
    backend="rpc://",
)

@app.task
def add(x, y):
    time.sleep(2)
    return x + y
EOF
```

![Create Tasks](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(3).png)

Run the following command to verify the directory structure:

```bash
find . -maxdepth 2 -type f -print
```

![Verify Structure](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(4).png)

**Explanation:**
- `app = Celery(...)`: Initializes a Celery application using RabbitMQ as the broker and RPC as the backend.
- `@app.task`: Registers `add` as a background task.
- `find . -maxdepth 2 -type f -print`: Lists all files in the current directory and immediate subdirectories to confirm `docker-compose.yml` and `worker/tasks.py` exist.

## Step 4: Validate and start the services

Run the following command to validate the compose file:

```bash
docker compose config
```

![Validate Compose](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(5).png)

Run the following command to start the services in detached mode:

```bash
docker compose up -d
```

![Start Services](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(6).png)

Run the following command to check the running containers:

```bash
docker compose ps
```

![Check Containers](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(7).png)

Run the following command to view the worker logs and ensure it connected successfully:

```bash
docker compose logs --tail=50 worker
```

![Check Worker Logs](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(8).png)

**Explanation:**
- `docker compose config`: Validates and views the parsed Compose file.
- `docker compose up -d`: Builds, (re)creates, starts, and attaches to containers for a service in detached mode.
- `docker compose ps`: Lists the containers and their current status.
- `docker compose logs --tail=50 worker`: Outputs the last 50 lines of logging information specific to the worker container. (You may see retry attempts until RabbitMQ is fully ready).

## Verification

Run the following command to dispatch a task to the Celery worker:

```bash
docker compose exec worker python -c "from tasks import add; r=add.delay(10,20); print('Task ID:', r.id)"
```

**Expected output:**
```text
Task ID: [UUID string]
```

![Send Task](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(9).png)

Run the worker logs command again to verify the task execution:

```bash
docker compose logs --tail=50 worker
```

![Verify Task Logs](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(10).png)

## Step 5: Download and configure Cloudflare Tunnel

To monitor tasks via Flower remotely, run the following commands:

```bash
cd ~/lab23-rabbitmq-flower
curl -L --output cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
chmod +x cloudflared
```

![Download Cloudflared](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(11).png)

**Explanation:**
- `curl -L --output cloudflared ...`: Downloads the latest Linux binary for `cloudflared` from GitHub.
- `chmod +x cloudflared`: Adds execution permissions to the downloaded binary so it can be run as a program.

## Step 6: Start the Cloudflare Tunnel

Run the following command to initiate the tunnel:

```bash
./cloudflared tunnel --url http://localhost:5555
```

![Start Tunnel](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(12).png)

*(Note: Running `docker compose config`, `docker compose up -d` and `docker compose ps` in a new terminal, as seen below, can be done to simply verify services are still running correctly without disruption.)*

![Check Config Again 1](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(13).png)
![Check Config Again 2](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(14).png)

To access the Flower dashboard and verify task completion, open the generated `https://<tunnel-id>.trycloudflare.com` URL (provided in the `cloudflared` terminal output) in your web browser.

- Navigate to the **Tasks** tab (or visit `https://<tunnel-id>.trycloudflare.com/tasks`) to see the executed task.

![Flower Tasks](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(15).png)

- Navigate to the **Workers** tab (or visit `https://<tunnel-id>.trycloudflare.com/workers`) to see the active worker node.

![Flower Workers](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab23/Pasted%20image%20(16).png)

## Conclusion

You built a distributed background processing architecture using RabbitMQ, Celery, and Flower. The services were orchestrated with Docker Compose, and remote web access to the monitoring dashboard was securely exposed via a Cloudflare Quick Tunnel.
