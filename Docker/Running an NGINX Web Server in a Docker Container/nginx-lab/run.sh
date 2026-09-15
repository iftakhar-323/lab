#!/usr/bin/env bash
#
# End-to-end verification script for the NGINX-in-Docker lab.
# Mirrors the sequence in the tutorial's "End-to-End Verification" section.
#
# Usage:
#   ./run.sh           # full pull + run + verify + cleanup
#   ./run.sh serve     # only start (or restart) the container, no cleanup
#   ./run.sh cleanup   # only stop and remove the container
#
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HTML_DIR="${LAB_DIR}/html"
CONTAINER_NAME="my-nginx"
HOST_PORT=8080
CONTAINER_PORT=80
IMAGE="nginx:latest"

log() { printf '\n=== %s ===\n' "$*"; }

cmd_pull() {
  log "Pulling image"
  docker pull "${IMAGE}"
}

cmd_content() {
  log "Ensuring HTML content exists"
  mkdir -p "${HTML_DIR}"
  if [[ ! -s "${HTML_DIR}/index.html" ]]; then
    echo '<h1>Hello from NGINX running in Docker!</h1>' > "${HTML_DIR}/index.html"
  fi
  cat "${HTML_DIR}/index.html"
}

cmd_run() {
  log "Starting container ${CONTAINER_NAME}"
  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    docker rm -f "${CONTAINER_NAME}" >/dev/null
  fi
  docker run --name "${CONTAINER_NAME}" \
    -v "${HTML_DIR}:/usr/share/nginx/html:ro" \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    -d "${IMAGE}"
}

cmd_verify() {
  log "docker ps"
  docker ps
  log "curl http://localhost:${HOST_PORT}"
  curl -sS "http://localhost:${HOST_PORT}"
  log "docker logs ${CONTAINER_NAME} (tail)"
  docker logs "${CONTAINER_NAME}" || true
}

cmd_cleanup() {
  log "Stopping and removing container"
  if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"; then
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    docker rm "${CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi
}

case "${1:-all}" in
  all)
    cmd_pull
    cmd_content
    cmd_run
    cmd_verify
    cmd_cleanup
    ;;
  serve)
    cmd_content
    cmd_run
    cmd_verify
    ;;
  cleanup)
    cmd_cleanup
    ;;
  *)
    echo "Usage: $0 [all|serve|cleanup]" >&2
    exit 1
    ;;
esac
