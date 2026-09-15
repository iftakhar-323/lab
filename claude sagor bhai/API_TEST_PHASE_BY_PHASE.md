# Poridhi API Testing Guide: Phase by Phase & Issue Tracker

> **Source Services:** `cloud-engine` & `proxy-engine`  
> **Directive:** API Black-Box & Contract Testing ➔ Minimal Load (8-10 Concurrency) ➔ Crash Hunting ➔ GitHub Issue Reporting with PoC & Fixes  
> **Environment:** Local / Staging Sandbox (Zero Auth: `security: []`)  

---

## 📋 Table of Contents
1. [Testing Roadmap (সাগর ভাইয়ের নির্দেশনা অনুযায়ী ৪টি ফেজ)](#1-testing-roadmap)
2. [Phase 1: Individual Endpoint & Contract Testing (সব এন্ডপয়েন্ট ভ্যালিডেশন)](#2-phase-1-individual-endpoint--contract-testing)
   - [1.1 Health & Liveness](#11-health--liveness)
   - [1.2 cloud-engine: Accounts & VPCs](#12-cloud-engine-accounts--vpcs)
   - [1.3 cloud-engine: Virtual Machines (VMs)](#13-cloud-engine-virtual-machines-vms)
   - [1.4 cloud-engine: Images & Guest Compatibility](#14-cloud-engine-images--guest-compatibility)
   - [1.5 cloud-engine: Snapshots & Operations](#15-cloud-engine-snapshots--operations)
   - [1.6 proxy-engine: Customers & K8s Namespaces](#16-proxy-engine-customers--k8s-namespaces)
   - [1.7 proxy-engine: Service Exposes & Ingress](#17-proxy-engine-service-exposes--ingress)
   - [1.8 proxy-engine: Load Balancers (L4 / L7)](#18-proxy-engine-load-balancers-l4--l7)
   - [1.9 proxy-engine: Proxy Nodes, VIP Pool & BGP](#19-proxy-engine-proxy-nodes-vip-pool--bgp)
3. [Phase 2: Minimal Load & Concurrency Testing (৮-১০টি কনকারেন্ট রিকোয়েস্ট)](#3-phase-2-minimal-load--concurrency-testing)
   - [2.1 Concurrent Proxy-IP Allocations (10 Requests)](#21-concurrent-proxy-ip-allocations-10-requests)
   - [2.2 Concurrent Burst VM Launches (8 Requests)](#22-concurrent-burst-vm-launches-8-requests)
   - [2.3 Race Condition on VM State (Simultaneous Restarts)](#23-race-condition-on-vm-state-simultaneous-restarts)
   - [2.4 Subdomain Collisions under Concurrent Expose](#24-subdomain-collisions-under-concurrent-expose)
4. [Phase 3: Live Crash Detection & Log Monitoring (ক্র্যাশ ধরার নিয়ম)](#4-phase-3-live-crash-detection--log-monitoring)
5. [Phase 4: Found Issues, Bugs & PoC Tracker (লাইভ বাগ ট্র্যাকার)](#5-phase-4-found-issues-bugs--poc-tracker)
   - [Known & Discovered Issue Log](#known--discovered-issue-log)
   - [GitHub Issue Submission Template (PoC + Suggested Fix)](#github-issue-submission-template)
6. [Ready-to-Run Automation Script (`api_test_suite.sh`)](#6-ready-to-run-automation-script)

---

## 1. Testing Roadmap

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           PHASE-BY-PHASE TEST PIPELINE                      │
├─────────────────────────────────────────────────────────────────────────────┤
│  Phase 1: Endpoint & Contract Testing                                       │
│  • Hit every single endpoint (happy & negative paths).                      │
│  • Verify expected HTTP status codes, uniform error body {"error": "..."}.  │
│  • Identify response shape quirks and parameter validations.                │
├─────────────────────────────────────────────────────────────────────────────┤
│  Phase 2: Minimal Load & Concurrency Testing (8-10 Requests)                │
│  • Fire 8 to 10 concurrent requests to probe race conditions.               │
│  • Test IPAM CAS transactions, VM boot semaphores, and socket locks.        │
├─────────────────────────────────────────────────────────────────────────────┤
│  Phase 3: Crash Hunting & Live Log Tailing                                  │
│  • Tail docker logs & systemd journalctl during test runs.                  │
│  • Watch for Go runtime panics, concurrent map writes, deadlocks, and 500s. │
├─────────────────────────────────────────────────────────────────────────────┤
│  Phase 4: Issue Documentation with PoC & Suggested Fixes                    │
│  • Log every bug in the Issue Tracker table below.                          │
│  • Submit GitHub issues with exact reproduction curls and suggested PR fix. │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Phase 1: Individual Endpoint & Contract Testing

### 1.1 Health & Liveness
- **Endpoint:** `GET /healthz` (both services)
- **Execution:**
  ```bash
  curl -s -i http://localhost:8080/healthz
  ```
- **Expected:** `HTTP 200 OK`, body: `{"status":"ok"}`.
- **Contract Rule:** All error responses across both APIs must strictly match: `{"error": "<string>"}` with no numeric `code` or `type` fields.

---

### 1.2 `cloud-engine`: Accounts & VPCs

#### Test CE-ACC-01: Valid Account Creation
```bash
curl -s -i -X POST http://localhost:8080/accounts \
  -H "Content-Type: application/json" \
  -d '{"name":"qa-org","email":"qa@poridhi.io"}'
```
- **Expected:** `HTTP 201 Created`.
- **Contract Check:** Response key must be **`account_id`** (not `id`). A default `vpc_id` must be present.

#### Test CE-ACC-02: Missing Required Fields
```bash
curl -s -i -X POST http://localhost:8080/accounts \
  -H "Content-Type: application/json" \
  -d '{"email":"only-email@poridhi.io"}'
```
- **Expected:** `HTTP 400 Bad Request`, body: `{"error":"..."}`.

#### Test CE-ACC-03: Account Listing Key Divergence (Documented Quirk)
```bash
curl -s http://localhost:8080/accounts/list | jq .
```
- **Expected:** `HTTP 200 OK`, JSON array.
- **Contract Check:** Each item in the array must use key **`id`** (not `account_id`).

#### Test CE-ACC-04: Delete Non-Existent Account
```bash
curl -s -i -X DELETE http://localhost:8080/accounts/fake-acc-999
```
- **Expected:** `HTTP 404 Not Found`.

---

### 1.3 `cloud-engine`: Virtual Machines (VMs)

#### Test CE-VM-01: Valid VM Launch
```bash
curl -s -i -X POST http://localhost:8080/vms \
  -H "Content-Type: application/json" \
  -d '{
    "name": "test-vm-01",
    "account_id": "<account_id>",
    "vpc_id": "<vpc_id>",
    "image_id": "<image_id>",
    "vcpu": 1,
    "memory_mb": 256
  }'
```
- **Expected:** `HTTP 202 Accepted` (Temporal) or `201 Created` (Legacy).
- **Polling:** Poll `GET /vms/{id}` until `state: "running"`.

#### Test CE-VM-02: Memory Floor Limit (< 128MB)
```bash
curl -s -i -X POST http://localhost:8080/vms \
  -H "Content-Type: application/json" \
  -d '{"name":"low-mem","account_id":"<acc_id>","vpc_id":"<vpc_id>","image_id":"<img_id>","vcpu":1,"memory_mb":64}'
```
- **Expected:** `HTTP 400 Bad Request` (Memory floor is 128MB).

#### Test CE-VM-03: Backend Engine Validation (400 vs 501)
- **Unrecognized Engine:**
  ```bash
  curl -s -i -X POST http://localhost:8080/vms -H "Content-Type: application/json" \
    -d '{"backend_engine":"unknown-engine", ...}'
  ```
  *Expected:* `HTTP 400 Bad Request`.
- **Unsupported Known Engine (`cloud-hypervisor`):**
  ```bash
  curl -s -i -X POST http://localhost:8080/vms -H "Content-Type: application/json" \
    -d '{"backend_engine":"cloud-hypervisor", ...}'
  ```
  *Expected:* `HTTP 501 Not Implemented` (Assert code is 501, not 400).

#### Test CE-VM-04: SSH Info Retrieval
```bash
curl -s -i http://localhost:8080/vms/<vm_id>/ssh
```
- **Expected:**
  - If orchestrator is running: `HTTP 200 OK` with `ssh_command` and `proxy_ssh_command`.
  - If orchestrator is down: `HTTP 503 Service Unavailable`.

---

### 1.4 `cloud-engine`: Images & Guest Compatibility

#### Test CE-IMG-01: Valid Image Build
```bash
curl -s -i -X POST http://localhost:8080/images \
  -H "Content-Type: application/json" \
  -d '{"docker_image":"alpine:latest"}'
```
- **Expected:** `HTTP 202 Accepted`. Poll `GET /images/{id}` until `status: "ready"`.

#### Test CE-IMG-02: Pnet Version Pinning (Known Guest Panic Defect)
- **Bug Check (`pnet_version: "latest"`):**
  ```bash
  curl -s -X POST http://localhost:8080/images -H "Content-Type: application/json" \
    -d '{"docker_image":"alpine:latest","pnet_version":"latest"}'
  ```
  *Note:* Spec documents that pnet 1.0.3 panics on Firecracker guests. Verify if `pnet_peer_id` ends up empty on VM boot.
- **Safe Pinning (`pnet_version: "1.0.2"`):**
  ```bash
  curl -s -X POST http://localhost:8080/images -H "Content-Type: application/json" \
    -d '{"docker_image":"alpine:latest","pnet_version":"1.0.2"}'
  ```
  *Expected:* Boots cleanly without panic.

---

### 1.5 `cloud-engine`: Snapshots & Operations

#### Test CE-SNAP-01: Snapshots Without Temporal Flow
```bash
curl -s -i -X POST http://localhost:8080/snapshots -H "Content-Type: application/json" \
  -d '{"vm_id":"<vm_id>"}'
```
- **Expected:** `HTTP 501 Not Implemented` when `temporal.flows.snapshot: false`. (No legacy fallback exists).

#### Test CE-OPS-01: Operation ID Slash Routing (Unencoded vs Encoded)
- **Unencoded slash:** `GET /operations/image/img-123/build` ➔ Expected: `200` or `404 (if not found)`.
- **Percent-encoded slash:** `GET /operations/image%2Fimg-123%2Fbuild` ➔ Expected: `404 Not Found` (Router does not decode `%2F`).

---

### 1.6 `proxy-engine`: Customers & K8s Namespaces

#### Test PE-CUST-01: Valid Customer Creation
```bash
curl -s -i -X POST http://localhost:8080/customers \
  -H "Content-Type: application/json" \
  -d '{"account_id":"<valid_cloud_engine_acc_id>","tier":"standard"}'
```
- **Expected:** `HTTP 201 Created`. Customer status shows `ns_ready: true` once K8s namespace `px-<id>` is ready.

#### Test PE-CUST-02: Unknown Account ID
```bash
curl -s -i -X POST http://localhost:8080/customers \
  -H "Content-Type: application/json" \
  -d '{"account_id":"nonexistent-acc-id","tier":"standard"}'
```
- **Expected:** `HTTP 400 Bad Request` (`unknown cloud-engine account: ...`).

---

### 1.7 `proxy-engine`: Service Exposes & Ingress

#### Test PE-EXP-01: Valid Expose
```bash
curl -s -i -X POST http://localhost:8080/expose \
  -H "Content-Type: application/json" \
  -d '{
    "customer_id": "<cust_id>",
    "vm_ids": ["<running_vm_id>"],
    "port": 3000,
    "subdomain": "mywebapp",
    "mode": "single"
  }'
```
- **Expected:** `HTTP 201 Created` with `url: "https://mywebapp.expose.poridhi.io"`.

#### Test PE-EXP-02: Fail-Closed on Proxy-IP Exhaustion
- **Scenario:** Expose a VM where proxy-IP allocation fails.
- **Expected:** `HTTP 502 Bad Gateway`. Must **never** fallback to VM's private `10.x.x.x` address.

#### Test PE-EXP-03: Response Shape Contract
```bash
curl -s http://localhost:8080/expose/<expose_id> | jq .
```
- **Contract Check:** Top-level fields must be **flat** (`.subdomain`, `.agent_ips`), not nested.

#### Test PE-EXP-04: Non-Existent ID Bug (Known Bug Verification)
```bash
curl -s -i -X PATCH http://localhost:8080/expose/fake-expose-id-999/weights \
  -H "Content-Type: application/json" \
  -d '{"weights":{"vm-1":100}}'
```
- **Actual Behavior (Known Bug):** Returns `HTTP 200 OK`!
- **Verification:** Confirm database has no record; log as Issue.

---

### 1.8 `proxy-engine`: Load Balancers (L4 / L7)

#### Test PE-LB-01: L4 TCP & L7 HTTP Defaults
- L4 with `protocol: TCP` ➔ default policy must be `maglev`.
- L7 with `protocol: HTTP` ➔ default policy must be `round_robin`.

#### Test PE-LB-02: Reserved Port 80/443 Rejection (Incident 2026-08-14 Lock)
```bash
curl -s -i -X POST http://localhost:8080/loadbalancers \
  -H "Content-Type: application/json" \
  -d '{"type":"l4","protocol":"TCP","port":80, ...}'
```
- **Expected:** `HTTP 400 Bad Request` (`reservedLBPortErr`). Port 80 and 443 must never be allowed for L4 LBs.

#### Test PE-LB-03: Response Shape Contract
```bash
curl -s http://localhost:8080/loadbalancers/<lb_id> | jq .
```
- **Contract Check:** Record must be **nested under `.lb`** (unlike expose).

#### Test PE-LB-04: Delete Non-Existent Backend Bug (Known Bug Verification)
```bash
curl -s -i -X DELETE http://localhost:8080/loadbalancers/<lb_id>/backends/nonexistent-backend-id
```
- **Actual Behavior (Known Bug):** Returns `HTTP 200 OK` (No existence check performed).

#### Test PE-LB-05: Health Divergence Verification
- Crash guest app while VM lives:
  - `backends[].health_status` = `healthy` (VM running).
  - `endpoint_health` = `unhealthy` (App down).
- **Rule:** Monitoring systems must always treat `endpoint_health` as ground truth.

---

### 1.9 `proxy-engine`: Proxy Nodes, VIP Pool & BGP

#### Test PE-BGP-01: Missing Query Param
```bash
curl -s -i http://localhost:8080/bgp/peers
```
- **Expected:** `HTTP 400 Bad Request` (`agent_ip query param required`).

#### Test PE-NODE-01: Malformed Heartbeat
```bash
curl -s -i -X POST http://localhost:8080/proxy-nodes/node-1/heartbeat \
  -H "Content-Type: application/json" -d '{}'
```
- **Expected:** Ignored, but returns `HTTP 200 {"ack": true}`.

---

## 3. Phase 2: Minimal Load & Concurrency Testing (8-10 Concurrent Requests)

> **Why this phase is critical:**  
> সাগর ভাইয়ের স্পষ্ট বার্তা: *"8/10 ta concurrent request... system crash korbe kothao nah kothao."*  
> একক রিকোয়েস্টে যেসব কোড কাজ করে, কনকারেন্ট ৮-১০টি রিকোয়েস্টেই ডেডলক, রেস কন্ডিশন এবং মেমোরি প্যানিক ধরা পড়ে।

### 2.1 Concurrent Proxy-IP Allocations (10 Requests)
- **Target:** `POST /proxy-ips`
- **Purpose:** Test IPAM CAS transaction safety and prevent CGNAT /32 address leakage.
```bash
echo "Firing 10 concurrent requests to /proxy-ips..."
for i in {1..10}; do
  curl -s -w "Resp: %{http_code}\n" -X POST http://localhost:8080/proxy-ips \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"cust-stress-1","vm_id":"vm-fixed-1","kind":"expose"}' &
done
wait
echo "Completed."
```
- **Pass Criteria:**
  - All 10 requests must return the **exact same `proxy_ip`** and identical 9 keys.
  - Zero 500 errors. No duplicate allocations in etcd.

---

### 2.2 Concurrent Burst VM Launches (8 Requests)
- **Target:** `POST /vms`
- **Purpose:** Probe disk I/O storms and verify node agent semaphore (`max_concurrent_starts: 20`).
```bash
echo "Launching 8 VMs concurrently..."
for i in {1..8}; do
  curl -s -w "VM $i Status: %{http_code}\n" -X POST http://localhost:8080/vms \
    -H "Content-Type: application/json" \
    -d "{
      \"name\": \"burst-vm-$i\",
      \"account_id\": \"$ACC_ID\",
      \"vpc_id\": \"$VPC_ID\",
      \"image_id\": \"$IMAGE_ID\",
      \"vcpu\": 1,
      \"memory_mb\": 256
    }" &
done
wait
echo "All 8 requests dispatched."
```
- **Pass Criteria:**
  - Node agent must not panic or run OOM.
  - All 8 VMs receive distinct private IPs without collisions.

---

### 2.3 Race Condition on VM State (Simultaneous Restarts)
- **Target:** `POST /vms/{id}/restart`
- **Purpose:** Probe socket file race conditions.
```bash
echo "Simultaneous restart attack on VM: $VM_ID"
curl -s -w "Call 1: %{http_code}\n" -X POST http://localhost:8080/vms/$VM_ID/restart &
curl -s -w "Call 2: %{http_code}\n" -X POST http://localhost:8080/vms/$VM_ID/restart &
wait
```
- **Pass Criteria:**
  - One call returns `202 Accepted`, the other returns `409 Conflict`.
  - Must **never** return `500 Internal Server Error` or deadlock the Firecracker socket.

---

### 2.4 Subdomain Collisions under Concurrent Expose
- **Target:** `POST /expose`
- **Purpose:** Two customers requesting the exact same subdomain at the same millisecond.
```bash
curl -s -w "Tenant 1: %{http_code}\n" -X POST http://localhost:8080/expose \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"c1","vm_ids":["vm1"],"port":8080,"subdomain":"conflict-app"}' &

curl -s -w "Tenant 2: %{http_code}\n" -X POST http://localhost:8080/expose \
  -H "Content-Type: application/json" \
  -d '{"customer_id":"c2","vm_ids":["vm2"],"port":8080,"subdomain":"conflict-app"}' &
wait
```
- **Pass Criteria:** Exactly one gets `201 Created`, the other receives `409 Conflict`. Zero duplicate records in PostgreSQL.

---

## 4. Phase 3: Live Crash Detection & Log Monitoring

টেস্ট রান করার সময় অন্য টার্মিনালে নিচের কমান্ডগুলো চালিয়ে রিয়েল-টাইম লগ মনিটর করুন:

```bash
# ১. cloud-engine এর কন্ট্রোল প্লেন লগ মনিটর:
docker compose logs -f --tail=100 api orchestrator worker

# ২. baremetal node এজেন্টের লাইভ লগ:
sudo journalctl -u poridhi-agent -f

# ৩. proxy-engine কন্টেইনার ও Envoy লগ:
kubectl logs -n proxy-system deploy/proxy-engine -f
```

### লগে যা দেখলে সাথে সাথে বাগ হিসেবে চিহ্নিত করবেন:
- ❌ `panic: runtime error: invalid memory address or nil pointer dereference`
- ❌ `fatal error: concurrent map writes`
- ❌ `pq: deadlock detected`
- ❌ `transport: authentication handshake failed`
- ❌ `signal: killed` (Out Of Memory OOM-Killer)

---

## 5. Phase 4: Found Issues, Bugs & PoC Tracker

এই টেবিলে টেস্ট চলাকালীন পাওয়া সমস্ত বাগ লিপিবদ্ধ করে GitHub-এ PoC সহ সাবমিট করুন:

### Known & Discovered Issue Log

| Issue # | Component | Severity | Bug Summary | Status |
|---|---|---|---|---|
| **ISSUE-01** | `proxy-engine` | **Medium** | `PATCH /expose/{id}/weights` returns 200 OK for non-existent expose IDs. | Confirmed (Spec) |
| **ISSUE-02** | `proxy-engine` | **Medium** | `DELETE /loadbalancers/{id}/backends/{bid}` returns 200 OK on mismatched/fake ID. | Confirmed (Spec) |
| **ISSUE-03** | `cloud-engine` | **High** | `pnet_version: latest` causes guest kernel panic in Firecracker on boot. | Confirmed (Spec) |
| **ISSUE-04** | `cloud-engine` | **Low** | Percent-encoded slash in Operation ID (`%2F`) returns 404 instead of routing. | Confirmed (Spec) |
| **ISSUE-05** | `cloud-engine` | **Medium** | Key naming divergence: Account creation returns `account_id`, listing returns `id`. | Confirmed (Spec) |
| **ISSUE-06** | `[Discovered]` | `[Critical/High]` | `[Add new discovered crash or race condition bug here]` | To be tested |
| **ISSUE-07** | `[Discovered]` | `[Critical/High]` | `[Add new discovered crash or race condition bug here]` | To be tested |

---

### GitHub Issue Submission Template

সাগর ভাইয়ের নির্দেশনা অনুযায়ী প্রতিটি ইস্যু নিচের ফরম্যাটে PoC ও Suggested Fix সহ ওপেন করবেন:

```markdown
### [Bug]: <Short Descriptive Title>

#### 1. Affected Component & Endpoint:
- **Repository:** `cloud-engine` / `proxy-engine`
- **Endpoint:** `<METHOD> /path`

#### 2. Severity:
Critical (System Crash/Panic) | High (Data Leak/Race) | Medium (Quirk/Misleading 200)

#### 3. Steps to Reproduce (Proof of Concept - PoC):
```bash
curl -X <METHOD> http://localhost:8080/... \
  -H "Content-Type: application/json" \
  -d '{ ... }'
```

#### 4. Expected Behavior:
Endpoint should return `404 Not Found` / `409 Conflict` with `{"error": "..."}`.

#### 5. Actual Behavior & Server Logs:
Server returned `500 Internal Server Error` (or misleading `200 OK`).
```
[Server Log Snippet / Panic Trace]
```

#### 6. Root Cause Analysis:
Describe why this happened (e.g., missing ID lookup in database, missing mutex lock in memory map).

#### 7. Suggested Fix / Solution PR:
- File: `internal/api/...go`
- Add validation before updating:
```go
if record == nil {
    c.JSON(http.StatusNotFound, gin.H{"error": "record not found"})
    return
}
```
```

---

## 6. Ready-to-Run Automation Script (`api_test_suite.sh`)

এই স্ক্রিপ্টটি লোকালি সেভ করে সরাসরি টেস্ট চালাতে পারেন:

```bash
#!/usr/bin/env bash
# =============================================================================
#  Poridhi Automated API Smoke & Concurrency Test Runner
# =============================================================================
set -uo pipefail

CE_API="${CE_API:-http://localhost:8080}"
PE_API="${PE_API:-http://localhost:8080}"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1 (Got $2, Expected $3)"; }

echo "=== 1. Basic Health Check ==="
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$CE_API/healthz")
[[ "$STATUS" == "200" ]] && pass "Healthz is 200" || fail "Healthz" "$STATUS" "200"

echo "=== 2. Account Validation ==="
# Missing field check
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$CE_API/accounts" \
  -H "Content-Type: application/json" -d '{"name":""}')
[[ "$STATUS" == "400" ]] && pass "Empty account rejected with 400" || fail "Account empty field" "$STATUS" "400"

echo "=== 3. VM Memory Floor Validation (<128MB) ==="
STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$CE_API/vms" \
  -H "Content-Type: application/json" \
  -d '{"name":"low-mem","memory_mb":64,"vcpu":1}')
[[ "$STATUS" == "400" ]] && pass "Memory < 128MB rejected with 400" || fail "Memory floor" "$STATUS" "400"

echo "=== 4. 10 Concurrent Requests to /proxy-ips (CAS Lock Test) ==="
PIDS=()
for i in {1..10}; do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "$CE_API/proxy-ips" \
    -H "Content-Type: application/json" \
    -d '{"customer_id":"stress-c1","vm_id":"stress-vm1","kind":"expose"}' &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do
  wait "$pid"
done
pass "10 concurrent /proxy-ips calls completed without hanging"

echo "=== Test Run Complete ==="
```

