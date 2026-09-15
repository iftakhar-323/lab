# Module 58 and 59 - Lab 17: Monitoring & Observability

You will build a Flask API that dispatches background tasks to a Celery worker using a Redis broker. You will implement Flower to observe task execution metrics and worker states in real-time. You will configure Nginx as a reverse proxy secured with HTTP Basic Authentication to protect the Flower dashboard.

![Lab 17 Architecture Overview](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Untitled%20Diagram.drawio.svg)

## Concepts

| Term | Definition |
| --- | --- |
| Flower | A web-based tool for monitoring and administrating Celery clusters. |
| Nginx | A web server used as a reverse proxy to manage and secure incoming traffic. |
| Basic Authentication | A method for HTTP user agents to provide a username and password when making a request. |

Flower connects to the Celery broker to ingest real-time data about workers and tasks. Nginx intercepts HTTP requests directed at the dashboard, enforces basic authentication, and proxies legitimate requests to the internal Flower process running on a separate port.

## Objectives

- Configure a virtual environment and install dependencies.
- Build a Flask API and a Celery task queue backed by Redis.
- Implement a Flower dashboard to monitor task execution and worker health.
- Configure Nginx as a reverse proxy with Basic Authentication.
- Verify task generation and secure dashboard access.

## What You Will Build

```text
~/lab17
├── app.py
├── tasks.py
└── venv/
```
The Flask API (`app.py`) triggers background tasks in `tasks.py` which are monitored by Flower and secured by Nginx.

## Step 1: Create the project directory

Run the following command:
```bash
mkdir -p ~/lab17 && cd ~/lab17
```
![Create Directory](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image.png)

**Explanation:**
- `mkdir -p ~/lab17`: Creates a directory named `lab17` in the home directory.
- `cd ~/lab17`: Changes the current working directory to `lab17`.

## Step 2: Start the Redis broker

Run the following command:
```bash
docker run -d --name lab17-redis -p 6379:6379 redis:7
```
![Verify Redis Status](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(2).png)

**Explanation:**
- `docker run -d`: Runs the container in detached mode.
- `--name lab17-redis`: Assigns the name `lab17-redis` to the container.
- `-p 6379:6379`: Maps port 6379 on the host to port 6379 on the container.
- `redis:7`: Specifies the Redis image version to use as the broker.

## Step 3: Install Nginx and utilities

Run the following command:
```bash
sudo apt update
sudo apt install -y nginx apache2-utils python3.12-venv
```
![Install Nginx](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(3).png)

**Explanation:**
- `sudo apt update`: Refreshes the local package index.
- `sudo apt install -y`: Installs the specified packages without requiring manual confirmation.
- `nginx`: Installs the Nginx web server for the reverse proxy.
- `apache2-utils`: Installs utilities including `htpasswd` for creating authentication credentials.
- `python3.12-venv`: Installs the module to create isolated Python environments.

## Step 4: Setup the virtual environment

Run the following command:
```bash
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
```
![Setup Virtualenv](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(4).png)

**Explanation:**
- `python3 -m venv venv`: Creates a virtual environment directory named `venv`.
- `source venv/bin/activate`: Activates the virtual environment.
- `pip install --upgrade pip`: Upgrades the Python package manager to the latest version.

## Step 5: Install Python dependencies

Run the following command:
```bash
pip install Flask Celery redis flower
```
![Install Packages](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(5).png)

**Explanation:**
- `pip install`: Installs the specified Python packages.
- `Flask`: The web framework for the API.
- `Celery`: The distributed task queue system.
- `redis`: The Python client for interacting with the Redis broker.
- `flower`: The monitoring tool for Celery clusters.

## Step 6: Create the Celery tasks configuration

