# NGINX-in-Docker Lab

This folder is the working directory for the **Running an NGINX Web Server in a Docker Container** tutorial.

The full tutorial lives one directory up in `../README.md`. Start there.

## Contents

| Path | Purpose |
|---|---|
| `html/index.html` | Custom HTML served by NGINX via a read-only volume mount. |
| `run.sh` | Helper script that wraps the tutorial's end-to-end verification sequence. |

## Quick Start

From this directory:

```bash
# Pull image, create content, run, verify, and clean up.
./run.sh

# Or start the container and leave it running.
./run.sh serve

# When finished, stop and remove the container.
./run.sh cleanup
```

The container listens on `localhost:8080`, forwarded to NGINX on port 80 inside the container. The local `html/` directory is mounted read-only into `/usr/share/nginx/html`.

## What You Learn

- Pulling and verifying a Docker image from Docker Hub.
- Mounting host content into a container with a read-only volume.
- Mapping a host port to a container port.
- Inspecting container state (`docker ps`, `docker logs`).
- Managing the container lifecycle (`stop`, `start`, `rm`).

For the complete walkthrough, troubleshooting, and next steps, see `../README.md`.
