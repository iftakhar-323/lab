# Running an NGINX Web Server in a Docker Container

**Prerequisites:** Familiarity with terminal commands and basic understanding of how web servers respond to HTTP requests.

## Introduction

This lab covers deploying an NGINX web server inside a Docker container using the Puku CLI integrated terminal. The lab proceeds by pulling an official image from Docker Hub, mounting a custom HTML directory into the container, managing the container lifecycle, and verifying a running web service without installing Docker locally.

**Architecture Overview**

The lab implements the following flow:

```
DockerHub --docker pull--> nginx image --docker run--> container --port mapping--> localhost
```

| Step | Action | Detail |
|---|---|---|
| 1 | Pull | `docker pull nginx` retrieves the image from DockerHub |
| 2 | Run | The image starts as a container |
| 3 | Mount | Host directory `nginx-lab/html` is bound to container path `/usr/share/nginx/html` |
| 4 | Verify | `docker ps` confirms the container is running |

A request to `curl http://localhost:<port>` is forwarded to container port 80, where NGINX reads the mounted `index.html` and returns it as the HTTP response.

## Learning Objectives

By the end of this lab, you will be able to:

1. Pull a Docker image from Docker Hub and verify it locally
2. Create and serve a custom HTML page from a running Docker container
3. Configure port mapping and volume mounts in a `docker run` command
4. Inspect container status, logs, and networking using Docker CLI commands
5. Stop, restart, and remove containers cleanly

## Prologue: The Challenge

You join a team that maintains a set of internal documentation portals. A colleague built one locally, and it works on their machine. When the service moves to a shared server, nothing works: missing dependencies, wrong versions, port conflicts.

The infrastructure lead assigns a task: containerize the web server so the environment is reproducible anywhere. The chosen approach is NGINX in Docker.

**Your deliverable:** a running NGINX container that serves a custom HTML page, mapped to a host port, with its content directory mounted from the project workspace.

## Environment Setup

Open Puku CLI and launch the integrated terminal.

Verify Docker is available:

```bash
docker --version
```

Expected output:

```
Docker version 24.x.x, build ...
```

Create the project directory structure:

```bash
mkdir -p nginx-lab/html
```

## Chapter 1: Images and the Docker Hub Registry

Docker does not require building every image from scratch. Docker Hub provides official, maintained images for common software. Before running a container, the corresponding image must be pulled.

### 1.1 What You Will Build

This chapter pulls the official NGINX image and verifies it is available on the local machine.

### 1.2 Think First: Images vs. Containers

Consider the following two statements:

"The NGINX image is running." vs. "The NGINX container is running."

**Question:** Which statement is technically accurate, and what is the difference between an image and a container?

<details>
<summary>Click to review</summary>

Only a container can run. An image is a read-only template: a snapshot of a filesystem and configuration. A container is a running instance created from that image. One image can produce many containers simultaneously, each isolated from the others.

The accurate statement is: "The NGINX container is running."

</details>

### 1.3 Pull the NGINX Image

Run the following command to download the latest official NGINX image from Docker Hub:

```bash
docker pull nginx
```

Docker downloads each layer of the image in parallel and confirms each layer as it completes.

Expected output:

```
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

### 1.4 Verify the Download

Confirm the image is available locally:

```bash
docker images
```

**Predict:** What columns will this command display?

<details>
<summary>Click to verify</summary>

The columns are `REPOSITORY`, `TAG`, `IMAGE ID`, `CREATED`, and `SIZE`. The `nginx` image with tag `latest` appears in the list, alongside any other images already present on the machine.

Sample output:

```
IMAGE                              ID             DISK USAGE   CONTENT SIZE
nginx:latest                       ec4ed8b5299e   241MB        66MB
```

</details>

**Self-Assessment:**

- [ ] `docker pull nginx` completed without errors
- [ ] `docker images` lists `nginx` with the `latest` tag
- [ ] You can explain the difference between an image and a container

## Chapter 2: Serving Content with Volume Mounts

An NGINX container started without configuration serves only its default welcome page. To serve custom content, a local directory is mounted into the container's web root. Any HTML file placed in that directory becomes immediately available through the running server.

### 2.1 What You Will Build

This chapter creates a custom HTML file, runs the NGINX container with a volume mount and port mapping, and verifies the server returns the custom content.

### 2.2 The Volume Mount and Port Mapping Flow

```
Host Machine                                    my-nginx Container
nginx-lab/html/index.html  --v mount :ro-->     /usr/share/nginx/html (read-only)
localhost:<port>           --p <port>:80-->     NGINX port 80 (internal listener)
```

### 2.3 Think First: Port Mapping

The NGINX server inside the container listens on port 80. The host machine cannot directly access port 80 inside the container.

**Question:** What does the `-p <host_port>:80` flag accomplish, and which number refers to the host?

<details>
<summary>Click to review</summary>

The `-p` flag maps a host port to a container port. The format is `host_port:container_port`.

For example, `-p 50000:80` means requests arriving at port 50000 on the host machine are forwarded to port 80 inside the container. The first number is the host port.

Without this mapping, the container's network is isolated and unreachable from outside.

</details>

### 2.4 Create the HTML Page

```bash
echo '<h1>Hello from NGINX running in Docker!</h1>' > nginx-lab/html/index.html
```

```bash
cat nginx-lab/html/index.html
```

Expected output:

```
<h1>Hello from NGINX running in Docker!</h1>
```

### 2.5 Run the NGINX Container

Complete the following `docker run` command:

```
docker run --name my-nginx \
  -v $(pwd)/nginx-lab/html:/usr/share/nginx/html:___ \   # Q1: What mode prevents the container from writing?
  -p ___:80 \                                             # Q2: Which host port to expose?
  -_ nginx                                                # Q3: Which flag runs detached?
```

Hints:

- Q1: two-letter abbreviation for "read-only"
- Q2: any free host port is valid; this lab uses 50000
- Q3: single-letter flag

<details>
<summary>Click to see solution</summary>

```bash
docker run --name my-nginx \
  -v $(pwd)/nginx-lab/html:/usr/share/nginx/html:ro \
  -p 50000:80 \
  -d nginx
```

| Flag | Purpose |
|---|---|
| `--name my-nginx` | Assigns a name to the container |
| `-v .../html:/usr/share/nginx/html:ro` | Mounts the local directory into the container web root, read-only |
| `-p 50000:80` | Maps host port 50000 to container port 80 |
| `-d` | Runs the container in detached (background) mode |

On Windows PowerShell, replace `$(pwd)` with `${PWD}`.

</details>

Expected output (container ID):

```
8106ee13f2aab334720b134d3b913e9b0a42f1712b13d8fcbeba0b3150a0066bb
```

### 2.6 Test and Verify

**Predict:** What will a request to the mapped port return?

```bash
curl http://localhost:50000
```

<details>
<summary>Click to verify</summary>

```
<h1>Hello from NGINX running in Docker!</h1>
```

The request reaches port 50000 on the host. The host forwards it to port 80 inside the container. NGINX reads `index.html` from the mounted volume and returns its contents. The same result appears when visiting `localhost:50000` in a browser.

</details>

**Self-Assessment:**

- [ ] Container started without errors and returned a container ID
- [ ] Requests to the mapped host port return the custom HTML
- [ ] You can explain what `:ro` prevents and why it matters for web serving
- [ ] You can predict what happens if the `-p` flag is omitted

## Chapter 3: Inspecting a Running Container

A container running in detached mode produces no output in the terminal. Docker provides commands to inspect its state, examine its logs, and confirm network configuration without interrupting the service.

### 3.2 Think First: Reading Container Status

**Question:** A teammate reports a container status of `Up 2 minutes (unhealthy)`. What does this indicate, and how does it differ from `Up 2 minutes`?

<details>
<summary>Click to review</summary>

`Up 2 minutes` indicates the container process is running.

`Up 2 minutes (unhealthy)` indicates the container process is running, but a configured health check is failing. The process has not crashed, but the service inside it is not passing its own readiness tests. This distinction matters in production: a load balancer should route traffic only to healthy containers.

</details>

### 3.3 Check Running Containers

```bash
docker ps
```

Expected output:

```
CONTAINER ID   IMAGE   COMMAND                  CREATED         STATUS        PORTS                   NAMES
8106ee13f2aa   nginx   "/docker-entrypoint…"   3 minutes ago   Up 3 minutes  0.0.0.0:50000->80/tcp   my-nginx
```

Verify in the output: `NAMES` shows `my-nginx`, `STATUS` shows `Up`, and `PORTS` shows `0.0.0.0:50000->80/tcp`.

### 3.4 View Container Logs

```bash
docker logs my-nginx
```

**Predict:** What type of information will appear in NGINX logs?

<details>
<summary>Click to verify</summary>

Expected output (abbreviated):

```
/docker-entrypoint.sh: /docker-entrypoint.d/ is not empty, will attempt to perform configuration
/docker-entrypoint.sh: Looking for shell scripts in /docker-entrypoint.d/
/docker-entrypoint.sh: Launching /docker-entrypoint.d/10-listen-on-ipv6-by-default.sh
10-listen-on-ipv6-by-default.sh: info: Getting the checksum of /etc/nginx/conf.d/default.conf
10-listen-on-ipv6-by-default.sh: info: Enabled listen on IPv6 in /etc/nginx/conf.d/default.conf
/docker-entrypoint.sh: Sourcing /docker-entrypoint.d/15-local-resolvers.envsh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/20-envsubst-on-templates.sh
/docker-entrypoint.sh: Launching /docker-entrypoint.d/30-tune-worker-processes.sh
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/06/25 08:47:19 [notice] 1#1: using the "epoll" event method
2026/06/25 08:47:19 [notice] 1#1: nginx/1.31.2
2026/06/25 08:47:19 [notice] 1#1: built by gcc 14.2.0 (Debian 14.2.0-19)
2026/06/25 08:47:19 [notice] 1#1: OS: Linux 6.17.0-35-generic
2026/06/25 08:47:19 [notice] 1#1: getrlimit(RLIMIT_NOFILE): 1024:524288
2026/06/25 08:47:19 [notice] 1#1: start worker processes
172.17.0.1 - - [25/Jun/2026:09:01:27 +0000] "GET / HTTP/1.1" 200 45 "-" "Mozilla/5.0 ..."
2026/06/25 09:01:27 [error] 30#30: *1 open() "/usr/share/nginx/html/favicon.ico" failed (2: No such file or directory)
172.17.0.1 - - [25/Jun/2026:09:01:27 +0000] "GET /favicon.ico HTTP/1.1" 404 555 "http://localhost:50000/" "Mozilla/5.0 ..."
```

The logs show three phases: entrypoint configuration, worker process startup, and access or error log entries. A 404 entry for `/favicon.ico` is expected; browsers request this file automatically, and the lab HTML does not provide one.

</details>

### 3.5 Experiment: Observing Live Log Updates

1. Run `docker logs my-nginx` and note the current number of access log entries
2. In another terminal tab, run `curl http://localhost:50000` three times
3. Run `docker logs my-nginx` again