Create a file named `~/lab17/tasks.py` with the following contents:
```python
import os
import time
import random

from celery import Celery

REDIS_HOST = os.getenv("REDIS_HOST", "localhost")
REDIS_PORT = os.getenv("REDIS_PORT", "6379")

BROKER_URL = f"redis://{REDIS_HOST}:{REDIS_PORT}/0"
RESULT_BACKEND = f"redis://{REDIS_HOST}:{REDIS_PORT}/1"

celery = Celery(
    "lab17",
    broker=BROKER_URL,
    backend=RESULT_BACKEND
)

@celery.task(bind=True)
def process_data_task(self, data_id):
    print(f"Processing data item {data_id}...")
    time.sleep(random.randint(2, 5))
    
    if random.random() < 0.2:
        raise ValueError(f"Simulated processing error for item {data_id}")
        
    return {"data_id": data_id, "status": "processed"}
```
**Explanation:**
- `REDIS_HOST` and `REDIS_PORT`: Retrieves Redis connection details from environment variables or uses defaults.
- `BROKER_URL`: Constructs the connection string for the message broker on database 0.
- `RESULT_BACKEND`: Constructs the connection string for storing task results on database 1.
- `celery = Celery(...)`: Initializes the Celery application with the defined broker and backend.
- `@celery.task(bind=True)`: Decorates the function to register it as a Celery task, binding the instance to `self`.
- `time.sleep(...)`: Simulates a long-running process by pausing execution randomly.
- `if random.random() < 0.2:`: Introduces a 20% chance of failure to generate error metrics for observability.
- `raise ValueError(...)`: Throws an error for the simulated failure.
- `return ...`: Provides the final result payload on successful execution.

## Step 7: Create the Flask API

Create a file named `~/lab17/app.py` with the following contents:
```python
from flask import Flask, jsonify, request
from tasks import celery, process_data_task

app = Flask(__name__)

@app.route("/", methods=["GET"])
def home():
    return jsonify({
        "message": "Lab 17 Monitoring API",
        "flower_url": "Secure access via Nginx (http://localhost:8080)"
    })

@app.route("/trigger", methods=["POST"])
def trigger_tasks():
    data = request.get_json(silent=True) or {}
    count = data.get("count", 5)
    
    task_ids = []
    for i in range(count):
        task = process_data_task.delay(i)
        task_ids.append(task.id)
        
    return jsonify({
        "message": f"{count} tasks successfully pushed to the queue.",
        "task_ids": task_ids
    }), 202

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
```
**Explanation:**
- `app = Flask(__name__)`: Initializes the Flask application.
- `@app.route("/", methods=["GET"])`: Defines a root endpoint to confirm the API is running.
- `@app.route("/trigger", methods=["POST"])`: Defines an endpoint to trigger multiple background tasks.
- `count = data.get("count", 5)`: Parses the requested number of tasks to execute, defaulting to 5.
- `process_data_task.delay(i)`: Dispatches the task to the Celery queue asynchronously.
- `task_ids.append(task.id)`: Collects the unique identifier for each dispatched task.
- `return jsonify(...), 202`: Returns a JSON response containing the task IDs with an HTTP 202 Accepted status code.
- `app.run(...)`: Starts the Flask development server on all network interfaces over port 5000.

## Step 8: Generate basic authentication credentials

Run the following command:
```bash
sudo htpasswd -bc /etc/nginx/.htpasswd admin admin123
```
![Create htpasswd](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(6).png)

**Explanation:**
- `sudo htpasswd`: Executes the Apache utility to manage basic authentication files.
- `-b`: Uses batch mode to supply the password directly in the command.
- `-c`: Creates a new file at `/etc/nginx/.htpasswd`.
- `admin`: Sets the username for the authentication prompt.
- `admin123`: Sets the password for the specified user.

## Step 9: Configure the Nginx reverse proxy

Run the following command:
```bash
sudo bash -c 'cat << EOF > /etc/nginx/sites-available/flower
server {
    listen 8080;
    server_name _;

    location / {
        auth_basic "Restricted Access";
        auth_basic_user_file /etc/nginx/.htpasswd;
        
        proxy_pass http://127.0.0.1:5555;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF'
sudo ln -s /etc/nginx/sites-available/flower /etc/nginx/sites-enabled/
sudo systemctl restart nginx
```
![Nginx Config](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(7).png)

