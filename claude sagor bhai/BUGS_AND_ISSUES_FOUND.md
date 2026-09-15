# Poridhi Platform: Discovered Issues, Bugs & PR Action Plan

> **Tracking Document:** Identified during step-by-step test execution, static analysis, CI verification, and code auditing.
> **Prepared for:** Senior Engineering Leadership (Sagore Sarker Bhai) & Core Engineering Team
> **Status:** Active Bug Log with Root Cause Analysis (RCA) & Solution PRs

---

## 📊 Summary of Discovered Bugs & Issues

| Bug ID           | Component        | Severity         | Category           | Description                                                                                           | Suggested Action                           |
| ---------------- | ---------------- | ---------------- | ------------------ | ----------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| **BUG-01** | `proxy-engine` | **High**   | CI / Determinism   | Missing replay test suite (`replay_test.go`) & testdata fixtures in `proxy-engine`.               | Create`replay_test.go` & record fixtures |
| **BUG-02** | `cloud-engine` | **High**   | Config / Startup   | Missing`TEMPORAL_PAYLOAD_KEY` causes `check-configs.sh` and Docker worker/api validation to fail. | Add default/doc in`.env.example`         |
| **BUG-03** | `proxy-engine` | **Medium** | API Logic          | `PATCH /expose/:id/weights` returns `200 OK` for non-existent Expose IDs.                         | Check`RowsAffected > 0`, return 404      |
| **BUG-04** | `proxy-engine` | **Medium** | API Logic          | `DELETE /loadbalancers/:id/backends/:backend_id` returns `200 OK` on fake/mismatched ID.          | Validate`:id` ownership, return 404      |
| **BUG-05** | `cloud-engine` | **High**   | VM Guest Defect    | `pnet_version: latest` (1.0.3) triggers Firecracker guest kernel/daemon panic on boot.              | Pin`"1.0.2"` until upstream 1.0.4        |
| **BUG-06** | `cloud-engine` | **High**   | Concurrency / Race | `SetVMState` in etcd store uses non-atomic Read-Modify-Write without CAS transaction.               | Implement etcd CAS retry loop              |
| **BUG-07** | `cloud-engine` | **Low**    | Contract / SDK     | Key divergence:`POST /accounts` emits `account_id` while `GET /accounts` emits `id`.          | Emit both keys for compatibility           |
| **BUG-08** | `proxy-engine` | **High**   | State / Contract   | `POST /customers` duplicate returns `201 Created` with unpersisted payload & zero-value `created_at`.| Use `RETURNING` or return 409 Conflict    |
| **BUG-09** | `proxy-engine` | **Medium** | API Logic          | `DELETE /customers/:id`, `DELETE /proxy-nodes/:id`, and `POST /proxy-nodes/:id/heartbeat` return 200 on fake IDs.| Validate RowsAffected, return 404         |
| **BUG-10** | Both Repos     | **Low**    | API Convention     | Route listing convention divergence (`/accounts/list`, `/vms/list` vs `/expose`, `/loadbalancers`).| Standardize RESTful paths                 |
| **BUG-11** | `cloud-engine` | **High**   | Concurrency / Perf | `AllocateVNI` linear etcd CAS loop causes 15.6x latency spike under 40+ concurrent requests.         | Implement exponential backoff / cursor CAS |
| **BUG-12** | `proxy-engine` | **High**   | Concurrency / Race | Mass phantom responses: 40/40 duplicate `POST /customers` return 201 with `0001-01-01` timestamp.    | Return 409 Conflict on existing customer   |
| **BUG-13** | `proxy-engine` | **Medium** | Database / N+1     | `pushXDS()` runs $O(N)$ sequential queries on every write, starving `pgxpool` under concurrent load. | Batch query load balancers & backends      |

---

## 🔍 Detailed Bug Reports with PoC & Suggested Fixes

---

### 🔴 BUG-01: Missing Replay Test Coverage in `proxy-engine`

#### 1. Description & Impact:

`cloud-engine` maintains 18 workflow replay test fixtures in `internal/workflows/testdata/` to protect against non-deterministic workflow edits. However, `proxy-engine` has **zero replay tests** and lacks `internal/workflows/replay_test.go`.
If an engineer modifies any of the 5 proxy-engine workflows (`CustomerProvision`, `ExposeProvision`, `LBProvision`, `CertIssue`, `Sweeps`) with non-deterministic Go code, Temporal workflow tasks will fail with `NonDeterministicWorkflowError` and **retry infinitely**, causing customer operations to silently freeze in production.

