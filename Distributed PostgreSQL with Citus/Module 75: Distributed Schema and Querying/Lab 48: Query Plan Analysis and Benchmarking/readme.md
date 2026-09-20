# Lab 48: Query Plan Analysis and Benchmarking

In this lab, you will analyze distributed query execution plans in Citus using `EXPLAIN` and run a multi-threaded load test to benchmark write throughput. You will deploy a 3-node Citus cluster (1 Coordinator + 2 Workers) using Docker Compose in your Poridhi environment. You will then observe how the Citus coordinator optimizes routed queries versus scatter-gather queries, and measure concurrent insert performance across multiple shards.

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/architecture_diagram.svg?v=7" alt="Citus Query Planning and Benchmarking Architecture" width="750">
</p>

---

## Objectives

- Deploy a 3-node Citus cluster (1 Coordinator + 2 Workers) using Docker Compose.
- Configure a Python virtual environment with SQLAlchemy and psycopg2-binary.
- Initialize distributed tables (`orders` sharded by `tenant_id`) and reference tables (`products`).
- Use `EXPLAIN` to compare single-tenant routed plans against multi-tenant scatter-gather plans.
- Run a high-concurrency Python benchmark with `ThreadPoolExecutor` measuring write throughput (inserts/second).

---

## Project Structure

```text
citus-benchmark-lab/
├── citus/
│   └── docker-compose.yml
└── app/
    ├── requirements.txt
    └── benchmark.py
```

---

## Step 1: Deploy Citus Cluster using Docker Compose

Create a dedicated workspace directory for the cluster configuration:

```bash
mkdir -p ~/citus-benchmark-lab/citus
cd ~/citus-benchmark-lab/citus
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/01_mkdir_citus.png" alt="Create Citus Benchmark Directory" width="700">
</p>

Create `docker-compose.yml`:

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
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/02_create_docker_compose.png" alt="Create docker-compose.yml" width="700">
</p>

Start all three containers in detached mode:

```bash
docker compose up -d || docker-compose up -d
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/03_docker_compose_up.png" alt="Start Citus Containers" width="700">
</p>

Verify that all three containers are healthy:

```bash
docker compose ps
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/04_docker_compose_ps.png" alt="Verify Citus Containers" width="700">
</p>

Wait 10 seconds for PostgreSQL instances to initialize, then register both worker nodes with the Citus coordinator:

```bash
sleep 10
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker1', 5432);"
docker exec citus_coordinator psql -U citus -d citus -c "SELECT citus_add_node('worker2', 5432);"
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/05_citus_add_nodes.png" alt="Register Citus Worker Nodes" width="700">
</p>

Confirm worker node registration:

```bash
docker exec citus_coordinator psql -U citus -d citus -c "SELECT nodename, nodeport, isactive FROM pg_dist_node;"
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/06_citus_active_workers.png" alt="Confirm Citus Active Workers" width="700">
</p>

---

## Step 2: Set Up Python Application Environment

Create the application directory:

```bash
mkdir -p ~/citus-benchmark-lab/app
cd ~/citus-benchmark-lab/app
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/07_mkdir_app.png" alt="Create App Directory" width="700">
</p>

Create and activate a virtual environment:

```bash
python3 -m venv venv
source venv/bin/activate
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/08_setup_app_venv.png" alt="Setup App Virtual Environment" width="700">
</p>

Create `requirements.txt` and install dependencies:

```bash
cat << 'EOF' > requirements.txt
psycopg2-binary==2.9.9
SQLAlchemy==2.0.23
EOF

pip install -r requirements.txt
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/09_create_requirements.png" alt="Create requirements.txt" width="700">
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/10_pip_install.png" alt="Install Python Dependencies" width="700">
</p>

---

## Step 3: Create the Benchmark and Query Plan Script

Create `benchmark.py`:

