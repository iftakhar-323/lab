# Lab 44: Citus Cluster Provisioning

In this lab, you will deploy and configure a multi-node distributed PostgreSQL cluster using Citus and Docker Compose in your Poridhi environment. You will deploy a 4-service stack consisting of a Citus Coordinator, two Citus Worker nodes, and a pgAdmin 4 web management interface. You will learn the core mechanics of horizontal scaling, register worker nodes into the cluster metadata catalog, verify cluster health, and validate physical shard distribution across nodes.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2074:%20Sharding%20with%20Citus%20and%20Flask/Lab%2044:%20Citus%20Cluster%20Provisioning/images/architecture_diagram.svg" alt="Citus Cluster Provisioning Architecture" width="750">
</p>

---

## Theory: Sharding and Citus Architecture

### Horizontal Scaling vs Vertical Scaling
Traditional PostgreSQL instances scale vertically by adding more CPU, RAM, and disk IOPS to a single machine. While effective up to a limit, vertical scaling introduces high hardware costs, downtime during upgrades, and a single point of failure.

Horizontal scaling partitions large tables across multiple independent database servers (nodes). **Citus** is an open-source extension that transforms PostgreSQL into a distributed database, providing horizontal scalability without sacrificing ACID transactions, SQL querying, or indexing capabilities.

### Coordinator vs Worker Node Architecture
A Citus cluster operates on a master-worker distributed topology:

1. **Coordinator Node (`citus_coordinator`):**
   - Serves as the primary entry point for all client applications, web services, and DB administrators.
   - Stores cluster-wide metadata catalogs (`pg_dist_node`, `pg_dist_partition`, `citus_shards`).
   - Receives SQL queries, parses them, generates distributed execution plans, and routes query fragments to worker nodes.
   - Aggregates results from worker nodes and returns the final response to the client.

2. **Worker Nodes (`citus_worker_1`, `citus_worker_2`):**
   - Independent PostgreSQL instances running the Citus extension.
   - Hold physical partitions (shards) of distributed tables.
   - Execute query fragments sent by the coordinator in parallel using local CPU cores and memory.

3. **pgAdmin 4 (`citus_pgadmin`):**
   - Web-based administration tool for PostgreSQL and Citus.
   - Allows graphical inspection of nodes, active connections, tables, and execution stats.

---

## Objectives

- Deploy a multi-node Citus cluster (1 Coordinator + 2 Workers + 1 pgAdmin) using Docker Compose.
- Register worker nodes into the Citus coordinator metadata catalog using `citus_add_node()`.
- Verify cluster health and active worker connectivity using `pg_dist_node` and `citus_get_active_worker_nodes()`.
- Access pgAdmin 4 via browser / HTTP port `8080` and connect to the Citus cluster.
- Create a distributed table (`companies`), populate seed rows, and verify physical shard allocation across worker nodes via `citus_shards`.

---

## Project Structure

```text
citus-cluster-lab/
└── docker-compose.yml
```

---

## Step 1: Create Project Directory

Create a dedicated directory for your Citus cluster configuration:

```bash
mkdir -p ~/citus-cluster-lab
cd ~/citus-cluster-lab
```

---

## Step 2: Create Docker Compose Configuration

Create `docker-compose.yml` to define the coordinator, two workers, and pgAdmin 4:

```bash
cat << 'EOF' > docker-compose.yml
version: '3.8'
services:
  coordinator:
    image: citusdata/citus:12.1
    container_name: citus_coordinator
    restart: always
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus
    command: ["-c", "listen_addresses=*"]

  worker1:
    image: citusdata/citus:12.1
    container_name: citus_worker_1
    restart: always
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus

  worker2:
    image: citusdata/citus:12.1
    container_name: citus_worker_2
    restart: always
    environment:
      - POSTGRES_PASSWORD=citus_password
      - POSTGRES_USER=citus
      - POSTGRES_DB=citus

  pgadmin:
    image: dpage/pgadmin4:8.2
    container_name: citus_pgadmin
    restart: always
    ports:
      - "8080:80"
    environment:
      - PGADMIN_DEFAULT_EMAIL=admin@poridhi.com
      - PGADMIN_DEFAULT_PASSWORD=admin_password
    depends_on:
      - coordinator
EOF
```

