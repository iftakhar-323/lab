# Cloud-Engine: Baremetal Live Bug Audit & Verification Report

---

## 1. Summary of Bug Verification on Live Baremetal

| Bug Reference    |  Component  |    Severity    | Description / Finding                                                                                             |                       Live Status on Baremetal                       |
| :--------------- | :----------: | :------------: | :---------------------------------------------------------------------------------------------------------------- | :-------------------------------------------------------------------: |
| **BUG-02** | Config / Env | **High** | Missing`TEMPORAL_PAYLOAD_KEY` in `.env.example`.                                                              | **Verified** in local template; server has it manually patched. |
| **BUG-05** |   VM Guest   | **High** | `pnet_version: latest` triggers panic inside Firecracker guest on boot.                                         |  **Verified**; image builder template requires pinned version.  |
| **BUG-06** |  etcd Store  | **High** | `SetVMState` performs non-atomic Read-Modify-Write (`GetVM` $\to$ `PutVM`) without CAS transaction.       | **Confirmed in Code**; race hazard during rapid status changes. |
| **BUG-07** | API Contract | **Low** | Contract divergence:`POST /accounts/create` returns `account_id`, while `GET /accounts/:id` returns `id`. |                 **CONFIRMED LIVE (100% Repro)**                 |
| **BUG-10** | REST Routing | **Low** | Route divergence:`GET /accounts` and `GET /vms` return `404 page not found`. Requires `/list`.            |                 **CONFIRMED LIVE (100% Repro)**                 |
| **BUG-11** |  IPAM / VNI  | **High** | `AllocateVNI` linear CAS retry loop degrades latency under concurrent onboarding.                               |       **Confirmed in Code**; no cursor randomize/backoff.       |

---

## 2. Newly Discovered Live Bugs on Baremetal Cluster

During live testing against the active baremetal API (`http://103.174.50.21:8080`), **4 new critical issues** were uncovered:

---

### 🔴 NEW-BUG-01: MicroVM Snapshot Precondition Failure (PID Tracking Mismatch)

#### 1. Description & Impact:

Calling `POST /vms/:id/snapshots` on an active, running Firecracker MicroVM fails immediately during the Temporal activity. The snapshot transitions to `"state": "failed"` with an RPC error.

#### 2. Live Reproduction Proof:

Executed live against running VM `65231f3faf6a46be929a589c130d777b`:

```bash
curl -s -X POST http://103.174.50.21:8080/vms/65231f3faf6a46be929a589c130d777b/snapshots \
  -H 'Content-Type: application/json' \
  -d '{"name":"snapshot-test"}'
```

Querying `GET /vms/65231f3faf6a46be929a589c130d777b/snapshots`:

```json
{
  "state": "failed",
  "error": "CreateSnapshot 65231f3faf6a46be929a589c130d777b: rpc error: code = FailedPrecondition desc = vm 65231f3faf6a46be929a589c130d777b: pid 3869818 is not this VM's firecracker process"
}
```

#### 3. Root Cause Analysis (RCA):

When Firecracker is launched inside the Jailer on Node-01, the agent records the Jailer wrapper process PID (`3869818`) instead of the child Firecracker daemon PID spawned inside the chroot jail. When `CreateSnapshotOnNode` queries the host process table to pause the VM for snapshotting, the PID name check fails the precondition.

#### 4. Suggested Fix:

In `cloud-engine/internal/agent/orchestrator.go`, extract and track the actual Firecracker child PID from `/proc/<pid>/task/` or the jailer cgroup rather than the parent jailer wrapper PID.

---

### 🟠 NEW-BUG-02: Blind 202 Accepted on Non-Existent Resources (Temporal Task Waste)

#### 1. Description & Impact:

The API handler blindly returns `202 Accepted` and triggers Temporal workflows for non-existent VMs and accounts without first verifying whether the record exists in etcd.

#### 2. Live Reproduction Proof:

Tested with a non-existent UUID `00000000000000000000000000000000`:

- `POST /vms/00000000.../restart` $\to$ Returns `202 Accepted` (`state: "restarting"`)
- `DELETE /vms/terminate/00000000...` $\to$ Returns `202 Accepted` (`state: "terminating"`)
- `DELETE /accounts/delete/00000000...` $\to$ Returns `202 Accepted` (`state: "deleting"`)

#### 3. Root Cause & Consequence:

The API routes directly call `h.temporal.Client.ExecuteWorkflow(...)` without querying `h.store.GetVM(...)` or `h.store.GetAccount(...)`. This floods Temporal task queues with phantom workflows that run, timeout, and generate false alert noise in worker logs.

#### 4. Suggested Fix:

Add a synchronous existence check in the Gin handlers before dispatching Temporal workflows:

```go
if _, err := h.store.GetVM(c.Request.Context(), vmID); err != nil {
    errResponse(c, http.StatusNotFound, "vm not found")
    return
}
```

---

