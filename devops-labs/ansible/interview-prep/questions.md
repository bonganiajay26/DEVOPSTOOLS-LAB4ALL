# Ansible Interview Questions

## Q1. What is idempotency and why does it matter in Ansible?

Idempotency means running a playbook N times produces the same result as running it once. No unintended side effects.

```yaml
# Idempotent — runs 100x, always same result
- name: Install nginx
  apt:
    name: nginx
    state: present     # "present" checks first, installs only if missing

# NOT idempotent — appends every run!
- name: Add to file
  command: echo "config=true" >> /etc/app.conf
  # Use lineinfile or blockinfile instead:
- name: Add config (idempotent)
  lineinfile:
    path: /etc/app.conf
    line: "config=true"
    state: present
```

---

## Q2. Explain Ansible inventory. What is dynamic inventory?

**Static inventory:**
```ini
# inventory.ini
[webservers]
web1.company.com ansible_user=ubuntu
web2.company.com
10.0.1.50 ansible_port=2222

[databases]
db1.company.com ansible_user=ec2-user

[production:children]   # Group of groups
webservers
databases

[webservers:vars]
ansible_user=ubuntu
ansible_python_interpreter=/usr/bin/python3
```

**Dynamic inventory** — query cloud API at runtime:
```bash
# AWS dynamic inventory
pip install boto3
ansible-inventory -i aws_ec2.yml --list   # Shows all EC2 instances

# aws_ec2.yml
plugin: amazon.aws.aws_ec2
regions: [us-east-1]
filters:
  instance-state-name: running
  tag:Environment: production
keyed_groups:
  - key: tags.Role
    prefix: role
# Creates groups: role_webserver, role_database, etc.
```

---

## Q3. What is the difference between a role and a playbook?

**Playbook**: Sequence of tasks, can be complex and long.
**Role**: Reusable, structured unit with standardized directory layout. Roles are the correct way to package and share automation.

```
roles/nginx/
├── tasks/main.yml       # The tasks
├── handlers/main.yml    # Handlers triggered by tasks
├── defaults/main.yml    # Default variables (lowest priority)
├── vars/main.yml        # Variables (high priority)
├── templates/           # Jinja2 templates
├── files/               # Static files
├── meta/main.yml        # Role metadata, dependencies
└── README.md

# Use in playbook:
- hosts: webservers
  roles:
  - nginx
  - { role: nodejs, nodejs_version: "20" }
  - common                 # Applied to all servers
```

---

## Q4. How does Ansible handle secrets?

```bash
# Ansible Vault — encrypt sensitive files
ansible-vault create secrets.yml
ansible-vault encrypt existing-secrets.yml
ansible-vault edit secrets.yml
ansible-vault view secrets.yml

# Encrypt single variable
ansible-vault encrypt_string 'my-password' --name 'db_password'
# Output:
# db_password: !vault |
#   $ANSIBLE_VAULT;1.1;AES256
#   6135623...

# Run with vault password
ansible-playbook site.yml --vault-password-file ~/.vault-pass
ansible-playbook site.yml --ask-vault-pass
export ANSIBLE_VAULT_PASSWORD_FILE=~/.vault-pass

# Multiple vault IDs (dev/prod different keys)
ansible-playbook site.yml \
  --vault-id dev@~/.vault-pass-dev \
  --vault-id prod@~/.vault-pass-prod
```

---

## Q5. What are handlers and when do you use them?

Handlers are tasks that run only when notified, and only once even if notified multiple times.

```yaml
tasks:
- name: Update nginx config
  template:
    src: nginx.conf.j2
    dest: /etc/nginx/nginx.conf
  notify: Reload nginx      # Triggers handler if config changed

- name: Install SSL cert
  copy:
    src: cert.pem
    dest: /etc/nginx/ssl/cert.pem
  notify: Reload nginx      # Also triggers — but handler runs ONCE at end

handlers:
- name: Reload nginx
  service:
    name: nginx
    state: reloaded          # graceful reload, not restart

# Force handlers to run immediately (not at end of play):
- meta: flush_handlers
```

