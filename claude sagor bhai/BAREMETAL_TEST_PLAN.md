# End-to-End Baremetal & Concurrency Test Plan

> **System Components:** `cloud-engine` (Compute, Hypervisor, OVN) & `proxy-engine` (Ingress, Envoy xDS, BGP)  
> **Prepared for:** Senior Engineering Leadership (Sagore Sarker Bhai) & Core Engineering Team  
> **Execution Scope:** Baremetal / Staging Cluster with real KVM, Firecracker, Jailer, OVN, and Envoy Pods  
> **Focus:** Full E2E User Journey, 8–10 Concurrent User Simulation (2s delay), In-Guest Service Verification, and Latency Benchmarking

---

## 1. Executive Summary & Objectives

This document outlines the rigorous testing strategy to validate the Poridhi infrastructure on a running **Baremetal / Staging server**.

While local development machines only run the **control-plane** (etcd + postgres), baremetal access enables full **data-plane** execution: booting real Linux microVMs via Firecracker, interacting over SSH and in-guest HTTP services, and routing live internet traffic through the Envoy xDS proxy.

### Primary Goals:
1. **Full Lifecycle Validation:** End-to-end user verification from account creation to a publicly reachable web page.
2. **8–10 Concurrent Users Simulation:** Parallel execution of complete user journeys with a 2-second think-time between sequential calls.
3. **In-Guest Service Verification:** Validating guest OS boot, SSH availability (port 22), and web service response (port 80).
4. **Public Exposure & Ingress Routing:** Exposing guest port 80 via `proxy-engine` and validating external HTTP reachability.
5. **Latency & Performance Benchmarks:** Measuring exact timings for VM boot (Warm vs Cold tier), SSH readiness, Expose binding, and End-to-End latency.
6. **Stress & Bottleneck Detection:** Identifying any TAP interface exhaustion, OVN port provisioning delays, etcd CAS lock contention, or xDS push storms under concurrent load.

---

## 2. End-to-End Architecture & Data Flow

```
[ External User / Browser ]
             │
             ▼ (Public Ingress)
   [ Envoy Proxy Pod ] ◄──── (xDS Dynamic Route Push) ──── [ proxy-engine ]
             │                                                    │
             │ (Geneve Tunnel / BGP CGNAT /32)                    │ (Resolves VM state & node)
             ▼                                                    ▼
   [ Baremetal Node Agent ] ── (ns-vpc-xxx) ─────────── [ cloud-engine API ]
             │                                                    │
             ▼ (TAP Device + Jailer)                              ▼
   [ Firecracker microVM ] ── (In-Guest App on Port 80) ─── [ etcd & OVN Switch ]
```

---

## 3. Test Phases & Step-by-Step Execution

### 🔹 Phase 1: Single User Baseline & Data-Plane Verification
* **Goal:** Confirm all components interact cleanly without errors and establish baseline timings.

| Step | Action | API Endpoint / Tool | Target SLA / Expected Result |
| :---: | :--- | :--- | :--- |
| **1** | Create Tenant Account | `POST /accounts/create` | `201 Created` with unique VNI & VPC ID (< 50ms) |
| **2** | Register Customer | `POST /customers` | `201 Created` with standard tier (< 50ms) |
| **3** | Launch MicroVM | `POST /vms/create` | `201/202` provisioning started; poll `GET /vms/:id` until state = `running` |
| **4** | Measure Boot Latency | Polling `GET /vms/:id` | **Warm Tier:** ~15 seconds \| **Cold Tier:** ~60 seconds |
| **5** | Retrieve SSH Info | `GET /vms/:id/ssh` | Returns `ssh_command`, private IP (`10.0.0.x`), and namespace |
| **6** | In-Guest Web Service | SSH into guest VM | Run `echo "Hello Poridhi" > index.html && python3 -m http.server 80 &` |
| **7** | In-Guest Verification | Curl port 80 inside VM | Returns `HTTP 200 OK` from guest web server |
| **8** | Expose Port 80 | `POST /expose` | `201 Created` binding port 80 to `<subdomain>.expose.poridhi.io` (< 3s) |
| **9** | External HTTP Ingress | Browser / cURL from outside | Access `http://<subdomain>.expose.poridhi.io` -> `HTTP 200 OK` |
| **10**| Clean Teardown | `DELETE /expose`, `DELETE /vms` | Graceful VM shutdown, TAP deletion, and proxy IP release |