**Observe:** Three new access log entries appear, one per `curl` request.

**Question:** In a production system, why would you monitor these logs rather than only checking that the container is `Up`?

<details>
<summary>Click to review</summary>

Container status confirms the process is running. Logs reveal what the process is actually doing. A container can be `Up` while returning 500 errors on every request, rejecting authentication, or logging repeated connection failures to a database. Status checks confirm liveness; logs reveal behavior.

</details>

**Self-Assessment:**

- [ ] `docker ps` shows `my-nginx` with status `Up`
- [ ] `docker logs my-nginx` displays startup and access entries
- [ ] You can identify the HTTP method, path, and status code in a log line
- [ ] You can explain the difference between container status and container health

## Chapter 4: Container Lifecycle Management

Containers are ephemeral by design. A deployment workflow involves starting, stopping, restarting, and eventually removing containers as application versions change. These operations leave the underlying image intact.

### 4.1 The Container Lifecycle

```
nginx:latest (image) --docker run--> Running (status: Up) --docker stop--> Stopped (status: Exited) --docker rm--> Removed
```

`docker start` brings a Stopped container back to Running. It does not work after `docker rm`.

The `nginx:latest` image is not affected by `stop` or `rm`. It persists until `docker rmi` is run.

### 4.2 Think First: Stop vs. Remove

**Question:** After `docker stop my-nginx`, can you run `docker start my-nginx`? After `docker rm my-nginx`, can you run `docker start my-nginx`?

<details>
<summary>Click to review</summary>

`docker stop` halts the container process but preserves the container record. `docker start` can restart it.

`docker rm` deletes the container record entirely. `docker start` fails because the named container no longer exists. The image (`nginx:latest`) is not affected by either operation.

</details>

### 4.3 Stop the Container

```bash
docker stop my-nginx
```

**Predict:** Will `my-nginx` appear in `docker ps` output?

<details>
<summary>Click to verify</summary>

No. `docker ps` shows only running containers. To see all containers including stopped ones:

```bash
docker ps -a
```

Expected output:

```
CONTAINER ID   IMAGE   COMMAND            CREATED         STATUS                     NAMES
8106ee13f2aa   nginx   "/docker-entry…"   10 minutes ago  Exited (0) 30 seconds ago  my-nginx
```

</details>

### 4.4 Restart the Container

```bash
docker start my-nginx
curl http://localhost:50000
```

Expected output:

```
<h1>Hello from NGINX running in Docker!</h1>
```

### 4.5 Remove the Container

```bash
docker stop my-nginx
docker rm my-nginx
```

Verify the image remains after container removal:

```bash
docker images
```

Expected output (image still present):

```
REPOSITORY   TAG       IMAGE ID       CREATED       SIZE
nginx        latest    ec4ed8b5299e   2 weeks ago   241MB
```

**Self-Assessment:**

- [ ] `docker stop` halted the container; it no longer appears in `docker ps`
- [ ] `docker start` restarted it, and the web page was accessible again
- [ ] `docker rm` removed the container but the image remains in `docker images`
- [ ] You can explain when `docker ps` vs. `docker ps -a` is appropriate

## Epilogue: The Complete System

The container runs in isolation, serves custom content from a mounted directory, and exposes a predictable port to the host.

| Command | Purpose |
|---|---|
| `docker pull nginx` | Download image from Docker Hub |
| `docker images` | List available local images |
| `docker run --name my-nginx -v ... -p 50000:80 -d nginx` | Create and start container |
| `docker ps` | List running containers |
| `docker ps -a` | List all containers, including stopped |
| `docker logs my-nginx` | View container output |
| `docker stop my-nginx` | Halt the container |
| `docker start my-nginx` | Restart a stopped container |
| `docker rm my-nginx` | Delete the container record |

Verify the full sequence end to end:

```bash
# Pull image
docker pull nginx

# Create content
mkdir -p nginx-lab/html
echo '<h1>Hello from NGINX running in Docker!</h1>' > nginx-lab/html/index.html

# Run container
docker run --name my-nginx \
  -v $(pwd)/nginx-lab/html:/usr/share/nginx/html:ro \
  -p 50000:80 \
  -d nginx

# Verify
docker ps
curl http://localhost:50000
docker logs my-nginx

# Cleanup
docker stop my-nginx
docker rm my-nginx
```

## The Principles

1. **Images are templates; containers are instances.** One image produces many containers. Deleting a container does not delete the image.
2. **Volume mounts separate content from infrastructure.** The HTML directory lives on the host. Updating a file there takes effect immediately, without rebuilding or restarting the container.
3. **Port mapping controls external access.** Without `-p`, a container is network-isolated. The mapping is explicit: host port to container port, with no ambiguity.
4. **Read-only mounts enforce discipline.** The `:ro` flag prevents the container process from modifying host files. Web servers have no requirement to write to their content directories.
5. **Logs reveal behavior; status confirms liveness.** A container can be `Up` and broken. Logs are the first tool for diagnosing service problems.
6. **Containers are ephemeral; images are durable.** Remove containers freely and rebuild them from images. The image is the artifact worth preserving and versioning.

## Troubleshooting

### Error: port is already allocated

**Cause:** Another process is using the specified host port.

**Solution:** Choose a different host port, or free the port:

```bash
lsof -ti:50000 | xargs kill -9
```

### Error: Conflict. The container name "/my-nginx" is already in use

**Cause:** A container named `my-nginx` already exists, possibly stopped.

**Solution:**

```bash
docker rm my-nginx
```

### Error: curl: (7) Failed to connect to localhost port 50000: Connection refused

**Cause:** The container is not running, or the port mapping does not match.

**Solution:** Check container state and port mapping:

```bash
docker ps
docker inspect my-nginx | grep -A5 Mounts
```

## Next Steps

1. Serve a multi-page HTML site by adding additional files to `nginx-lab/html/` and navigating to them by path.
2. Write a custom `nginx.conf` and mount it into the container to configure custom routing rules.
3. Replace the `:ro` mount with a writable mount and observe what permissions the NGINX process holds inside the container.
4. Chain this lab with a Dockerfile: build a custom image that includes the HTML at build time rather than through a runtime mount.

## Additional Resources

- [Docker CLI Reference](https://docs.docker.com/reference/cli/docker/)
- [Official NGINX Docker Image](https://hub.docker.com/_/nginx)
- [Docker Volume Documentation](https://docs.docker.com/storage/volumes/)