---

## Q6. How do you run tasks only on specific hosts or skip in certain conditions?

```yaml
tasks:
# when: conditional execution
- name: Install SELinux tools
  yum:
    name: libselinux-python
  when: ansible_os_family == "RedHat"

- name: Check if service exists
  stat:
    path: /etc/systemd/system/myapp.service
  register: service_file

- name: Start service only if it exists
  service:
    name: myapp
    state: started
  when: service_file.stat.exists

# delegate_to: run task on different host
- name: Remove from load balancer
  shell: haproxy_remove.sh {{ inventory_hostname }}
  delegate_to: loadbalancer.company.com

# run_once: run only once even across many hosts
- name: Create database schema
  command: python manage.py migrate
  run_once: true
  delegate_to: "{{ groups['webservers'][0] }}"
```

---

## Q7. What is `register` and `debug` used for?

```yaml
# register: capture task output
- name: Check disk usage
  command: df -h /
  register: disk_output

- name: Show disk usage
  debug:
    var: disk_output.stdout_lines

- name: Fail if disk over 80%
  fail:
    msg: "Disk usage critical!"
  when: '"8" in disk_output.stdout or "9" in disk_output.stdout'

# Common registered variables:
# result.rc          = return code (0 = success)
# result.stdout      = standard output
# result.stderr      = standard error
# result.changed     = whether task made change
# result.stdout_lines = list of output lines
```

---

## Q8. How do you run Ansible in CI/CD pipelines?

```yaml
# .github/workflows/ansible.yml
- name: Run Ansible playbook
  uses: dawidd6/action-ansible-playbook@v2
  with:
    playbook: site.yml
    directory: ./ansible
    key: ${{ secrets.SSH_PRIVATE_KEY }}
    inventory: |
      [webservers]
      ${{ secrets.PROD_SERVER_IP }}
    options: |
      --extra-vars "env=production app_version=${{ github.sha }}"
      --vault-password-file /dev/stdin

# For AWS SSM (no SSH needed!):
# Use ansible-pylibssh with aws_ssm connection plugin
# Connection type: community.aws.aws_ssm
```

---

## Q9. What is the difference between `copy`, `template`, and `file` modules?

```yaml
# copy: copy static file from control node to remote
- copy:
    src: files/nginx.conf     # No variables, exact copy
    dest: /etc/nginx/nginx.conf

# template: render Jinja2 template with variables
- template:
    src: templates/nginx.conf.j2   # Contains {{ variables }}
    dest: /etc/nginx/nginx.conf

# file: manage file/directory metadata (permissions, ownership, symlinks)
- file:
    path: /etc/app/config
    state: directory             # Create directory
    mode: "0755"
    owner: appuser
    group: appuser

- file:
    src: /etc/nginx/sites-available/myapp
    dest: /etc/nginx/sites-enabled/myapp
    state: link                  # Create symlink
```

---

## Q10. How do you use Ansible with Terraform (or other IaC tools)?

```bash
# Pattern 1: Terraform creates VMs, outputs IPs, Ansible configures them
# terraform output -json | python3 scripts/generate-inventory.py

# Pattern 2: Terraform null_resource calls Ansible after provisioning
resource "null_resource" "configure" {
  provisioner "local-exec" {
    command = "ansible-playbook -i '${self.triggers.ip},' --private-key ${var.key_path} site.yml"
    environment = {
      ANSIBLE_HOST_KEY_CHECKING = "False"
    }
  }
  triggers = {
    ip = aws_instance.web.public_ip
  }
}

# Pattern 3: Use Ansible dynamic inventory to query Terraform state
# terraform-inventory plugin reads terraform.tfstate
```

---

## Q11. What is `ansible-lint` and why should you use it?

```bash
# ansible-lint: static analysis for playbooks
pip install ansible-lint
ansible-lint playbooks/site.yml

# Common rules checked:
# - risky-file-permissions: mode should be quoted string "0644"
# - no-changed-when: command module should have changed_when
# - command-instead-of-module: use yum/apt instead of command to install
# - yaml[truthy]: use true/false not yes/no

# Fix automatically where possible:
ansible-lint --fix playbooks/site.yml

# In CI:
- name: Lint Ansible playbooks
  run: |
    pip install ansible ansible-lint
    ansible-lint playbooks/
```