#### 2. Proof of Concept (PoC) / Reproduction:

Run the replay verification script against `proxy-engine`:

```bash
cd /home/iftakhar/Poridhi/claude\ sagor\ bhai/proxy-engine
WORKFLOW_DIR=internal/workflows ../cloud-engine/scripts/ci/check-replay-coverage.sh
```

**Actual Output:**

```
=== replay coverage: internal/workflows ===
✗ no replay test at internal/workflows/replay_test.go
exit status 1
```

#### 3. Suggested Fix / Solution PR:

1. Create `proxy-engine/internal/workflows/replay_test.go`:

```go
package workflows

import (
	"testing"
	"go.temporal.io/sdk/worker"
)

func TestReplayCommittedHistories(t *testing.T) {
	replayer := worker.NewWorkflowReplayer()
	replayer.RegisterWorkflow(CustomerProvisionWorkflow)
	replayer.RegisterWorkflow(ExposeProvisionWorkflow)
	replayer.RegisterWorkflow(LBProvisionWorkflow)
	// Replay files in testdata/*.json
}
```

2. Generate initial fixtures using `TestGenerateHistories` and commit to `proxy-engine/internal/workflows/testdata/`.

---

### 🔴 BUG-02: Missing `TEMPORAL_PAYLOAD_KEY` Fails Docker Config Validation

#### 1. Description & Impact:

Running configuration validation fails for the Docker compose environment configurations because `TEMPORAL_PAYLOAD_KEY` is required by the config validator but not set.

#### 2. Proof of Concept (PoC) / Reproduction:

```bash
cd /home/iftakhar/Poridhi/claude\ sagor\ bhai/cloud-engine
./scripts/ci/check-configs.sh
```

**Actual Output:**

```
=== configs ===
  ok   configs/worker.yaml
  FAIL configs/docker/worker.yaml: validate: temporal: TEMPORAL_PAYLOAD_KEY is unset; generate one with `openssl rand -base64 32`
  ok   configs/api.yaml
  FAIL configs/docker/api.yaml: validate: temporal: TEMPORAL_PAYLOAD_KEY is unset; generate one with `openssl rand -base64 32`
2 config(s) failed
exit status 1
```

#### 3. Suggested Fix / Solution PR:

In `configs/docker/worker.yaml` and `configs/docker/api.yaml`, ensure the validator permits an empty string when payload encryption is disabled, or update `.env.example` to explicitly include:

```bash
TEMPORAL_PAYLOAD_KEY=$(openssl rand -base64 32)
```

---

### 🟡 BUG-03: `PATCH /expose/:id/weights` Returns `200 OK` on Non-Existent Expose ID

#### 1. Description & Impact:

When a client sends a PATCH request to update weights for an Expose ID that does not exist in the database, the API handler returns `HTTP 200 OK` with `{"updated": "<fake-id>"}`, misleading clients into believing a non-existent expose was successfully updated.

#### 2. Proof of Concept (PoC) / Reproduction:

```bash
curl -i -X PATCH http://localhost:8080/expose/fake-expose-id-9999/weights \
  -H "Content-Type: application/json" \
  -d '{"weights":{"vm-1":100}}'
```

**Actual Response:**

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"updated":"fake-expose-id-9999"}
```

#### 3. Root Cause Analysis:

In `proxy-engine/internal/api/expose_legacy.go:283-302`:

```go
func (h *Handler) UpdateWeights(c *gin.Context) {
    ...
    if err := h.store.UpdateExposeWeights(ctx, id, body.Weights); err != nil {
        errResp(c, http.StatusInternalServerError, err.Error())
        return
    }
    c.JSON(http.StatusOK, gin.H{"updated": id})
}
```

In `proxy-engine/internal/store/postgres.go:569-574`:

```go
func (s *Store) UpdateExposeWeights(ctx context.Context, id string, weights map[string]int) error {
    weightsJSON, _ := json.Marshal(weights)
    tag, err := s.pool.Exec(ctx, `UPDATE expose_records SET weights=$1 WHERE id=$2`, weightsJSON, id)
    return err // If id doesn't exist, tag.RowsAffected() == 0, but err is nil!
}
```

#### 4. Suggested Fix / Solution PR:

In `proxy-engine/internal/store/postgres.go`:

```go
func (s *Store) UpdateExposeWeights(ctx context.Context, id string, weights map[string]int) error {
    weightsJSON, _ := json.Marshal(weights)
    tag, err := s.pool.Exec(ctx, `UPDATE expose_records SET weights=$1 WHERE id=$2 AND state != 'deleted'`, weightsJSON, id)
    if err != nil {
        return err
    }
    if tag.RowsAffected() == 0 {
        return ErrNotFound
    }
    return nil
}
```

In `expose_legacy.go`:

```go
if errors.Is(err, store.ErrNotFound) {
    errResp(c, http.StatusNotFound, "expose record not found")
    return
}
```

---

### 🟡 BUG-04: `DELETE /loadbalancers/:id/backends/:backend_id` Returns `200 OK` on Non-Existent or Mismatched Backend

#### 1. Description & Impact:

When deleting a backend from a load balancer:

1. The load balancer ID (`:id`) in the path is completely ignored.
2. If `:backend_id` does not exist, the API still returns `HTTP 200 OK` with `{"removed": "<fake-id>"}`.

#### 2. Proof of Concept (PoC) / Reproduction:

```bash
curl -i -X DELETE http://localhost:8080/loadbalancers/real-lb-1/backends/fake-backend-999
```

**Actual Response:**

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"removed":"fake-backend-999"}
```

