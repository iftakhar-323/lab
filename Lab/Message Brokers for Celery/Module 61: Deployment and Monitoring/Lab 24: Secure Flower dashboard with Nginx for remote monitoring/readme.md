# Secure Flower Dashboard with Nginx for Remote Monitoring

You will build a secure remote monitoring setup for Celery tasks using Flower and Nginx. This architecture places the Flower dashboard behind an Nginx reverse proxy to restrict access using HTTP Basic Authentication.

![Lab 24 Architecture Overview](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/lab24-architecture.svg)

## Concept

| Term | Description |
| ---- | ----------- |
| Flower | A web-based tool for monitoring and administrating Celery clusters. |
| Nginx | A web server acting as a reverse proxy to forward client requests to internal services. |
| Reverse Proxy | A server that sits in front of backend applications and intercepts external requests. |
| HTTP Basic Authentication | A method for an HTTP user agent to provide a username and password when making a request. |

A reverse proxy acts as an intermediary for requests from clients seeking resources from servers. Instead of exposing Flower directly to the internet, Nginx intercepts incoming HTTP traffic on port 80, enforces authentication, and routes authorized requests to the internally hosted Flower service on port 5555.

## Objectives

- Build a RabbitMQ message broker service.
- Configure Flower for Celery monitoring.
- Implement an Nginx reverse proxy with Basic Authentication.
- Verify remote authenticated access to the dashboard.

## What You Will Build

You will build an environment where an Nginx server authenticates users before forwarding traffic to a local Flower instance.

```text
/
└── etc/
    └── nginx/
        ├── .flower_htpasswd
        └── sites-available/
            └── flower
```

## Step 1: Update System Packages

Run the following command:

```bash
sudo apt update
```

![Update System Packages](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(2).png)

**Explanation:**
- `sudo apt update`: Updates the package lists for upgrades and new package installations to ensure the latest versions are retrieved.

## Step 2: Install RabbitMQ

Run the following command:

```bash
sudo apt install rabbitmq-server -y
```

![Install RabbitMQ](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(3).png)

**Explanation:**
- `sudo apt install`: Uses the package manager to install a package.
- `rabbitmq-server`: The package name for the RabbitMQ message broker.
- `-y`: Automatically answers yes to installation prompts.

## Step 3: Enable and Start RabbitMQ Service

Run the following command to enable and start the service:

```bash
sudo systemctl enable --now rabbitmq-server
```

![Enable RabbitMQ Service](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(4).png)

Run the following command to verify the service status:

```bash
sudo systemctl status rabbitmq-server --no-pager
```

![Verify RabbitMQ Status](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(5).png)

Run the following command to verify the RabbitMQ port is listening:

```bash
ss -lntp | grep 5672
```

![Verify RabbitMQ Port](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(6).png)

**Explanation:**
- `sudo systemctl`: Controls the systemd system and service manager.
- `enable`: Configures the service to start automatically on system boot.
- `--now`: Immediately starts the service in addition to enabling it.
- `rabbitmq-server`: The name of the service to manage.
- `status`: Displays the current operational state of the service.
- `--no-pager`: Forces the output to display without pagination, useful for non-interactive execution.
- `ss -lntp`: Lists listening TCP ports with process information.
- `grep 5672`: Filters the output to find the default RabbitMQ port.

## Step 4: Install Flower

Run the following command to install the package:

```bash
python3 -m pip install --user flower
```

![Install Flower](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(19).png)

Run the following command to verify the installation:

```bash
python3 -m flower --version
```

![Verify Flower Version](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(18).png)

**Explanation:**
- `python3 -m pip install`: Uses the Python package installer to install a package.
- `--user`: Installs the package in the user's home directory to avoid system-wide changes.
- `flower`: The Celery monitoring tool package.
- `--version`: Displays the installed version of the tool.
- `flower`: The package name for the Celery monitoring tool.

## Step 5: Start Flower

Run the following command to start the monitoring dashboard:

```bash
python3 -m celery --broker=amqp://guest:guest@localhost:5672// flower --port=5555
```

![Start Flower](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(17).png)

Run the following command in a new terminal to verify local access:

```bash
curl -I http://localhost:5555
```

![Local Flower Test](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(7).png)

**Explanation:**
- `python3 -m celery`: Runs the Celery command-line utility via Python.
- `--broker=...`: Specifies the RabbitMQ broker URL with default guest credentials.
- `flower`: Instructs Celery to start the Flower monitoring dashboard.
- `--port=5555`: Binds the Flower service to port 5555 on the local machine.
- `curl -I ...`: Fetches the HTTP headers to verify the local service is running.

## Step 6: Install Nginx and Utilities

Run the following command:

```bash
sudo apt install nginx apache2-utils -y
```

![Install Nginx](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(8).png)

**Explanation:**
- `sudo apt install`: Uses the package manager to install packages.
- `nginx`: The web server package to act as the reverse proxy.
- `apache2-utils`: Provides the `htpasswd` utility required for generating Basic Authentication credentials.
- `-y`: Automatically accepts installation prompts.

## Step 7: Enable and Start Nginx

Run the following command to enable the service:

```bash
sudo systemctl enable --now nginx
```

![Enable Nginx Service](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(9).png)

Run the following command to verify the service status:

```bash
sudo systemctl status nginx --no-pager
```

![Verify Nginx Status](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(10).png)