---

### 🔹 Phase 2: 8–10 Concurrent Users Simulation (Automated Load Test)
* **Goal:** Simulate realistic user traffic with 8–10 parallel users executing the full lifecycle simultaneously.
* **Think Time:** **2 seconds delay** between sequential requests (`sleep 2`) per user to emulate real user behavior.
* **Tooling:** Executed via `simulate_concurrent_users.sh 8` and `postman_collection.json`.

#### Sequence Executed by Each Parallel User:
1. `POST /accounts/create` $\to$ pause 2s
2. `POST /customers` $\to$ pause 2s
3. `POST /vms/create` (concurrent boot request) $\to$ pause 2s
4. Poll `GET /vms/:id` until `running` (records boot duration)
5. `GET /vms/:id/ssh` $\to$ verify port 22 readiness
6. Probe in-guest HTTP service on port 80
7. `POST /expose` (binding to distinct subdomains: `site-user1`, `site-user2`, etc.) $\to$ pause 2s
8. External HTTP probe to verify live routing through Envoy $\to$ pause 2s
9. Teardown and resource release

#### Key Failure Modes & Checks:
- **Jailer & TAP Capacity:** Ensure the host creates 10 isolated TAP interfaces without conflict (`tap-vm-xxx`).
- **IPAM Allocation:** Verify all 10 VPCs and microVMs receive unique private IPs and Geneve VNIs without race conditions.
- **xDS Push Storm:** Check whether 10 rapid `POST /expose` calls overwhelm `proxy-engine` or cause dropped xDS snapshots.
- **Memory & CPU Saturation:** Monitor host load average, ensuring 10 Firecracker processes remain within memory limits.

---

### 🔹 Phase 3: Failure Modes & Edge Case Stress Testing
1. **Duplicate VM Operations:** Attempt concurrent restart / terminate calls on the same VM to verify lock safety.
2. **Expose with Invalid Backends:** Verify error handling when exposing stopped or terminated VMs.
3. **Resource Leak Audit:**
   - Verify zero orphaned Firecracker processes after deletion (`pgrep firecracker`).
   - Verify OVN logical switch ports are unmapped cleanly.
   - Verify proxy CGNAT /32 IPs are returned to the pool.

---

## 4. Latency & Benchmarking Deliverable Format

The execution will generate a comprehensive benchmark table formatted as follows:

| User ID | Account Latency | Customer Latency | VM Launch Req | VM Boot State | SSH Ready | Expose Latency | Ingress Response | Total E2E Time | Status |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **User 1** | 24ms | 18ms | 12ms | 14.8s | 2.1s | 1.8s | 110ms | 31.2s | ✅ PASS |
| **User 2** | 31ms | 16ms | 11ms | 15.2s | 2.3s | 1.9s | 115ms | 31.8s | ✅ PASS |
| **...** | ... | ... | ... | ... | ... | ... | ... | ... | ... |
| **User 10**| 28ms | 19ms | 13ms | 15.6s | 2.4s | 2.1s | 120ms | 32.5s | ✅ PASS |

---

## 5. Ready Artifacts in Local PoC Directory

All test tooling has been engineered, pre-tested, and ready in local PoC directory:

1. **Postman Collection (`postman_collection.json`):**
   - Standard Postman v2.1.0 collection with chained variables (`account_id`, `vpc_id`, `vm_id`, `subdomain`) and automated test scripts.
2. **Postman Environment (`postman_environment.json`):**
   - Configurable host endpoints (`ce_url`, `pe_url`).
3. **Bash Simulation Suite (`simulate_concurrent_users.sh`):**
   - Multithreaded bash script capable of running against any baremetal IP with `--users 8` or `--users 10` and custom delays.
4. **Single-Flow Verification Runner (`run_e2e_flow.sh`):**
   - 1-click end-to-end health & flow verifier with colored status logs.

---

## 6. Access Requirements to Begin Execution

To start Phase 1 immediately, the following parameters are required from the engineering team:
- **Server IP / Domain:** (e.g. `http://<baremetal-ip>:8080` for cloud-engine and `:8081` for proxy-engine).
- **SSH Access (Optional but recommended):** For verifying in-guest microVM services and node telemetry directly.