---

## Q12. How do you implement zero-downtime deployments with Ansible?

```yaml
- name: Rolling deploy to web servers
  hosts: webservers
  serial: 1                          # Deploy to ONE server at a time
  max_fail_percentage: 0             # Stop if any server fails

  pre_tasks:
  - name: Remove from load balancer
    delegate_to: haproxy.internal
    command: haproxy_disable.sh {{ inventory_hostname }}

  tasks:
  - name: Pull new Docker image
    docker_image:
      name: myapp:{{ app_version }}
      source: pull

  - name: Stop current container
    docker_container:
      name: myapp
      state: stopped

  - name: Start new container
    docker_container:
      name: myapp
      image: myapp:{{ app_version }}
      state: started
      restart_policy: unless-stopped

  - name: Wait for health check
    uri:
      url: http://localhost:8080/health
      status_code: 200
    register: result
    retries: 10
    delay: 5
    until: result.status == 200

  post_tasks:
  - name: Add back to load balancer
    delegate_to: haproxy.internal
    command: haproxy_enable.sh {{ inventory_hostname }}
```

---

## Q13. What are Ansible facts and how do you use them?

```yaml
# Facts = system information gathered at playbook start
# Access via: ansible_facts.* or ansible_*

- debug:
    msg: >
      OS: {{ ansible_distribution }} {{ ansible_distribution_version }}
      Arch: {{ ansible_architecture }}
      Memory: {{ ansible_memtotal_mb }} MB
      Kernel: {{ ansible_kernel }}
      IP: {{ ansible_default_ipv4.address }}

# Conditionals based on facts:
- name: Install apache (distro-specific)
  package:
    name: "{{ 'apache2' if ansible_os_family == 'Debian' else 'httpd' }}"
    state: present

# Custom facts — create /etc/ansible/facts.d/myapp.fact on remote
# Content: [myapp]\nversion=2.1.0
# Access: ansible_local.myapp.myapp.version

# Speed up: skip fact gathering if not needed
- hosts: all
  gather_facts: false               # Skip for simple tasks
```

---

## Q14. How do you test Ansible roles?

```bash
# Molecule — testing framework for Ansible roles
pip install molecule molecule-docker

# Initialize
cd roles/nginx
molecule init scenario

# molecule/default/molecule.yml
---
driver:
  name: docker
platforms:
- name: ubuntu22
  image: ubuntu:22.04
  pre_build_image: true
- name: centos9
  image: centos:9
  pre_build_image: true

# molecule/default/verify.yml
- name: Verify nginx
  hosts: all
  tasks:
  - name: Check nginx is running
    service_facts:
  - assert:
      that: ansible_facts.services['nginx'].state == 'running'

# Run tests
molecule test         # Full test: create → converge → verify → destroy
molecule converge     # Just apply the role (for development)
molecule verify       # Just run assertions
```

---

## Q15. Ansible playbook is running very slowly. How do you optimize it?

```ini
# ansible.cfg optimizations
[defaults]
# Parallel execution (default is 5)
forks = 20

# SSH pipelining (reduces SSH connections)
pipelining = True

# Connection persistence (reuse SSH connections)
[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True

# Strategy: free (don't wait for all hosts before next task)
[defaults]
strategy = free           # Default is 'linear' (waits for all hosts)
```

```yaml
# In playbook:
- hosts: all
  strategy: free           # Each host advances independently
  gather_facts: false       # Skip if you don't need facts
  tasks:
  - name: Async long-running task
    command: ./long-script.sh
    async: 300             # Max 300 seconds
    poll: 0                # Fire and forget (don't wait)
    register: async_job

  - name: Check async job
    async_status:
      jid: "{{ async_job.ansible_job_id }}"
    register: result
    until: result.finished
    retries: 30
    delay: 10
```
