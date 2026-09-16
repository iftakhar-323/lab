# Distributed PostgreSQL with Citus & Flask Hands-On Labs

A comprehensive hands-on guide and production-grade implementation for setting up a distributed Citus PostgreSQL cluster, containerized with Docker Compose, and integrated with a multi-tenant Python Flask REST API.

---

## 📚 Table of Contents

### Module 74: Sharding with Citus and Flask
- [x] [**Lab 44: Citus Cluster Provisioning**](./Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2044:%20Citus%20Cluster%20Provisioning/readme.md)
  - Horizontal scaling concepts and coordinator vs. worker node architecture.
  - Deploy a 3-node Citus 12.1 cluster using Docker Compose (1 Coordinator + 2 Workers).
  - Dynamic worker node registration and cluster topology verification via `citus_nodes`.
- [x] [**Lab 45: Flask–Citus Integration**](./Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/readme.md)
  - Connect a Flask REST API to Citus coordinator via SQLAlchemy and `psycopg2-binary`.
  - Create distributed event tables sharded by `tenant_id`.
  - Expose application port 5000 publicly via the **Poridhi Load Balancer** and verify ingestion.

### Module 75: Distributed Schema and Querying
- [x] [**Lab 46: Distributed Schema Design**](./Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2046:%20Distributed%20Schema%20Design/readme.md)
  - Understand the architectural distinction between Distributed, Reference, and Local tables.
  - Shard `orders` table across workers using `create_distributed_table('orders', 'tenant_id')`.
  - Replicate `products` globally to all worker nodes via `create_reference_table('products')`.
  - Inspect Citus distribution metadata using `citus_tables` and `citus_shards`.
- [x] [**Lab 47: Sharded Data API**](./Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/readme.md)
  - Build tenant-isolated REST endpoints (`POST /orders` and `GET /orders/<tenant_id>`).
  - Leverage Citus point-query routing to dispatch tenant requests directly to a single worker.
  - Access endpoints publicly through the Poridhi Load Balancer and test with multi-tenant payloads.
- [x] [**Lab 48: Query Plan Analysis and Benchmarking**](./Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/readme.md)
  - Analyze distributed execution plans using `EXPLAIN (ANALYZE, VERBOSE)`.
  - Compare single-tenant Router execution (`Task Count: 1`) with cross-tenant Adaptive scatter-gather.
  - Benchmark concurrent write throughput using a multi-threaded Python load generator.

---

## 🛠️ Architecture & Tech Stack

| Component | Technology | Description |
|---|---|---|
| **Distributed Database** | Citus 12.1 (PostgreSQL 16) | Coordinator + Worker distributed database cluster |
| **Container Engine** | Docker & Docker Compose | Isolated multi-node container networking |
| **Web Framework** | Python 3 & Flask 3.0 | Lightweight REST API framework |
| **ORM & Driver** | SQLAlchemy 2.0 & psycopg2-binary | Database abstraction and connection pooling |
| **Edge Routing** | Poridhi Load Balancer | Public internet proxy routing to container ports |
| **Load Testing** | Python `ThreadPoolExecutor` | High-concurrency write throughput benchmark |

---

## 🔑 Core Citus Concepts

| Concept | Description |
|---|---|
| **Coordinator Node** | The central entry point that stores cluster metadata, parses client queries, optimizes query plans, and delegates execution. |
| **Worker Nodes** | Independent PostgreSQL instances that store shards of distributed tables and execute sub-queries in parallel. |
| **Distributed Table** | A table horizontally partitioned into multiple physical shards across worker nodes based on a distribution column (e.g., `tenant_id`). |
| **Reference Table** | A table whose full dataset is replicated to every worker node, allowing worker-local joins with zero network latency. |
| **Local Table** | A traditional PostgreSQL table residing entirely on the coordinator node (e.g., global auth metadata). |
| **Point Query Routing** | When a query filters by the distribution key (`WHERE tenant_id = 501`), the coordinator routes directly to a single worker, bypassing the rest of the cluster. |