**Explanation:**
- `sudo systemctl`: Controls the systemd system and service manager.
- `status`: Displays the operational status.
- `enable`: Configures the service to start automatically on system boot.
- `--now`: Immediately starts the service in addition to enabling it.
- `nginx`: The name of the web server service.

## Step 8: Generate Basic Auth Credentials

Run the following command:

```bash
sudo htpasswd -c /etc/nginx/.flower_htpasswd floweradmin
```

![Create htpasswd](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(11).png)

**Explanation:**
- `sudo htpasswd`: Executes the utility for managing HTTP Basic Authentication files.
- `-c`: Creates a new password file (overwriting if it already exists).
- `/etc/nginx/.flower_htpasswd`: The path where the credentials file will be stored.
- `floweradmin`: The username that will be granted access to the dashboard.

## Step 9: Create Nginx Server Block

Create a file named `/etc/nginx/sites-available/flower` with the following contents:

```nginx
server {
    listen 80;
    server_name _;

    location / {
        auth_basic "Flower Monitoring";
        auth_basic_user_file /etc/nginx/.flower_htpasswd;

        proxy_pass http://127.0.0.1:5555;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

![Nginx Configuration](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(12).png)

**Explanation:**
- `server { ... }`: Defines a virtual server block for handling requests.
- `listen 80;`: Instructs Nginx to listen for incoming HTTP traffic on port 80.
- `server_name _;`: Acts as a catch-all server block for any requested hostname.
- `location / { ... }`: Defines rules for all incoming requests to the root path.
- `auth_basic "Flower Monitoring";`: Enables Basic Authentication and sets the authentication realm prompt.
- `auth_basic_user_file /etc/nginx/.flower_htpasswd;`: Specifies the path to the file containing authorized usernames and passwords.
- `proxy_pass http://127.0.0.1:5555;`: Forwards authenticated requests to the internal Flower instance running on port 5555.
- `proxy_set_header ...`: Passes along original client connection details to the backend service.

## Step 10: Enable the Site and Remove Default

Run the following command:

```bash
sudo ln -s /etc/nginx/sites-available/flower /etc/nginx/sites-enabled/flower
sudo rm -f /etc/nginx/sites-enabled/default
```

**Explanation:**
- `sudo ln -s`: Creates a symbolic link to enable the new Nginx configuration.
- `/etc/nginx/sites-available/flower`: The source file containing the site configuration.
- `/etc/nginx/sites-enabled/flower`: The destination directory where Nginx looks for active sites.
- `sudo rm -f`: Forcefully removes a file without prompting.
- `/etc/nginx/sites-enabled/default`: The default Nginx configuration file being removed to prevent conflicts.

## Step 11: Test Nginx Configuration

Run the following command:

```bash
sudo nginx -t
```

![Enable Site and Test Config](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(13).png)

**Explanation:**
- `sudo nginx`: Executes the Nginx web server binary.
- `-t`: Tests the configuration file syntax and verifies its validity without starting the server.

## Step 12: Reload Nginx

Run the following command:

```bash
sudo systemctl reload nginx
```

**Explanation:**
- `sudo systemctl`: Controls the systemd system and service manager.
- `reload`: Instructs the service manager to reload the configuration gracefully without dropping connections.
- `nginx`: The target service to be reloaded.

## Verification

Run the following commands to verify that Nginx properly handles unauthenticated and authenticated requests.

1. Test unauthenticated access by running the following command:
```bash
curl -I http://localhost
```
Expected output:
```text
HTTP/1.1 401 Unauthorized
Server: nginx/1.18.0 (Ubuntu)
Date: Wed, 01 Jan 2025 00:00:00 GMT
Content-Type: text/html
Content-Length: 188
Connection: keep-alive
WWW-Authenticate: Basic realm="Flower Monitoring"
```

![Reload and Unauthenticated Test](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(14).png)

2. Test authenticated access by running the following command:
```bash
curl -u floweradmin http://localhost
```
Expected output:
```text
Enter host password for user 'floweradmin':
<!DOCTYPE html>
<html lang="en">
<head>
    <title>Flower</title>
...
```

![Authenticated Flower Access](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(15).png)

3. Confirm Nginx is listening on port 80 by running the following command:
```bash
sudo ss -lntp | grep nginx
```
Expected output:
```text
LISTEN 0      511          0.0.0.0:80        0.0.0.0:*    users:(("nginx",pid=12345,fd=6))
```

4. Retrieve the server IP to access the Flower dashboard from your web browser:
```bash
hostname -I
```
Expected output:
```text
192.168.1.100
```

![Nginx Port and Server IP](https://raw.githubusercontent.com/iftakhar-323/lab-assets/main/lab24/Pasted%20image%20(16).png)

*(Note: To access the Flower dashboard remotely, open `http://<your-server-ip>/` in your browser. When prompted, enter the username `floweradmin` and the password you generated.)*

| # | Call | Status | Body snippet |
| - | ---- | ------ | ------------ |
| 1 | `curl -I http://localhost` | 401 | `HTTP/1.1 401 Unauthorized` |
| 2 | `curl -u floweradmin http://localhost` | 200 | `<title>Flower</title>` |

## Conclusion

You built a secure monitoring infrastructure by installing RabbitMQ and Flower, and configuring Nginx as a reverse proxy. The environment successfully restricts external dashboard access using HTTP Basic Authentication while ensuring internal task monitoring remains operational.
