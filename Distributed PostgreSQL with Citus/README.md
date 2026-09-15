# Distributed PostgreSQL with Citus & Flask Hands-On Labs

A comprehensive hands-on guide and production-grade implementation for setting up a distributed Citus PostgreSQL cluster on AWS with Pulumi, containerized with Docker, and integrated with a multi-tenant Python Flask REST API.

---

## 📚 Table of Contents

### Module 74: Sharding with Citus and Flask
- [x] [**Lab 44: Citus Cluster Provisioning**](./Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2044:%20Citus%20Cluster%20Provisioning/readme.md)
  - Infrastructure as Code with Pulumi on AWS (VPC, Subnets, Security Groups, EC2).
  - Automated Citus 12.1 deployment via EC2 `user_data` (1 Coordinator + 3 Workers).
  - Automated cluster formation and worker registration (`citus_add_node`).
- [x] [**Lab 45: Flask–Citus Integration**](./Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2045:%20Flask%E2%80%93Citus%20Integration/readme.md)
  - Multi-tenant Flask application with SQLAlchemy.
  - Transparent connection through Citus Coordinator via SSH tunnel.
  - Creating distributed tables and testing shard ingestion.

### Module 75: Distributed Schema and Querying
- [x] [**Lab 46: Distributed Schema Design**](./Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2046:%20Distributed%20Schema%20Design/readme.md)
  - Designing multi-tenant distributed schemas (`tenants`, `orders`).
  - Creating reference tables (`products`) for zero-network-overhead distributed joins.
  - Citus catalog verification (`pg_dist_partition`, `citus_tables`).
- [x] [**Lab 47: Sharded Data API**](./Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2047:%20Sharded%20Data%20API/readme.md)
  - Building REST endpoints for tenant-isolated data.
  - Verifying single-shard routing on insert and lookup.
- [x] [**Lab 48: Query Plan Analysis and Benchmarking**](./Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/readme.md)
  - Analyzing distributed execution plans (`EXPLAIN` router vs adaptive executor).
  - Benchmarking multi-tenant insertion throughput with Apache Bench (`ab`).

---

## 🛠️ Architecture & Tech Stack

- **Cloud Provider**: AWS (EC2 `t2.micro`, VPC, IGW, Route Tables, Security Groups)
- **Infrastructure as Code**: Pulumi (Python SDK)
- **Distributed Database**: Citus 12.1 on PostgreSQL 16 (Dockerized)
  - 1 Coordinator Node (Routing, Metadata, Query Planning)
  - 3 Worker Nodes (Sharding, Storage, Distributed Query Execution)
- **Application Layer**: Python 3, Flask 3.0, Flask-SQLAlchemy 3.1, `psycopg2-binary`