#### 3. Root Cause Analysis:

In `proxy-engine/internal/api/loadbalancer_legacy.go:518-531`:

```go
func (h *Handler) RemoveLBBackend(c *gin.Context) {
    backendID := c.Param("backend_id")
    // Note: c.Param("id") is never read!
    if err := h.store.RemoveLBBackend(ctx, backendID); err != nil { ... }
    c.JSON(http.StatusOK, gin.H{"removed": backendID})
}
```

In `internal/store/postgres.go`:

```go
func (s *Store) RemoveLBBackend(ctx context.Context, id string) error {
    _, err := s.pool.Exec(ctx, `UPDATE lb_backends SET state='deleted' WHERE id=$1`, id)
    return err // If id doesn't exist, returns nil!
}
```

#### 4. Suggested Fix / Solution PR:

1. Verify `:backend_id` belongs to `:id`:

```sql
UPDATE lb_backends SET state='deleted', deleted_at=now() WHERE id=$1 AND lb_id=$2
```

2. If `tag.RowsAffected() == 0`, return `HTTP 404 Not Found`.

---

### 🔴 BUG-05: `pnet_version: latest` (1.0.3) Causes Firecracker Guest Kernel Panic

#### 1. Description & Impact:

When creating a VM image with `POST /images` omitting `pnet_version` or setting it to `"latest"`, the template builder injects pnet 1.0.3. When the Firecracker guest boots, pnet 1.0.3 crashes with `index out of range` in `client/system.GetInfo (info_linux.go:62)`, preventing the VM from enrolling in the mesh.

#### 2. Code Reference:

In `cloud-engine/internal/template/pnetrelease.go:62-69`:

```go
// KNOWN BAD RELEASE: 1.0.3 panics on Firecracker guests (index out of
// range in client/system.GetInfo, info_linux.go:62 — its system-info
// parser chokes on something in the minimal guest environment; the same
// build works on ordinary hosts). The daemon dies at login, the guest
// never enrols, and the failure reads as an empty pnet_peer_id much
// later. Until a fixed release ships, callers should pin "1.0.2".
```

#### 3. Suggested Fix / Solution PR:

In `cloud-engine/internal/template/pnetrelease.go`:

```go
if version == "latest" {
    // Pin to safe release 1.0.2 until upstream 1.0.4 resolves info_linux.go:62
    version = "1.0.2"
}
```

---

### 🔴 BUG-06: Non-Atomic Read-Modify-Write in `SetVMState` (etcd Race Condition)

#### 1. Description & Impact:

In `cloud-engine`, updating a VM's state (`SetVMState`) is performed by reading the VM from etcd, mutating the state in memory, and putting it back. Under concurrent calls (e.g. agent updating `running` while reconciler updates `node_lost`), one write silently overwrites the other, leading to stale states and orphaned VMs.

#### 2. Root Cause Analysis:

In `cloud-engine/internal/store/vm.go:71-78`:

```go
func (s *Store) SetVMState(ctx context.Context, vmID string, state types.VMState) error {
    vm, err := s.GetVM(ctx, vmID)
    if err != nil {
        return err
    }
    vm.State = state
    return s.PutVM(ctx, vm) // Direct overwrite without etcd CAS transaction!
}
```

#### 3. Suggested Fix / Solution PR:

Refactor `SetVMState` to use an etcd Compare-And-Swap (CAS) transaction with revision check:

```go
func (s *Store) SetVMState(ctx context.Context, vmID string, state types.VMState) error {
    key := VMKey(vmID)
    for i := 0; i < maxRetries; i++ {
        resp, err := s.client.Get(ctx, key)
        if err != nil { return err }
        if len(resp.Kvs) == 0 { return ErrNotFound }

        var vm types.VM
        if err := json.Unmarshal(resp.Kvs[0].Value, &vm); err != nil { return err }
        vm.State = state
        val, _ := json.Marshal(vm)

        txnResp, err := s.client.Txn(ctx).
            If(clientv3.Compare(clientv3.ModRevision(key), "=", resp.Kvs[0].ModRevision)).
            Then(clientv3.OpPut(key, string(val))).
            Commit()
        if err != nil { return err }
        if txnResp.Succeeded { return nil }
    }
    return ErrConcurrentUpdate
}
```

---

### 🟢 BUG-07: Key Naming Inconsistency Between `POST /accounts` and `GET /accounts`

#### 1. Description:

- `POST /accounts/create` returns JSON with key `"account_id"`.
- `GET /accounts/:id` returns JSON with key `"id"`.
- `GET /accounts/list` returns array with key `"id"`.

#### 2. Code Reference:

- `cloud-engine/internal/api/account_create.go:46`: `gin.H{"account_id": result.Account.ID}`
- `cloud-engine/pkg/types/types.go:48`: `ID string `json:"id"``

#### 3. Suggested Fix:

In `account_create.go`, emit both keys so existing clients don't break:

```go
gin.H{
    "id":         result.Account.ID,
    "account_id": result.Account.ID,
    ...
}
```

---

### 🔴 BUG-08: `POST /customers` Silently Ignores Existing Rows and Returns Phantom Payload

#### 1. Description & Impact:
When `POST /customers` is called concurrently or repeatedly with an already-existing `account_id`:
1. The database query in `proxy-engine/internal/store/postgres.go` runs `INSERT INTO customers(id, tier) VALUES($1, $2) ON CONFLICT(id) DO NOTHING`.
2. The handler blindly constructs `customer := &store.Customer{ID: req.ID, Tier: req.Tier}` without fetching the actual persisted values.
3. As a result, the HTTP response returns `201 Created` with a zero-value timestamp: `"created_at": "0001-01-01T00:00:00Z"`.
4. Worse: If the client attempts to change their tier via `POST /customers` (e.g., `"tier": "enterprise"`), the API lies and returns `201 Created` with `"tier": "enterprise"`, but the database still silently retains `"standard"`!

#### 2. Proof of Concept (PoC) / Reproduction:
```bash
# 1. Create a customer
curl -s -X POST http://127.0.0.1:8095/customers \
  -H "Content-Type: application/json" \
  -d '{"account_id":"ff6dac9f6953878215cf05bf17ab28e2","tier":"standard"}'

# 2. Re-send with enterprise tier
curl -s -X POST http://127.0.0.1:8095/customers \
  -H "Content-Type: application/json" \
  -d '{"account_id":"ff6dac9f6953878215cf05bf17ab28e2","tier":"enterprise"}'

# 3. Query GET /customers/:id
curl -s http://127.0.0.1:8095/customers/ff6dac9f6953878215cf05bf17ab28e2
```

**Actual Output:**
- `POST` response: `HTTP 201 Created {"customer_id":"...","tier":"enterprise","created_at":"0001-01-01T00:00:00Z"}`
- `GET` response: `HTTP 200 OK {"customer_id":"...","tier":"standard","created_at":"2026-09-11T15:51:04.703626+06:00"}`

#### 3. Suggested Fix / Solution PR:
In `proxy-engine/internal/store/postgres.go`:
```go
func (s *Store) InsertCustomer(ctx context.Context, c *Customer) error {
    row := s.pool.QueryRow(ctx,
        `INSERT INTO customers(id, tier) VALUES($1, $2)
         ON CONFLICT(id) DO UPDATE SET id=EXCLUDED.id
         RETURNING id, tier, ns_ready, created_at`,
        c.ID, c.Tier)
    return row.Scan(&c.ID, &c.Tier, &c.NSReady, &c.CreatedAt)
}
```
Or return `409 Conflict` if existing row cannot be modified via POST.

---

### 🔴 BUG-09: Missing `RowsAffected` Checks on Delete / Heartbeat Operations

