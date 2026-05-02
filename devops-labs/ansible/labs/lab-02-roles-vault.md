# Lab 02: Ansible Roles, Vault, and Dynamic Inventory

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Build a reusable role, encrypt secrets with Vault, and use dynamic inventory.

---

## Part 1: Create a Reusable Role

```bash
mkdir roles-lab && cd roles-lab

# Use ansible-galaxy to scaffold the role structure
ansible-galaxy role init nginx-config

ls nginx-config/
# defaults/ files/ handlers/ meta/ tasks/ templates/ tests/ vars/

# Edit the role
cat > nginx-config/defaults/main.yml << 'EOF'
---
nginx_port: 80
nginx_worker_processes: auto
nginx_worker_connections: 1024
nginx_keepalive_timeout: 65
nginx_gzip: true
nginx_server_name: "{{ inventory_hostname }}"
nginx_document_root: /var/www/html
nginx_error_log_level: warn
nginx_ssl_enabled: false
nginx_ssl_cert: ""
nginx_ssl_key: ""
EOF

cat > nginx-config/tasks/main.yml << 'EOF'
---
- name: Install nginx
  apt:
    name: nginx
    state: present
    update_cache: yes
  tags: [install]

- name: Configure nginx
  template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
    mode: "0644"
    validate: /usr/sbin/nginx -t -c %s
  notify: Reload nginx
  tags: [configure]

- name: Configure virtual host
  template:
    src: vhost.conf.j2
    dest: "/etc/nginx/sites-available/{{ nginx_server_name }}"
  notify: Reload nginx
  tags: [configure]

- name: Enable virtual host
  file:
    src: "/etc/nginx/sites-available/{{ nginx_server_name }}"
    dest: "/etc/nginx/sites-enabled/{{ nginx_server_name }}"
    state: link
  notify: Reload nginx
  tags: [configure]

- name: Disable default site
  file:
    path: /etc/nginx/sites-enabled/default
    state: absent
  notify: Reload nginx
  tags: [configure]

- name: Start nginx
  service:
    name: nginx
    state: started
    enabled: yes
  tags: [service]
EOF

cat > nginx-config/handlers/main.yml << 'EOF'
---
- name: Reload nginx
  service:
    name: nginx
    state: reloaded

- name: Restart nginx
  service:
    name: nginx
    state: restarted
EOF

cat > nginx-config/templates/nginx.conf.j2 << 'EOF'
user www-data;
worker_processes {{ nginx_worker_processes }};
pid /run/nginx.pid;

events {
    worker_connections {{ nginx_worker_connections }};
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout {{ nginx_keepalive_timeout }};
    types_hash_max_size 2048;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    {% if nginx_gzip %}
    gzip on;
    gzip_vary on;
    gzip_min_length 1000;
    gzip_types text/plain text/css application/json application/javascript;
    {% endif %}

    error_log /var/log/nginx/error.log {{ nginx_error_log_level }};
    access_log /var/log/nginx/access.log;

    include /etc/nginx/sites-enabled/*;
}
EOF

cat > nginx-config/templates/vhost.conf.j2 << 'EOF'
server {
    listen {{ nginx_port }};
    server_name {{ nginx_server_name }};
    root {{ nginx_document_root }};
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /health {
        access_log off;
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }

    {% if nginx_ssl_enabled %}
    listen 443 ssl;
    ssl_certificate {{ nginx_ssl_cert }};
    ssl_certificate_key {{ nginx_ssl_key }};
    ssl_protocols TLSv1.2 TLSv1.3;
    {% endif %}
}
EOF
```

### Use the role in a playbook

```bash
cat > site.yml << 'EOF'
---
- name: Configure web servers
  hosts: webservers
  become: true

  roles:
  - role: nginx-config
    vars:
      nginx_port: 8080
      nginx_server_name: "mysite.example.com"
      nginx_gzip: true
      nginx_error_log_level: error

  post_tasks:
  - name: Verify website
    uri:
      url: "http://localhost:8080/health"
      status_code: 200
    register: health

  - debug:
      msg: "✅ Site health: {{ health.json }}"
EOF

ansible-playbook site.yml -i "localhost," \
  -e "ansible_connection=local" \
  --become
```

---

## Part 2: Ansible Vault

