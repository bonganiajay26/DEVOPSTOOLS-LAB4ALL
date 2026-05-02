# Lab 01: Your First Ansible Playbook

**Difficulty**: Beginner | **Time**: 45 minutes  
**Goal**: Install and configure nginx on multiple servers using Ansible.

---

## Setup: Local Test Environment with Docker

```bash
# Use Docker to simulate multiple servers (no cloud needed)
mkdir ansible-lab && cd ansible-lab

# Docker Compose: 3 Ubuntu servers
cat > docker-compose.yml << 'EOF'
services:
  server1:
    image: ubuntu:22.04
    hostname: server1
    command: /usr/sbin/sshd -D
    ports:
      - "2221:22"
    volumes:
      - ./ssh:/root/.ssh:ro
    environment:
      ROOT_PASSWORD: ansible123

  server2:
    image: ubuntu:22.04
    hostname: server2
    command: /usr/sbin/sshd -D
    ports:
      - "2222:22"
    volumes:
      - ./ssh:/root/.ssh:ro

  server3:
    image: ubuntu:22.04
    hostname: server3
    command: /usr/sbin/sshd -D
    ports:
      - "2223:22"
    volumes:
      - ./ssh:/root/.ssh:ro
EOF

# Generate SSH key pair for Ansible
mkdir ssh
ssh-keygen -t ed25519 -f ssh/id_ed25519 -N ""
cp ssh/id_ed25519.pub ssh/authorized_keys

# Build custom image with SSH
cat > Dockerfile.server << 'EOF'
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y openssh-server python3 && \
    mkdir /var/run/sshd && \
    echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D"]
EOF

# Or use an existing SSH-enabled image
# docker run -d --name server1 -p 2221:22 rastasheep/ubuntu-sshd:22.04
```

### Simpler: Use local hosts for this lab

```bash
# If you have sudo access on your machine, test against localhost:
cat > inventory.ini << 'EOF'
[local]
localhost ansible_connection=local

[webservers]
localhost ansible_connection=local
EOF

# Test connection
ansible all -i inventory.ini -m ping
# localhost | SUCCESS => {"ping": "pong"}
```

---

## Part 1: Ad-Hoc Commands

```bash
# First: test Ansible is installed
ansible --version

# Run commands on all hosts
ansible all -i inventory.ini -m ping

# Run a shell command
ansible all -i inventory.ini -m command -a "uname -a"

# Gather facts (system information)
ansible all -i inventory.ini -m setup | head -50

# Check specific facts
ansible all -i inventory.ini -m setup -a "filter=ansible_distribution*"

# Install a package (requires become: true / --become)
ansible webservers -i inventory.ini \
  -m apt \
  -a "name=tree state=present" \
  --become

# Get file content
ansible all -i inventory.ini \
  -m command \
  -a "cat /etc/os-release"
```

---

## Part 2: Your First Playbook

```bash
cat > install-nginx.yml << 'EOF'
---
- name: Install and Configure Nginx
  hosts: webservers
  become: true                  # Run as root (sudo)
  gather_facts: true            # Collect system info first

  vars:
    nginx_port: 80
    site_name: "My Website"

  tasks:
  # Task 1: Update package cache
  - name: Update apt package cache
    apt:
      update_cache: yes
      cache_valid_time: 3600    # Only update if older than 1 hour

  # Task 2: Install nginx
  - name: Install nginx
    apt:
      name: nginx
      state: present            # 'present' = install if not there

  # Task 3: Create custom index page
  - name: Create custom index.html
    copy:
      content: |
        <!DOCTYPE html>
        <html>
        <head><title>{{ site_name }}</title></head>
        <body>
          <h1>Welcome to {{ site_name }}</h1>
          <p>Served by: {{ inventory_hostname }}</p>
          <p>OS: {{ ansible_distribution }} {{ ansible_distribution_version }}</p>
          <p>IP: {{ ansible_default_ipv4.address | default('N/A') }}</p>
        </body>
        </html>
      dest: /var/www/html/index.html
      mode: "0644"

  # Task 4: Configure firewall (UFW)
  - name: Allow nginx through firewall
    ufw:
      rule: allow
      name: Nginx

  # Task 5: Start and enable nginx
  - name: Ensure nginx is started and enabled
    service:
      name: nginx
      state: started
      enabled: yes

  # Task 6: Verify it's running
  - name: Wait for nginx to be accessible
    uri:
      url: "http://localhost:{{ nginx_port }}"
      status_code: 200
    register: result
    retries: 5
    delay: 2
    until: result.status == 200

  - name: Show success message
    debug:
      msg: "✅ Nginx is running! URL: http://{{ inventory_hostname }}:{{ nginx_port }}"
EOF
```