```bash
cat << 'EOF' > benchmark.py
import os
import time
import concurrent.futures
from sqlalchemy import create_engine, text

COORDINATOR_IP = os.environ.get("COORDINATOR_IP", "127.0.0.1")
DATABASE_URL = f"postgresql://citus:citus_password@{COORDINATOR_IP}:5432/citus"

engine = create_engine(DATABASE_URL, pool_size=25, max_overflow=10)

def setup_schema():
    """Initializes tables and configures distributed sharding."""
    print("Setting up database schema...")
    with engine.connect() as conn:
        conn.execute(text("DROP TABLE IF EXISTS orders CASCADE;"))
        conn.execute(text("DROP TABLE IF EXISTS products CASCADE;"))
        conn.commit()

        # Create physical tables
        conn.execute(text("""
            CREATE TABLE products (
                id INT PRIMARY KEY,
                name VARCHAR(100),
                price NUMERIC(10, 2)
            );
        """))
        conn.execute(text("""
            CREATE TABLE orders (
                id SERIAL,
                tenant_id INT,
                product_id INT,
                quantity INT,
                PRIMARY KEY (tenant_id, id)
            );
        """))
        conn.commit()

        # 1. Reference Table (Duplicated on all workers)
        conn.execute(text("SELECT create_reference_table('products');"))
        conn.commit()
        print("  - 'products' table replicated as Reference Table.")

        # 2. Distributed Table (Sharded by tenant_id)
        conn.execute(text("SELECT create_distributed_table('orders', 'tenant_id');"))
        conn.commit()
        print("  - 'orders' table sharded by 'tenant_id'.")

        # Insert seed product
        conn.execute(text("INSERT INTO products (id, name, price) VALUES (1, 'Cloud Server', 99.00);"))
        conn.commit()
        print("Schema setup completed successfully.\n")

def run_explain_plans():
    """Runs EXPLAIN on single-tenant vs multi-tenant queries."""
    print("=" * 60)
    print("1. QUERY PLAN ANALYSIS (EXPLAIN)")
    print("=" * 60)

    with engine.connect() as conn:
        # 1. Single-tenant query (Direct shard routing)
        print("\n[A] Single-Tenant Query Plan (WHERE tenant_id = 501):")
        result = conn.execute(text("EXPLAIN SELECT * FROM orders WHERE tenant_id = 501;"))
        for row in result:
            print("  ", row[0])

        # 2. Cross-tenant query (Scatter-Gather across all worker shards)
        print("\n[B] Global Query Plan without Distribution Key (Scatter-Gather):")
        result = conn.execute(text("EXPLAIN SELECT COUNT(*) FROM orders;"))
        for row in result:
            print("  ", row[0])

def insert_single_order(tenant_id):
    """Inserts a single order for a given tenant."""
    with engine.connect() as conn:
        conn.execute(
            text("INSERT INTO orders (tenant_id, product_id, quantity) VALUES (:t, 1, 2);"),
            {"t": tenant_id}
        )
        conn.commit()

def run_concurrency_benchmark(total_inserts=1000, concurrency=20):
    """Benchmarks concurrent multi-tenant inserts using a thread pool."""
    print("\n" + "=" * 60)
    print(f"2. WRITE CONCURRENCY BENCHMARK ({total_inserts} Inserts, {concurrency} Workers)")
    print("=" * 60)

    start_time = time.time()

    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as executor:
        # Distribute inserts across 10 distinct tenant IDs (0 to 9)
        futures = [executor.submit(insert_single_order, i % 10) for i in range(total_inserts)]
        for f in concurrent.futures.as_completed(futures):
            f.result()

    duration = time.time() - start_time
    throughput = total_inserts / duration

    print(f"Total Inserts:  {total_inserts}")
    print(f"Execution Time: {duration:.2f} seconds")
    print(f"Throughput:     {throughput:.2f} inserts/second")
    print("=" * 60 + "\n")

if __name__ == '__main__':
    setup_schema()
    run_explain_plans()
    run_concurrency_benchmark(total_inserts=1000, concurrency=20)
EOF
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/11_create_benchmark_py.png" alt="Create benchmark.py" width="700">
</p>

---

## Step 4: Run Query Plan Analysis and Benchmark

Execute the benchmarking script:

```bash
python3 benchmark.py
```

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/12_run_benchmark_explain.png" alt="Run Benchmark Script - EXPLAIN Query Plan" width="700">
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/Distributed%20PostgreSQL%20with%20Citus/Module%2075:%20Distributed%20Schema%20and%20Querying/Lab%2048:%20Query%20Plan%20Analysis%20and%20Benchmarking/images/13_run_benchmark_concurrency.png" alt="Run Benchmark Script - Concurrency Benchmark" width="700">
</p>

### Expected Output

```text
Setting up database schema...
  - 'products' table replicated as Reference Table.
  - 'orders' table sharded by 'tenant_id'.
Schema setup completed successfully.

============================================================
1. QUERY PLAN ANALYSIS (EXPLAIN)
============================================================

[A] Single-Tenant Query Plan (WHERE tenant_id = 501):
   Custom Scan (Citus Adaptive)  (cost=0.00..0.00 rows=0 width=0)
     Task Count: 1
     Tasks Shown: All
     ->  Task
           Node: host=worker2 port=5432 dbname=citus
           ->  Bitmap Heap Scan on orders_102059 orders  (cost=4.22..14...

[B] Global Query Plan without Distribution Key (Scatter-Gather):
   Aggregate  (cost=250.00..250.02 rows=1 width=8)
     ->  Custom Scan (Citus Adaptive)  (cost=0.00..0.00 rows=100000 width=8)
           Task Count: 32
           Tasks Shown: One of 32
           ->  Task
                 Node: host=worker1 port=5432 dbname=citus
                 ->  Aggregate  (cost=33.12..33.13 rows=1 width=8)
                       ->  Seq Scan on orders_102042 orders  (cost=0.00..28.50 rows=1850 width=0)

============================================================
2. WRITE CONCURRENCY BENCHMARK (1000 Inserts, 20 Workers)
============================================================
Total Inserts:  1000
Execution Time: 1.79 seconds
Throughput:     560.15 inserts/second
============================================================
```

### Plan Interpretation

1. **`Task Count: 1` (Single-Tenant Route)**: When `tenant_id` is specified in the `WHERE` clause, Citus calculates the shard hash immediately and routes the query directly to the worker holding that specific shard (`Task Count: 1`). The other worker nodes are not contacted, keeping resource usage minimal.
2. **`Task Count: 32` (Scatter-Gather)**: When querying across all tenants without specifying `tenant_id` (such as `SELECT COUNT(*)`), Citus must contact all 32 shards across both worker nodes in parallel and aggregate the partial results on the coordinator.
3. **Write Concurrency**: Because the 1,000 inserts span 10 different tenants (`i % 10`), writes execute in parallel across different worker shards without locking bottlenecks.

---

## Conclusion

You have successfully analyzed Citus distributed execution plans and benchmarked concurrent write throughput. Using `EXPLAIN`, you verified that tenant-specific queries route to a single shard with `Task Count: 1`, while global queries execute via parallel scatter-gather tasks across the cluster. Finally, your concurrency benchmark confirmed that distributing writes across shards enables high insertion throughput.