```bash
# Vault encrypts sensitive variables

# Create a vault file
ansible-vault create group_vars/all/vault.yml
# Enter vault password: myVaultPass123

# Vault file content (ansible-vault editor opens):
# db_password: SuperSecret123!
# api_key: sk-abc123def456
# smtp_password: mailPass!

# View encrypted file (notice it's base64-encoded ciphertext)
cat group_vars/all/vault.yml

# Edit encrypted file
ansible-vault edit group_vars/all/vault.yml

# Create an unencrypted companion file
mkdir -p group_vars/all
cat > group_vars/all/vars.yml << 'EOF'
db_name: myapp
db_user: appuser
db_password: "{{ vault_db_password }}"   # Reference vault variable
api_key: "{{ vault_api_key }}"
EOF

# Use vault variables in playbook
cat > deploy-app.yml << 'EOF'
---
- name: Deploy Application
  hosts: webservers
  become: true

  tasks:
  - name: Configure database connection
    template:
      src: db-config.ini.j2
      dest: /etc/myapp/db.ini
      mode: "0600"

  - name: Set API key environment variable
    lineinfile:
      path: /etc/myapp/environment
      regexp: '^API_KEY='
      line: "API_KEY={{ api_key }}"
      create: yes
      mode: "0600"
EOF

cat > db-config.ini.j2 << 'EOF'
[database]
host = {{ db_host | default('localhost') }}
name = {{ db_name }}
user = {{ db_user }}
password = {{ db_password }}
EOF

# Run with vault password
ansible-playbook deploy-app.yml \
  -i "localhost," \
  -e "ansible_connection=local" \
  --ask-vault-pass

# Or use password file (good for CI/CD)
echo "myVaultPass123" > ~/.vault-pass
chmod 600 ~/.vault-pass
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault-pass

ansible-playbook deploy-app.yml -i "localhost," -e "ansible_connection=local"
```

---

## Part 3: Dynamic Inventory (AWS)

```bash
# Dynamic inventory queries cloud APIs at runtime
# No static IP lists to maintain

# Install AWS inventory plugin
pip install boto3 botocore

# aws_ec2.yml — dynamic inventory config
cat > aws_ec2.yml << 'EOF'
plugin: amazon.aws.aws_ec2
regions:
  - us-east-1

# Filter: only running instances
filters:
  instance-state-name: running
  tag:Environment: production

# Group instances by tags
keyed_groups:
  - key: tags.Role
    prefix: role
  - key: tags.Environment
    prefix: env
  - key: instance_type
    prefix: type

# Variable mapping
hostnames:
  - private-ip-address    # Use private IP (for VPN/bastion access)

compose:
  ansible_host: private_ip_address
  ansible_user: "'ubuntu'"  # Default SSH user
EOF

# List discovered inventory
ansible-inventory -i aws_ec2.yml --list | python3 -m json.tool | head -50

# Run against dynamically discovered hosts
ansible -i aws_ec2.yml \
  role_webserver \
  -m ping

# Combine static + dynamic inventory
ansible-playbook site.yml -i "static-inventory.ini,aws_ec2.yml"
```

---

## Part 4: Playbook Testing with Molecule

```bash
# Install Molecule
pip install molecule molecule-docker

# Initialize Molecule for your role
cd nginx-config
molecule init scenario

# molecule/default/molecule.yml
cat > molecule/default/molecule.yml << 'EOF'
---
dependency:
  name: galaxy
driver:
  name: docker
platforms:
  - name: ubuntu22
    image: ubuntu:22.04
    pre_build_image: true
  - name: ubuntu20
    image: ubuntu:20.04
    pre_build_image: true
provisioner:
  name: ansible
verifier:
  name: ansible
EOF

# Write verification tests
cat > molecule/default/verify.yml << 'EOF'
---
- name: Verify nginx role
  hosts: all
  tasks:
  - name: Check nginx is installed
    package:
      name: nginx
      state: present
    check_mode: yes
    register: pkg_check
    failed_when: pkg_check.changed

  - name: Check nginx is running
    service:
      name: nginx
      state: started
    check_mode: yes
    register: svc_check
    failed_when: svc_check.changed

  - name: Check nginx responds to health check
    uri:
      url: http://localhost/health
      status_code: 200
EOF

# Run full test cycle: create → converge → verify → destroy
molecule test

# During development
molecule converge        # Just apply the role
molecule verify          # Just run tests
molecule destroy         # Just cleanup
```

---

## Cleanup

```bash
cd ../..
rm -rf roles-lab
rm -f ~/.vault-pass
```

## What You Learned

- [x] Role creation with ansible-galaxy scaffold
- [x] Role directory structure and conventions
- [x] Ansible Vault for encrypting secrets
- [x] Group vars and vault variable references
- [x] Dynamic inventory with AWS EC2 plugin
- [x] Role testing with Molecule
