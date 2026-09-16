# Lab 14 — Flask Integration with Celery + Redis

![Lab 14 Architecture Overview](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/lab_14.drawio.svg)

## Overview

You will build a Flask web application integrated with Celery and Redis. This setup allows the Flask API to offload long-running background tasks to a Celery worker asynchronously, using Redis as both the message broker and result backend.

## 1. Update system

```bash
sudo apt update -y
```

![Update System](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image.png)

Optional: clear existing processes using the required ports:

```bash
sudo fuser -k 6379/tcp || true
sudo fuser -k 5000/tcp || true
```

---

## 2. Create project

```bash
mkdir -p celery-lab
cd celery-lab
```

Create virtual environment:

```bash
python3 -m venv venv
```

Activate it:

```bash
source venv/bin/activate
```

You should see:

```text
(venv)
```

in your terminal.

![Create Project](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(2).png)

---

# 3. Install Python packages

```bash
pip install flask celery redis
```

![Install Packages](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(6).png)

Verify:

```bash
pip list
```

You should have:

```text
celery
Flask
redis
```

![Verify Packages](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(7).png)

---

# 4. Install Redis

```bash
sudo apt install -y redis-server
```

Start Redis:

```bash
sudo systemctl start redis-server
```

Check Redis:

```bash
sudo systemctl status redis-server
```

You should see:

```text
Active: active (running)
```

Press `q` to leave the status screen.

Then test Redis:

```bash
redis-cli ping
```

Expected:

```text
PONG
```

![Install Redis](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(5).png)

---

# 5. Create `app.py`

Since your Poridhi environment doesn't have `nano`, use:

```bash
cat > app.py <<'PY'
import time

from flask import Flask, jsonify, request
from celery import Celery

# --------------------------------------------------
# Flask Application
# --------------------------------------------------

app = Flask(__name__)


# --------------------------------------------------
# Celery Configuration
# Redis is used as:
# 1. Message Broker
# 2. Result Backend
# --------------------------------------------------

celery = Celery(
    "app",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/0"
)


# --------------------------------------------------
# Celery Background Task
# --------------------------------------------------

@celery.task(name="send_email_task")
def send_email_task(to_email):

    # Simulate a long-running task
    time.sleep(10)

    return f"Email sent to {to_email}"


# --------------------------------------------------
# Flask API: Submit Email Task
# --------------------------------------------------

@app.route("/send-email", methods=["POST"])
def send_email():

    data = request.get_json()

    # Check whether JSON body exists
    if not data:
        return jsonify({
            "error": "JSON body is required"
        }), 400

    # Get email address
    to_email = data.get("to")

    # Check required field
    if not to_email:
        return jsonify({
            "error": "to field is required"
        }), 400

    # Send task to Celery asynchronously
    task = send_email_task.delay(to_email)

    # Immediately return task ID
    return jsonify({
        "message": "Email is being sent in the background",
        "task_id": task.id
    }), 202


# --------------------------------------------------
# Flask API: Check Task Status
# --------------------------------------------------

@app.route("/task-status/<task_id>", methods=["GET"])
def task_status(task_id):

    # Get task information using task ID
    task = send_email_task.AsyncResult(task_id)

    response = {
        "task_id": task_id,
        "status": task.status
    }

    # Return result if task completed successfully
    if task.status == "SUCCESS":
        response["result"] = task.result

    return jsonify(response)


# --------------------------------------------------
# Run Flask Application
# --------------------------------------------------

if __name__ == "__main__":

    app.run(
        host="0.0.0.0",
        port=5000,
        debug=True,
        use_reloader=False
    )
PY
```

![Create app.py](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(8).png)

---

# 6. Check the file

```bash
ls
```

You should see:

```text
app.py
venv
```

Check syntax:

```bash
python3 -m py_compile app.py
```

If there is **no output**, the syntax is correct.

![Check File](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(9).png)

---

# 7. Start Flask

In **Terminal 1**:

```bash
cd celery-lab
source venv/bin/activate
python3 app.py
```

Expected:

```text
* Serving Flask app 'app'
* Debug mode: on
* Running on all addresses (0.0.0.0)
* Running on http://127.0.0.1:5000
```

Keep this terminal running.

**Do not press `Ctrl+C`.**

---

# 8. Start Celery Worker

Open **Terminal 2**.

Run:

```bash
cd celery-lab
source venv/bin/activate
```

Then:

```bash
celery -A app.celery worker --loglevel=info
```

You should see something similar to:

```text
transport: redis://localhost:6379/0
results: redis://localhost:6379/0
```

And:

```text
[tasks]
    . send_email_task
```

Finally:

```text
celery@xxxxxxxx ready.
```

![Start Celery](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(10).png)

Keep this terminal running too.

---

# 9. Submit a background task

Open **Terminal 3**.

Run:

```bash
curl -X POST http://127.0.0.1:5000/send-email \
  -H "Content-Type: application/json" \
  -d '{"to": "user@example.com"}' 
```

Expected:

```json
{
  "message": "Email is being sent in the background",
  "task_id": "YOUR-TASK-ID"
}
```

For example:

```json
{
  "message": "Email is being sent in the background",
  "task_id": "a8aa5c5e-b62f-4995-872d-27846b581292"
}
```

**Copy your actual task ID.**

![Submit Task](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(11).png)

---

# 10. Check task status

Replace `YOUR-TASK-ID` with your actual ID:

```bash
curl http://127.0.0.1:5000/task-status/YOUR-TASK-ID
```

Immediately after submitting, you may see:

```json
{
  "status": "PENDING",
  "task_id": "YOUR-TASK-ID"
}
```

Because the task takes 10 seconds.

---

# 11. Check completed task

Wait approximately 10–15 seconds.

Then run:

```bash
curl http://127.0.0.1:5000/task-status/YOUR-TASK-ID
```

Expected:

```json
{
  "result": "Email sent to user@example.com",
  "status": "SUCCESS",
  "task_id": "YOUR-TASK-ID"
}
```

![Check Status](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab14/Pasted%20image%20(12).png)

---

# 12. Test missing `to` field

Run:

```bash
curl -X POST http://127.0.0.1:5000/send-email \
  -H "Content-Type: application/json" \
  -d '{}' 
```

Expected:

```json
{
  "error": "to field is required"
}
```

This should return HTTP `400`.

---

# 13. Test empty JSON/body

You can also test:

```bash
curl -X POST http://127.0.0.1:5000/send-email \
  -H "Content-Type: application/json" \
  -d '' 
```

Expected:

```json
{
  "error": "JSON body is required"
}
```

---

## Conclusion

In this lab, you successfully integrated Flask with Celery and Redis to handle asynchronous background tasks. You configured Redis as the message broker and result backend, and verified the task execution flow through the Flask API.