### Run the playbook

```bash
# Dry run first (--check shows what WOULD happen)
ansible-playbook install-nginx.yml -i inventory.ini --check --diff

# Run for real
ansible-playbook install-nginx.yml -i inventory.ini

# Verify
curl http://localhost
```

---

## Part 3: Idempotency — Run Twice

```bash
# Run the SAME playbook again
ansible-playbook install-nginx.yml -i inventory.ini

# Notice:
# - "Update apt cache"    → changed (valid cache time passed)
# - "Install nginx"       → ok (already installed, no change)
# - "Create index.html"   → ok (file unchanged)
# - "Start nginx"         → ok (already running)
#
# Result: 0 changes! This is idempotency — safe to run repeatedly.
```

---

## Part 4: Add a Handler

```bash
cat > install-nginx-v2.yml << 'EOF'
---
- name: Configure Nginx with Handler
  hosts: webservers
  become: true

  tasks:
  - name: Install nginx
    apt:
      name: nginx
      state: present

  - name: Update nginx configuration
    template:
      src: nginx.conf.j2
      dest: /etc/nginx/nginx.conf
      validate: /usr/sbin/nginx -t -c %s    # Validate before applying
    notify: Reload nginx                     # Only reload if config changed

  - name: Start nginx
    service:
      name: nginx
      state: started
      enabled: yes

  handlers:
  # Only runs if "Update nginx configuration" task changed
  - name: Reload nginx
    service:
      name: nginx
      state: reloaded    # Graceful reload (no downtime)
EOF

# Create the template
cat > nginx.conf.j2 << 'EOF'
events { worker_connections 1024; }

http {
    server {
        listen {{ nginx_port | default(80) }};
        server_name {{ inventory_hostname }};

        location / {
            root /var/www/html;
            index index.html;
        }

        location /health {
            return 200 '{"status":"ok","host":"{{ inventory_hostname }}"}';
            add_header Content-Type application/json;
        }
    }
}
EOF

ansible-playbook install-nginx-v2.yml -i inventory.ini

# Change the template and run again — handler fires!
echo "    # updated" >> nginx.conf.j2
ansible-playbook install-nginx-v2.yml -i inventory.ini
# RUNNING HANDLER: Reload nginx  ← only when config changed
```

---

## Cleanup

```bash
# Uninstall nginx
cat > cleanup.yml << 'EOF'
---
- name: Cleanup
  hosts: webservers
  become: true
  tasks:
  - name: Remove nginx
    apt:
      name: nginx
      state: absent
      purge: yes
  - name: Remove nginx data
    file:
      path: /var/www/html/index.html
      state: absent
EOF

ansible-playbook cleanup.yml -i inventory.ini
cd ..
rm -rf ansible-lab
```

## What You Learned

- [x] Ansible ad-hoc commands for quick tasks
- [x] Playbook structure: hosts, become, tasks
- [x] Core modules: apt, copy, service, uri
- [x] Jinja2 templates with `template` module
- [x] Handlers for conditional restarts
- [x] Idempotency — same result every run