### 🟡 NEW-BUG-03: Zero Uniqueness Validation on Account Creation (VNI Leak Risk)

#### 1. Description & Impact:

`POST /accounts/create` does not enforce any uniqueness check on `email`. Submitting the identical email and name creates multiple independent accounts and provisions separate VPCs with distinct Geneve VNIs.

#### 2. Live Reproduction Proof:

Submitting `{"name":"duplicate-test","email":"dup@example.com"}` twice in succession:

- Request 1: `202 Accepted` $\to$ Created Account `a34c887a...` with VPC `vpc-a34c887a` (VNI 101)
- Request 2: `202 Accepted` $\to$ Created Account `198782bc...` with VPC `vpc-198782bc` (VNI 102)

#### 3. Root Cause & Suggested Fix:

etcd stores accounts under `/accounts/<random_id>` without maintaining an inverted index key `/accounts-by-email/<email>`.
Enforce unique email indexing in `internal/store/account.go` with an etcd CAS transaction (`clientv3.Compare`).

---

### 🟡 NEW-BUG-04: Premature Resource Allocation on Invalid Image ID

#### 1. Description & Impact:

When `POST /vms/create` is requested with an invalid or non-existent `image_id`, the API returns `202 Accepted`, immediately reserves a private IP (`10.0.0.2`), assigns a MAC address, and dispatches the workflow. The workflow subsequently fails and marks the VM as `terminated`, unnecessarily consuming IPAM leases.

#### 2. Live Reproduction Proof:

```bash
curl -s -X POST http://103.174.50.21:8080/vms/create \
  -H 'Content-Type: application/json' \
  -d '{"name":"bad-img-vm","account_id":"...","vpc_id":"...","image_id":"img-nonexistent","vcpu":1,"memory_mb":512}'
```

Response: `202 Accepted` with `private_ip: "10.0.0.2"`.
Resulting VM status: `"state": "terminated"`.

#### 3. Suggested Fix:

Validate `image_id` against etcd in `CreateVM` before allocating VPC IP and MAC addresses.

---

## 3. Verified Status of Original Cloud-Engine Bugs

### 🔹 BUG-07: Key Divergence (`account_id` vs `id`) — Confirmed Live

- `POST /accounts/create` response:
  ```json
  { "account_id": "08aeb8c08fc8d0526b5cd2390df9ca2c", ... }
  ```
- `GET /accounts/08aeb8c08fc8d0526b5cd2390df9ca2c` response:
  ```json
  { "id": "08aeb8c08fc8d0526b5cd2390df9ca2c", ... }
  ```
- **Fix:** Emit both `account_id` and `id` in both endpoints for backward compatibility.

### 🔹 BUG-10: Route Naming Convention Divergence — Confirmed Live

- `GET http://103.174.50.21:8080/accounts` $\to$ `404 page not found`
- `GET http://103.174.50.21:8080/vms` $\to$ `404 page not found`
- `GET http://103.174.50.21:8080/nodes` $\to$ `404 page not found`
- The system strictly expects `/accounts/list`, `/vms/list`, and `/nodes/list`.
- **Fix:** Register route aliases (`r.GET("/accounts", h.ListAccounts)`) in `internal/api/handler.go`.

---

## 4. Master Cloud-Engine Bug Action Matrix

| Issue ID             |     Severity     | File Reference                                                   | Actionable Patch                                                                       |
| :------------------- | :--------------: | :--------------------------------------------------------------- | :------------------------------------------------------------------------------------- |
| **NEW-BUG-01** |  **High**  | `cloud-engine/internal/agent/orchestrator.go`                  | Fix Firecracker PID resolution vs jailer wrapper PID for snapshotting.                 |
| **NEW-BUG-02** | **Medium** | `cloud-engine/internal/api/vm_restart.go`, `vm_terminate.go` | Return`404 Not Found` if resource does not exist before starting Temporal workflow.  |
| **NEW-BUG-03** | **Medium** | `cloud-engine/internal/store/account.go`                       | Add`/accounts-by-email/` unique CAS index to prevent duplicate accounts & VNI waste. |
| **NEW-BUG-04** |  **Low**  | `cloud-engine/internal/api/vm_create.go`                       | Pre-validate`image_id` in store before allocating IP & MAC.                          |
| **BUG-06**     |  **High**  | `cloud-engine/internal/store/vm.go`                            | Replace`GetVM` $\to$ `PutVM` with etcd CAS retry loop in `SetVMState`.         |
| **BUG-07**     |  **Low**  | `cloud-engine/internal/api/account_*.go`                       | Unify`account_id` and `id` in JSON responses.                                      |
| **BUG-10**     |  **Low**  | `cloud-engine/internal/api/handler.go`                         | Add standard REST route aliases for listing endpoints.                                 |
| **BUG-11**     |  **High**  | `cloud-engine/internal/store/ipam.go`                          | Implement randomized exponential backoff on`AllocateVNI` CAS collisions.             |