**Explanation:**
- `sudo bash -c`: Executes the file creation and command string with administrative privileges.
- `listen 8080;`: Configures Nginx to listen on port 8080 for incoming HTTP traffic.
- `auth_basic "Restricted Access";`: Enables Basic Authentication and sets the prompt message.
- `auth_basic_user_file ...`: Points Nginx to the generated `.htpasswd` file for verifying credentials.
- `proxy_pass http://127.0.0.1:5555;`: Forwards the authenticated traffic to the internal Flower dashboard running on port 5555.
- `proxy_set_header ...`: Preserves the original client headers through the proxy forwarding process.
- `sudo ln -s ...`: Creates a symbolic link to enable the site configuration.
- `sudo systemctl restart nginx`: Restarts the Nginx service to apply the new configuration.

## Step 10: Start the application services

Run the following command to configure Nginx and start the Flask API:
```bash
sudo ln -s /etc/nginx/sites-available/flower /etc/nginx/sites-enabled/
sudo systemctl restart nginx
cd ~/lab17 && source venv/bin/activate
python app.py
```
![Start Flask API](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(8).png)

Run the following command to start the Celery worker:
```bash
cd ~/lab17 && source venv/bin/activate
celery -A tasks.celery worker --loglevel=info
```
![Start Celery Worker](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(9).png)

Run the following command to start Flower:
```bash
cd ~/lab17 && source venv/bin/activate
celery -A tasks.celery flower --port=5555
```
![Start Flower](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(10).png)

**Explanation:**
- `source ~/lab17/venv/bin/activate`: Activates the Python virtual environment.
- `python app.py`: Starts the Flask API server.
- `celery -A tasks.celery worker --loglevel=info`: Starts the Celery worker process.
- `celery -A tasks.celery flower --port=5555`: Starts the Flower dashboard process.

## Verification

**1. Verify API health**
Run the following command:
```bash
curl -s -X GET http://localhost:5000/
```
Expected output:
```json
{
  "flower_url": "Secure access via Nginx (http://localhost:8080)",
  "message": "Lab 17 Monitoring API"
}
```

**2. Trigger Celery tasks**
Run the following command:
```bash
curl -s -X POST http://localhost:5000/trigger -H "Content-Type: application/json" -d '{"count":2}'
```
![Trigger Tasks](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab17/Pasted%20image%20(11).png)
Expected output:
```json
{
  "message": "2 tasks successfully pushed to the queue.",
  "task_ids": [
    "b8c3a9f0-d9d2-43f1-b552-e5b1eb887f43",
    "f2f183b0-56ef-466a-bb63-5af22b3de9b1"
  ]
}
```

**3. Verify secure dashboard access (Failure)**
Run the following command:
```bash
curl -s -I http://localhost:8080/ | head -n 1
```
Expected output:
```text
HTTP/1.1 401 Unauthorized
```

**4. Verify secure dashboard access (Success)**
Run the following command:
```bash
curl -s -u admin:admin123 -I http://localhost:8080/ | head -n 1
```
Expected output:
```text
HTTP/1.1 200 OK
```

*(Note: You can also open `http://<your-loadbalancer-ip>:8080/` in a web browser. Enter `admin` as the username and `admin123` as the password to view the Flower dashboard.)*

| # | Call | Status | Body snippet |
| --- | --- | --- | --- |
| 1 | `GET /` | 200 | "message": "Lab 17 Monitoring API" |
| 2 | `POST /trigger` | 202 | "message": "2 tasks successfully pushed to the queue." |
| 3 | `GET :8080/` | 401 | WWW-Authenticate: Basic realm="Restricted Access" |
| 4 | `GET :8080/ (Auth)`| 200 | HTTP/1.1 200 OK |

## Conclusion

You built a robust background task system using Flask, Celery, and Redis. You configured a Flower dashboard to monitor the task queues and successfully secured it using Nginx and Basic Authentication.