#### 1. Description & Impact:
Multiple deletion and heartbeat handlers ignore whether any database row was affected:
- `DELETE /customers/:id`: Calling delete on a non-existent customer returns `HTTP 200 OK {"deleted": "<fake-id>"}`.
- `DELETE /proxy-nodes/:node_id`: Calling delete on a non-existent proxy node returns `HTTP 200 OK {"deleted": "<fake-node-id>"}`.
- `POST /proxy-nodes/:node_id/heartbeat`: The handler has code to return `404 Not Found`, but `store.UpdateProxyNodeHeartbeat` discards the command tag and returns `nil` error, causing `HTTP 200 OK {"ack": true}` to be returned for non-existent proxy nodes.

#### 2. Proof of Concept (PoC) / Reproduction:
```bash
curl -s -i -X DELETE http://127.0.0.1:8095/customers/nonexistent-customer-123
# Returns HTTP 200 OK {"deleted":"nonexistent-customer-123"}

curl -s -i -X POST http://127.0.0.1:8095/proxy-nodes/fake-node-id/heartbeat \
  -H "Content-Type: application/json" -d '{"status":"healthy"}'
# Returns HTTP 200 OK {"ack":true}
```

#### 3. Suggested Fix / Solution PR:
In `proxy-engine/internal/store/postgres.go`:
Check `tag.RowsAffected()` in `DeleteCustomer`, `DeleteProxyNode`, and `UpdateProxyNodeHeartbeat`. Return `store.ErrNotFound` when `RowsAffected == 0`.

---

### 🟢 BUG-10: Cross-Platform Route Naming Divergence (`/list` vs Bare Nouns)

#### 1. Description:
`cloud-engine` endpoints require `/list` suffix for collection routes (`/accounts/list`, `/vms/list`, `/nodes/list`), whereas `proxy-engine` follows standard REST bare noun conventions (`/expose`, `/loadbalancers`, `/proxy-nodes`).
Calling standard REST paths like `GET /nodes` or `GET /accounts` results in `404 page not found`.

#### 2. Suggested Fix:
Register alias routes in `cloud-engine/internal/api/handler.go`:
```go
r.GET("/accounts", h.ListAccounts)
r.GET("/accounts/list", h.ListAccounts)
r.GET("/vms", h.ListVMs)
r.GET("/vms/list", h.ListVMs)
r.GET("/nodes", h.ListNodes)
r.GET("/nodes/list", h.ListNodes)
```

---

### 🔴 BUG-11: VNI CAS Contention & 15.6x Latency Degradation Under 40 Concurrency

#### 1. Description & Impact:
In `cloud-engine/internal/ipam/ipam.go:61-94`, `AllocateVNI` assigns Geneve VNIs by reading a cursor and attempting an etcd CAS transaction in a linear loop (`for vni := cursor; vni <= vniMax; vni++`).
Under a minimal load of 40 concurrent account creation requests:
- At 10 concurrent requests: execution took **0.03 seconds**.
- At 40 concurrent requests: execution took **0.469 seconds** (**15.6x latency degradation**).
- **Cause**: All 40 threads read the same initial cursor simultaneously; 1 thread commits the CAS transaction, while the other 39 fail, retry, advance to `cursor+1`, and repeat. This produces $O(N^2)$ etcd round-trips ($40 \times 39 / 2 \approx 780$ transactions). Under higher loads (100+ concurrency), this will trigger etcd timeout errors and API client 504 Gateway Timeouts.

#### 2. Suggested Fix / Solution PR:
In `cloud-engine/internal/ipam/ipam.go`:
Implement atomic cursor increment (`clientv3.OpPut` with CAS increment or randomized backoff jitter) rather than linear optimistic lock walking.

---

### 🔴 BUG-12: Mass Phantom Confirmations on Concurrent `POST /customers` (40/40 Collisions)

#### 1. Description & Impact:
When 40 concurrent requests target `POST /customers` with the same account ID (e.g. rapid user double-clicking, frontend retry storms, or webhook replays):
- **100% of requests (40/40)** returned `HTTP 201 Created` with zero-value timestamp `"created_at": "0001-01-01T00:00:00Z"`.
- Exactly 1 row was inserted in PostgreSQL; the other 39 were silently discarded by `ON CONFLICT DO NOTHING`.
- The API told 39 callers that their customer and tier were successfully created, when in reality nothing was created or updated.