---

## Step 3: Deploy the Cluster using Docker Compose

Ensure any conflicting containers are stopped, then launch the stack in detached mode:

```bash
docker compose up -d || docker-compose up -d
```

Verify that all 4 containers (`citus_coordinator`, `citus_worker_1`, `citus_worker_2`, `citus_pgadmin`) are running and healthy:

```bash
docker compose ps
```

---

## Step 4: Register Worker Nodes to Citus Coordinator

Wait 10 seconds for PostgreSQL initialization to complete, then connect to the coordinator and register both worker nodes:

```bash
sleep 10
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker1', 5432);"
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker2', 5432);"
```

Verify that both worker nodes are registered and active in the cluster catalog:

```bash
docker exec citus_coordinator psql -U citus -d citus -c "SELECT nodename, nodeport, isactive FROM pg_dist_node;"
```

You can also run Citus's built-in helper function:

```bash
docker exec citus_coordinator psql -U citus -d citus -c "SELECT * FROM citus_get_active_worker_nodes();"
```

Expected Output:
```text
 node_name | node_port 
-----------+-----------
 worker1   |      5432
 worker2   |      5432
(2 rows)
```

---

## Step 5: Access pgAdmin 4 Web Interface (Optional)

You can access the pgAdmin 4 GUI to manage and monitor the cluster:

1. Open your browser and navigate to `http://<YOUR_VM_IP>:8080` (or access port `8080` using the **Poridhi Load Balancer**).
2. Log in with the credentials:
   - **Email:** `admin@poridhi.com`
   - **Password:** `admin_password`
3. In the left panel, right-click **Servers** > **Register** > **Server...**:
   - **General Tab:** Name = `Citus Coordinator`
   - **Connection Tab:**
     - **Host name/address:** `coordinator` (or `citus_coordinator`)
     - **Port:** `5432`
     - **Maintenance database:** `citus`
     - **Username:** `citus`
     - **Password:** `citus_password`
4. Click **Save** to connect and browse cluster databases and metrics.

You can also verify pgAdmin HTTP responsiveness from the terminal:

```bash
curl -I http://localhost:8080/login
```

Expected Output:
```text
HTTP/1.1 200 OK
...
```

---

## Step 6: Validate Distributed Table and Shard Placement

To verify that the Citus cluster distributes data across worker nodes, create a distributed table and insert sample rows:

```bash
docker exec citus_coordinator psql -U citus -d citus -c "
CREATE TABLE companies (
    id INT PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    country VARCHAR(50)
);

SELECT create_distributed_table('companies', 'id');

INSERT INTO companies (id, name, country) VALUES
(1, 'TechCorp', 'USA'),
(2, 'InnoSoft', 'Germany'),
(3, 'CloudNet', 'Japan'),
(4, 'DataFlow', 'UK');
"
```

Now query `citus_shards` to confirm that physical shards for the `companies` table are distributed across both `worker1` and `worker2`:

```bash
docker exec citus_coordinator psql -U citus -d citus -c "
SELECT shardid, nodename, nodeport 
FROM citus_shards 
WHERE table_name::text = 'companies' 
ORDER BY shardid LIMIT 6;
"
```

Expected Output:
```text
 shardid | nodename | nodeport 
---------+----------+----------
  102008 | worker1  |     5432
  102009 | worker2  |     5432
  102010 | worker1  |     5432
  102011 | worker2  |     5432
  102012 | worker1  |     5432
  102013 | worker2  |     5432
(6 rows)
```

Confirm that rows can be queried from the coordinator:

```bash
docker exec citus_coordinator psql -U citus -d citus -c "SELECT * FROM companies ORDER BY id;"
```

---

## Conclusion

You have successfully provisioned a fully functional multi-node Citus distributed database cluster with pgAdmin 4 using Docker Compose. You verified node registration, monitored cluster state via the Citus metadata catalog, and confirmed horizontal sharding by distributing the `companies` table across worker nodes. This cluster architecture serves as the foundation for multi-tenant application integration and distributed query execution.
