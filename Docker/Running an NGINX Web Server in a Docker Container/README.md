# Running an NGINX Web Server in a Docker Container

![Docker](https://img.shields.io/badge/Docker-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![NGINX](https://img.shields.io/badge/NGINX-009639?style=for-the-badge&logo=nginx&logoColor=white)
![Puku](https://img.shields.io/badge/Puku-CLI-4F46E5?style=for-the-badge)
![Level](https://img.shields.io/badge/Level-Beginner-22C55E?style=for-the-badge)

> **Prerequisites:** Familiarity with terminal commands and a basic understanding of how web servers respond to HTTP requests.

---

## 📑 Table of Contents

1. [Introduction](#-introduction)
2. [Learning Objectives](#-learning-objectives)
3. [Architecture Overview](#-architecture-overview)
4. [Prologue — The Challenge](#-prologue--the-challenge)
5. [Environment Setup](#-environment-setup)
6. [Chapter 1 — Images and the Docker Hub Registry](#-chapter-1--images-and-the-docker-hub-registry)
7. [Chapter 2 — Serving Content with Volume Mounts](#-chapter-2--serving-content-with-volume-mounts)
8. [Chapter 3 — Inspecting a Running Container](#-chapter-3--inspecting-a-running-container)
9. [Chapter 4 — Container Lifecycle Management](#-chapter-4--container-lifecycle-management)
10. [Epilogue — The Complete System](#-epilogue--the-complete-system)
11. [The Principles](#-the-principles)
12. [Troubleshooting](#-troubleshooting)
13. [Next Steps](#-next-steps)
14. [Additional Resources](#-additional-resources)

---

## 📘 Introduction

This lab teaches you how to deploy an **NGINX web server** inside a **Docker container** using the **Puku CLI** integrated terminal. You will pull an official image from Docker Hub, mount a custom HTML directory into the container, manage the container lifecycle, and verify a running web service — **without installing Docker locally**.

By the end, you will have a reproducible web server environment that runs identically anywhere Docker is available.

---

## 🎯 Learning Objectives

By the end of this lab, you will be able to:

- ✅ Pull a Docker image from Docker Hub and verify it locally
- ✅ Create and serve a custom HTML page from a running Docker container
- ✅ Configure port mapping and volume mounts in a `docker run` command
- ✅ Inspect container status, logs, and networking using Docker CLI commands
- ✅ Stop, restart, and remove containers cleanly

---

## 🏗️ Architecture Overview

The following diagram shows the complete flow this lab implements — from Docker Hub to a running container serving your HTML content.

```text
┌──────────────────┐   docker pull   ┌──────────────────┐
│   Docker Hub     │ ───────────────▶│  nginx:latest    │
│   (registry)     │                 │  (local image)   │
└──────────────────┘                 └────────┬─────────┘
                                              │ docker run
                                              ▼
                                     ┌──────────────────┐
                                     │    my-nginx      │
                                     │  (container ·    │
                                     │   port 80 · Up)  │
                                     └────────┬─────────┘
                                              │ -p 8080:80
                                              ▼
                                     ┌──────────────────┐
                                     │ localhost:8080   │
                                     └──────────────────┘
```

**Mount mapping (read-only):**

| Host Path | Container Path | Mode |
|---|---|---|
| `nginx-lab/html/` | `/usr/share/nginx/html` | `:ro` (read-only) |

**Request flow:** `curl http://localhost:8080` → host forwards to container port 80 → NGINX reads mounted `index.html` → HTML response returned.

---

## 📖 Prologue — The Challenge

**Scenario**

You join a team that maintains a set of internal documentation portals. A colleague built one locally — and it works on *their* machine. When the service moves to a shared server, nothing works: missing dependencies, wrong versions, port conflicts.

The infrastructure lead assigns you a task:

> **Containerize the web server so the environment is reproducible anywhere. Use NGINX in Docker.**

**Your deliverable:** A running NGINX container that serves a custom HTML page, mapped to a host port, with its content directory mounted from the project workspace.

---

## 🛠️ Environment Setup

**Step 1.** Open **Puku CLI** and launch the integrated terminal.

**Step 2.** Verify Docker is available:

```bash
docker --version
```

**Expected output:**

```text
Docker version 24.x.x, build ...
```

**Step 3.** Create the project directory structure:

```bash
mkdir -p nginx-lab/html
```

---

# 📦 Chapter 1 — Images and the Docker Hub Registry

> Docker does not require you to build every image from scratch. **Docker Hub** provides official, maintained images for common software. Before running a container, you pull its image.

### 🎯 1.1 What You Will Build

In this chapter, you will **pull the official NGINX image** and verify it is available on your local machine.

### 💭 1.2 Think First: Images vs. Containers

Consider the following two statements:

> *"The NGINX **image** is running."* vs. *"The NGINX **container** is running."*

**Question:** Which statement is technically accurate, and what is the difference between an image and a container?

<details>
<summary>🔎 Click to reveal the answer</summary>

Only a **container** can "run."

- An **image** is a *read-only template* — a snapshot of a filesystem and configuration.
- A **container** is a *running instance* created from that image.

One image can produce many containers simultaneously, each isolated from the others.

✅ **Correct statement:** *"The NGINX **container** is running."*
</details>

### ⬇️ 1.3 Pull the NGINX Image

Run the following command to download the latest official NGINX image from Docker Hub:

```bash
docker pull nginx
```

Docker downloads each layer of the image in parallel and confirms each layer as it completes.

![docker pull nginx — terminal output showing layer downloads](images/docker-pull-nginx.png)

**Expected output:**

```text
Using default tag: latest
latest: Pulling from library/nginx
1645c1e06f46: Pull complete
1b30016634d5: Pull complete
e95a6c7ea7d4: Pull complete
acf093e7a04f: Pull complete
cd9307c9ecd8: Pull complete
fcb6fd84b2a0: Pull complete
df68ee7e7a80: Pull complete
1cf7d051b485: Download complete
e2c07e54e55a: Download complete
Digest: sha256:ec4ed8b5299e5e90694af7750eb6dffd2627317d30544d056b0371f8082f7bce
Status: Downloaded newer image for nginx:latest
docker.io/library/nginx:latest
```

### ✅ 1.4 Verify the Download

Confirm the image is available locally:

```bash
docker images
```

![docker images — listing local Docker images](images/docker-images-output.png)

**Predict:** What columns will this command display?

<details>
<summary>🔎 Click to verify</summary>

The columns are **`REPOSITORY`**, **`TAG`**, **`IMAGE ID`**, **`CREATED`**, and **`SIZE`**. The `nginx` image with tag `latest` appears in the list, alongside any other images already present on the machine.

**Sample output:**

```text
REPOSITORY   TAG       IMAGE ID       CREATED       SIZE
nginx        latest    ec4ed8b5299e   2 weeks ago   241MB
```
</details>

> 💡 **Note:** The screenshot above shows additional project images already on this machine. Only the `nginx:latest` row is relevant to this lab.

### 🧾 Checkpoint 1

- [ ] `docker pull nginx` completed without errors
- [ ] `docker images` lists `nginx` with the `latest` tag
- [ ] You can explain the difference between an image and a container

---

# 📂 Chapter 2 — Serving Content with Volume Mounts

> An NGINX container started without configuration serves only its default welcome page. To serve your own content, you **mount a local directory into the container's web root**. Any HTML file placed in that directory becomes immediately available through the running server.

### 🎯 2.1 What You Will Build

In this chapter, you will:
1. Create a custom HTML file
2. Run the NGINX container with a volume mount and port mapping
3. Verify the server returns your custom content

### 🔁 2.2 The Volume Mount and Port Mapping Flow

```text
   Host Machine                              my-nginx Container
   ─────────────                             ──────────────────
   nginx-lab/html/index.html                 /usr/share/nginx/html
       (your content       --v mount :ro-->      (container web root,
        on host disk)                            read-only)

   localhost:8080          --p 8080:80-->     NGINX port 80
       (external access)                       (internal listener)
```

### 💭 2.3 Think First: Port Mapping

The NGINX server inside the container listens on **port 80**. Your host machine cannot directly access port 80 inside the container.

**Question:** What does the `-p 8080:80` flag accomplish, and which number refers to the host?

<details>
<summary>🔎 Click to reveal the answer</summary>

The `-p` flag maps a **host port** to a **container port**. The format is `host_port:container_port`.

`-p 8080:80` means: requests arriving at **port 8080** on your host machine are forwarded to **port 80** inside the container. The **first number (8080) is the host port**.

Without this mapping, the container's network is isolated and unreachable from outside.
</details>

### 📝 2.4 Create the HTML Page

```bash
echo '<h1>Hello from NGINX running in Docker!</h1>' > nginx-lab/html/index.html
```

```bash
cat nginx-lab/html/index.html
```

**Expected output:**

```html
<h1>Hello from NGINX running in Docker!</h1>
```

### 🚀 2.5 Run the NGINX Container

Complete the following `docker run` command by filling in the blanks:

```bash
docker run --name my-nginx \
  -v $(pwd)/nginx-lab/html:/usr/share/nginx/html:___ \   # Q1: What mode prevents the container from writing?
  -p ___:80 \                                            # Q2: Which host port to expose?
  -_ nginx                                                # Q3: Which flag runs detached?
```

**Hints:**

| Question | Hint |
|---|---|
| Q1 | Two-letter abbreviation for "read-only" |
| Q2 | Use port **8080** (common choice) |
| Q3 | Single-letter flag |

<details>
<summary>✅ Click to see the solution</summary>

```bash
docker run --name my-nginx \
  -v $(pwd)/nginx-lab/html:/usr/share/nginx/html:ro \
  -p 8080:80 \
  -d nginx
```

**Flag breakdown:**

| Flag | Purpose |
|---|---|
| `--name my-nginx` | Assigns a human-readable name to the container |
| `-v .../html:/usr/share/nginx/html:ro` | Mounts local directory into container web root, **read-only** |
| `-p 8080:80` | Maps host port 8080 to container port 80 |
| `-d` | Runs the container in **detached** (background) mode |

> ⚠️ **Windows PowerShell:** replace `$(pwd)` with `${PWD}`.
</details>

![docker run command — terminal output showing container ID](images/docker-run-command.png)

**Expected output (container ID):**

```text
8106ee13f2aab334720b134d3b913e9b0a42f1712b13d8fcbeba0b3150a0066bb
```

### 🧪 2.6 Test and Verify

**Predict:** What will the following command return?

```bash
curl http://localhost:8080
```

<details>
<summary>🔎 Click to verify</summary>

**Expected output:**

```html
<h1>Hello from NGINX running in Docker!</h1>
```

The command sends an HTTP GET request to port 8080. The host forwards this to port 80 inside the container. NGINX reads `index.html` from the mounted volume and returns its contents.

The same result appears when visiting `http://localhost:8080` in a browser:

![Browser showing the served HTML page at localhost:8080](images/browser-test-result.png)
</details>

### 🧾 Checkpoint 2

- [ ] Container started without errors and returned a container ID
- [ ] `curl http://localhost:8080` returns your custom HTML
- [ ] You can explain what `:ro` prevents and why it matters for web serving
- [ ] You can predict what happens if `-p 8080:80` is omitted

---

# 🔍 Chapter 3 — Inspecting a Running Container

> A container running in **detached mode** produces no output in the terminal. Docker provides commands to inspect its state, examine its logs, and confirm network configuration — **without interrupting the service**.

### 💭 3.1 Think First: Reading Container Status

**Question:** A teammate tells you a container shows status `Up 2 minutes (unhealthy)`. What does this indicate, and how does it differ from `Up 2 minutes`?

<details>
<summary>🔎 Click to reveal the answer</summary>

- `Up 2 minutes` → the container **process is running**.
- `Up 2 minutes (unhealthy)` → the container process is running, but a **configured health check is failing**. The process has not crashed, but the service inside it is not passing its own readiness tests.

This distinction matters in production: a load balancer should route traffic only to **healthy** containers.
</details>

### 📋 3.2 Check Running Containers

```bash
docker ps
```

![docker ps — listing the running my-nginx container](images/docker-ps-output.png)

**Expected output:**

```text
CONTAINER ID   IMAGE   COMMAND                  CREATED         STATUS        PORTS                  NAMES
8106ee13f2aa   nginx   "/docker-entrypoint…"   3 minutes ago   Up 3 minutes  0.0.0.0:8080->80/tcp   my-nginx
```

Verify in the output:

| Column | Value |
|---|---|
| `NAMES` | `my-nginx` |
| `STATUS` | `Up` |
| `PORTS` | `0.0.0.0:8080->80/tcp` |

### 📜 3.3 View Container Logs

```bash
docker logs my-nginx
```

**Predict:** What type of information will appear in NGINX logs?

<details>
<summary>🔎 Click to verify</summary>

![docker logs my-nginx — full terminal output](images/docker-logs-output.png)

**Expected output (abbreviated):**

```text
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/06/25 08:47:19 [notice] 1#1: start worker processes
172.17.0.1 - - [25/Jun/2026:09:01:27 +0000] "GET / HTTP/1.1" 200 45 "-" "curl/7.81.0"
172.17.0.1 - - [25/Jun/2026:09:01:27 +0000] "GET /favicon.ico HTTP/1.1" 404 555 ...
```

The logs show three phases:
1. **Entrypoint configuration** — initialization scripts
2. **Worker process startup** — NGINX is ready to serve
3. **Access / error entries** — every HTTP request

> 💡 A `404` entry for `/favicon.ico` is **expected** — browsers request this file automatically, and the lab HTML does not provide one.
</details>

### 🧪 3.4 Experiment: Observing Live Log Updates

1. Run `docker logs my-nginx` and **note the current number of access log entries**
2. In another terminal tab, run `curl http://localhost:8080` **three times**
3. Run `docker logs my-nginx` again

**Observe:** Three new access log entries appear — one per `curl` request.

### 💭 3.5 Think First: Logs vs. Status

**Question:** In a production system, why would you monitor these logs rather than just checking that the container is `Up`?

<details>
<summary>🔎 Click to reveal the answer</summary>

Container **status** confirms the process is running. **Logs** reveal what the process is *actually doing*.

A container can be `Up` while:
- returning `500` errors on every request
- rejecting authentication
- logging repeated connection failures to a database

**Status checks confirm liveness; logs reveal behavior.**
</details>

### 🧾 Checkpoint 3

- [ ] `docker ps` shows `my-nginx` with status `Up`
- [ ] `docker logs my-nginx` displays startup and access entries
- [ ] You can identify the HTTP method, path, and status code in a log line
- [ ] You can explain the difference between container status and container health

---

# ♻️ Chapter 4 — Container Lifecycle Management

> Containers are **ephemeral by design**. A deployment workflow involves starting, stopping, restarting, and eventually removing containers as application versions change. These operations leave the underlying image intact.

### 🔄 4.1 The Container Lifecycle

```text
┌─────────────────┐  docker run   ┌─────────────────┐  docker stop  ┌─────────────────┐  docker rm  ┌─────────────┐
│ nginx:latest    │ ────────────▶ │    Running      │ ────────────▶ │    Stopped      │ ──────────▶ │  Removed    │
│ (image)         │               │ (status: Up)    │               │ (status: Exited)│             │  (gone)     │
└─────────────────┘               └─────────────────┘               └─────────────────┘             └─────────────┘
                                          ▲
                                          │
                                          └──────────── docker start ─────────────────────────────────┘
                                                                       (only works before rm)
```

| Note | Detail |
|---|---|
| ↩️ `docker start` | Brings a **Stopped** container back to **Running**. Does **not** work after `docker rm`. |
| 🛡️ Image safety | The `nginx:latest` image is **never** affected by `stop` or `rm` — it persists until you run `docker rmi`. |

### 💭 4.2 Think First: Stop vs. Remove

**Question:** After `docker stop my-nginx`, can you run `docker start my-nginx`? After `docker rm my-nginx`, can you run `docker start my-nginx`?

<details>
<summary>🔎 Click to reveal the answer</summary>

- `docker stop` → halts the container process but **preserves the container record**. `docker start` can restart it. ✅
- `docker rm` → **deletes the container record entirely**. `docker start` will fail because the named container no longer exists. ❌

The image (`nginx:latest`) is **not** affected by either operation.
</details>

### ⏹️ 4.3 Stop the Container

```bash
docker stop my-nginx
```

**Predict:** Will `my-nginx` appear in `docker ps` output?

<details>
<summary>🔎 Click to verify</summary>

**No.** `docker ps` shows only **running** containers. To see all containers (including stopped ones):

```bash
docker ps -a
```

**Expected output:**

```text
CONTAINER ID   IMAGE   COMMAND            CREATED         STATUS                     NAMES
8106ee13f2aa   nginx   "/docker-entry…"   10 minutes ago  Exited (0) 30 seconds ago  my-nginx
```
</details>

### ▶️ 4.4 Restart the Container

```bash
docker start my-nginx
```

```bash
curl http://localhost:8080
```

**Expected output:**

```html
<h1>Hello from NGINX running in Docker!</h1>
```

### 🗑️ 4.5 Remove the Container

```bash
docker stop my-nginx
docker rm my-nginx
```

Verify the image **remains** after container removal:

```bash
docker images
```

**Expected output — image still present:**

```text
REPOSITORY   TAG       IMAGE ID       CREATED       SIZE
nginx        latest    ec4ed8b5299e   2 weeks ago   241MB
```

### 🧾 Checkpoint 4

- [ ] `docker stop` halted the container; it no longer appears in `docker ps`
- [ ] `docker start` restarted it and the web page was accessible again
- [ ] `docker rm` removed the container but the image remains in `docker images`
- [ ] You can explain when `docker ps` vs `docker ps -a` is appropriate

---

# 🏁 Epilogue — The Complete System

The container runs in isolation, serves custom content from a mounted directory, and exposes a predictable port to the host.

### 📚 Command Reference

| Command | Purpose |
|---|---|
| `docker pull nginx` | Download image from Docker Hub |
| `docker images` | List available local images |
| `docker run --name my-nginx -v ... -p 8080:80 -d nginx` | Create and start container |
| `docker ps` | List running containers |
| `docker ps -a` | List all containers including stopped |
| `docker logs my-nginx` | View container output |
| `docker stop my-nginx` | Halt the container |
| `docker start my-nginx` | Restart a stopped container |
| `docker rm my-nginx` | Delete the container record |

### 🔁 End-to-End Verification

Run the full sequence in one go:

```bash
# 1. Pull image
docker pull nginx

# 2. Create content
mkdir -p nginx-lab/html
echo '<h1>Hello from NGINX running in Docker!</h1>' > nginx-lab/html/index.html

# 3. Run container
docker run --name my-nginx \
  -v $(pwd)/nginx-lab/html:/usr/share/nginx/html:ro \
  -p 8080:80 \
  -d nginx

# 4. Verify
docker ps
curl http://localhost:8080
docker logs my-nginx

# 5. Cleanup
docker stop my-nginx
docker rm my-nginx
```

---

# 💡 The Principles

| # | Principle | Takeaway |
|---|---|---|
| 1 | **Images are templates; containers are instances** | One image produces many containers. Deleting a container does not delete the image. |
| 2 | **Volume mounts separate content from infrastructure** | The HTML directory lives on the host. Updating a file there takes effect immediately, without rebuilding or restarting the container. |
| 3 | **Port mapping controls external access** | Without `-p`, a container is network-isolated. The mapping is explicit: host port → container port. |
| 4 | **Read-only mounts enforce discipline** | The `:ro` flag prevents the container process from modifying host files. Web servers have no business writing to their content directories. |
| 5 | **Logs reveal behavior; status confirms liveness** | A container can be `Up` and broken. Logs are the first tool for diagnosing service problems. |
| 6 | **Containers are ephemeral; images are durable** | Remove containers freely. Rebuild them from images. The image is the artifact worth preserving and versioning. |

---

## 🩹 Troubleshooting

### ❌ Error: `port is already allocated`

| Field | Detail |
|---|---|
| **Cause** | Another process is using the specified host port. |
| **Solution** | Choose a different host port, or free the port: |

```bash
lsof -ti:8080 | xargs kill -9
```

---

### ❌ Error: `Conflict. The container name "/my-nginx" is already in use`

| Field | Detail |
|---|---|
| **Cause** | A container named `my-nginx` already exists (possibly stopped). |
| **Solution** | Remove the existing container first: |

```bash
docker rm my-nginx
```

---

### ❌ Error: `curl: (7) Failed to connect to localhost port 8080: Connection refused`

| Field | Detail |
|---|---|
| **Cause** | The container is not running, or the port mapping does not match. |
| **Solution** | Inspect container state and port mapping: |

```bash
docker ps
docker inspect my-nginx | grep -A5 Mounts
```

---

## ➡️ Next Steps

1. 🌐 Serve a **multi-page HTML site** by adding additional files to `nginx-lab/html/` and navigating to them by path.
2. ⚙️ Write a **custom `nginx.conf`** and mount it into the container to configure custom routing rules.
3. 🔓 Replace the `:ro` mount with a **writable mount** and observe what permissions the NGINX process holds inside the container.
4. 🐳 Chain this lab with a **Dockerfile**: build a custom image that includes the HTML at build time rather than via a runtime mount.

---

## 📚 Additional Resources

- 📖 [Docker CLI Reference](https://docs.docker.com/reference/cli/docker/)
- 🐳 [Official NGINX Docker Image](https://hub.docker.com/_/nginx)
- 💾 [Docker Volume Documentation](https://docs.docker.com/storage/volumes/)

---

<div align="center">

**🎉 Congratulations — you have successfully deployed NGINX in Docker! 🎉**

Made with ❤️ using Puku CLI

</div>