#### 2. Suggested Fix / Solution PR:
In `proxy-engine/internal/store/postgres.go` and `customer_legacy.go`:
Inspect `tag.RowsAffected()`. If `RowsAffected == 0`, return `HTTP 409 Conflict {"error": "customer already exists"}` instead of `201 Created`.

---

### 🟡 BUG-13: N+1 Database Query Storm on xDS Push During High-Churn Writes

#### 1. Description & Impact:
In `proxy-engine/internal/api/handler.go:155-210`, every write operation (`POST /expose`, `PATCH /expose/:id/weights`, `DELETE /expose/:id`, `POST /loadbalancers`, etc.) calls `pushXDS()`.
`pushXDS()` calls `h.globalState(ctx)` and `h.customerState(ctx, customerID)`, which executes:
1. `ListActiveExposes` (1 query)
2. `ListActiveLBs` (1 query)
3. For each load balancer: `ListActiveLBBackends` + `GetLBHealthCheck` (2 queries per LB)
4. `ListActiveProxyNodes` (1 query)

Under 40 concurrent mutating requests, this generates hundreds of sequential queries simultaneously against `pgxpool`. Because `pgxpool` default max connections is small, connection acquire latency balloons, causing request queueing.

#### 2. Suggested Fix / Solution PR:
1. Replace the N+1 loop with a single `JOIN` query: `SELECT lb.*, b.*, hc.* FROM lb_records ... JOIN lb_backends ...`.
2. Debounce xDS pushes using a channel and a coalesce timer (e.g. 100ms debounce buffer) so 40 rapid writes trigger only 1 xDS snapshot compilation.

---

## ⚡ Minimal Load & Stress Test Findings (30-40 Concurrent Requests)

| Stress Test Scenario | Concurrency | Duration | Pass Rate | Observed Behavior & Findings |
| :--- | :---: | :---: | :---: | :--- |
| **POST /accounts/create** | 40 | 0.469s | 40/40 (100%) | All 40 VNIs allocated uniquely. Latency increased 15.6x due to etcd CAS loop contention (**BUG-11**). |
| **POST /customers (Distinct Accounts)** | 40 | 0.053s | 40/40 (100%) | Inter-service calls from proxy-engine to cloud-engine handled 40 concurrent HTTP requests cleanly. |
| **POST /customers (Same Account ID)** | 40 | 0.033s | 40/40 (100% false 201) | 40/40 returned `201 Created` with `"0001-01-01"` zero-timestamps (**BUG-12**). |
| **DELETE /customers (Same ID)** | 40 | 0.052s | 40/40 (200 OK) | 1 actual delete, 39 phantom deletes all returned `200 OK {"deleted": "..."}` (**BUG-09**). |
| **POST /proxy-nodes (Shared Node IDs)**| 40 | 0.051s | 40/40 (100%) | Postgres `ON CONFLICT DO UPDATE` handled concurrent upserts cleanly without deadlocks. |
| **POST /expose (Cloud-Engine Integration)** | 40 | 0.033s | 40/40 | 39 returned `400 Bad Request` (VM not found), 1 returned `404` (Customer deleted). 0 server crashes. |

---

## 🎯 Action Items for PRs (Pull Requests)

1. **PR-01 (`proxy-engine`)**: Implement `internal/workflows/replay_test.go` and commit initial testdata fixtures.
2. **PR-02 (`proxy-engine`)**: Fix `UpdateExposeWeights`, `RemoveLBBackend`, `DeleteCustomer`, `DeleteProxyNode`, and `UpdateProxyNodeHeartbeat` to check `RowsAffected` and return `404 Not Found` when records do not exist.
3. **PR-03 (`proxy-engine`)**: Fix `InsertCustomer` to return `409 Conflict` on duplicate ID instead of returning phantom 201 with zero-value `created_at`.
4. **PR-04 (`proxy-engine`)**: Batch xDS state database queries (`globalState`) to eliminate N+1 query storms.
5. **PR-05 (`cloud-engine`)**: Refactor `SetVMState` in `internal/store/vm.go` to use etcd CAS retry loop.
6. **PR-06 (`cloud-engine`)**: Default `pnet_version` to `"1.0.2"` to safeguard against guest panic.
7. **PR-07 (`cloud-engine`)**: Add standard REST collection aliases (`/accounts`, `/vms`, `/nodes`) alongside `/list`.
8. **PR-08 (`cloud-engine`)**: Optimize `AllocateVNI` in `internal/ipam/ipam.go` with backoff jitter to eliminate the 15.6x latency spike under concurrency.
