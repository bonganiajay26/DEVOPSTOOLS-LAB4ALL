# Ansible Core Concepts

## Architecture

```
Control Node (your machine or CI/CD server)
      │
      │  SSH / WinRM (agentless)
      │
 ─────┼────────────────────────────
 │    │    │         │             │
Host1 Host2 Host3  Host4         Host5
(Ubuntu) (CentOS) (Ubuntu) (Windows) (Docker)
```

**Key principle**: Ansible is **agentless**. It uses SSH to connect and runs Python modules remotely. No daemon to install or maintain on managed hosts.

---

## Inventory

The inventory defines what Ansible manages.

```ini
# inventory.ini — static inventory

# Individual hosts
web1.company.com ansible_user=ubuntu
10.0.1.50 ansible_user=ec2-user ansible_port=2222

# Groups
[webservers]
web1.company.com
web2.company.com

[databases]
db1.company.com
db2.company.com

# Group of groups
[production:children]
webservers
databases

# Group variables
[webservers:vars]
ansible_user=ubuntu
ansible_python_interpreter=/usr/bin/python3

[databases:vars]
ansible_user=postgres
db_port=5432
```

```yaml
# inventory.yml — YAML format (more readable)
all:
  children:
    production:
      children:
        webservers:
          hosts:
            web1.company.com:
              ansible_user: ubuntu
            web2.company.com:
              ansible_user: ubuntu
          vars:
            http_port: 80
        databases:
          hosts:
            db1.company.com:
              ansible_user: postgres
```

---

## Playbook Anatomy

```yaml
---
# Playbook = list of plays
- name: Configure Web Servers         # Play name
  hosts: webservers                    # Which inventory group
  become: true                         # sudo
  gather_facts: true                   # Collect system info
  vars:
    nginx_version: "1.25"

  pre_tasks:                           # Run before tasks
  - name: Update apt cache
    apt:
      update_cache: yes
      cache_valid_time: 3600

  tasks:                               # Main tasks
  - name: Install nginx
    apt:
      name: nginx={{ nginx_version }}
      state: present

  - name: Copy nginx config
    template:
      src: nginx.conf.j2
      dest: /etc/nginx/nginx.conf
    notify: Reload nginx               # Trigger handler on change

  - name: Start nginx
    service:
      name: nginx
      state: started
      enabled: yes

  post_tasks:                          # Run after all tasks
  - name: Verify nginx is running
    uri:
      url: http://localhost
      status_code: 200

  handlers:                            # Only run when notified
  - name: Reload nginx
    service:
      name: nginx
      state: reloaded
```

---

## Variables Priority (lowest to highest)

```
1. role defaults  (roles/myrole/defaults/main.yml)
2. inventory vars (group_vars/, host_vars/)
3. playbook vars  (vars: in playbook)
4. host facts     (gathered with gather_facts)
5. registered vars (register:)
6. command line   (ansible-playbook -e "var=value")
7. connection vars (ansible_user, etc.)
```

---

## Jinja2 Templating

```yaml
# Variable substitution
- name: Print hostname
  debug:
    msg: "Running on {{ inventory_hostname }}"

# Conditionals
- name: Install on Debian
  apt:
    name: nginx
  when: ansible_os_family == "Debian"

# Filters
- debug:
    msg: |
      Upper: {{ 'hello' | upper }}
      Default: {{ undefined_var | default('fallback') }}
      Dict keys: {{ mydict | dict2items | map(attribute='key') | list }}
      Last: {{ mylist | last }}
      Combine: {{ dict1 | combine(dict2) }}
      Regex: {{ 'foo123' | regex_replace('[0-9]+', 'NUM') }}

# Loop with filters
- name: Create users
  user:
    name: "{{ item.name }}"
    uid:  "{{ item.uid }}"
    groups: "{{ item.groups | join(',') }}"
  loop:
    - { name: alice, uid: 1001, groups: [sudo, docker] }
    - { name: bob,   uid: 1002, groups: [docker] }
```

---

## Roles Structure

```
roles/
  my-role/
    tasks/
      main.yml        # Main task list
      install.yml     # Called from main.yml
      configure.yml
    handlers/
      main.yml        # Handlers
    defaults/
      main.yml        # Default variables (lowest priority)
    vars/
      main.yml        # Role variables (higher priority)
    templates/
      nginx.conf.j2   # Jinja2 templates
    files/
      index.html      # Static files
    meta/
      main.yml        # Role metadata + dependencies
    tests/
      inventory
      test.yml        # Role tests (Molecule)
    README.md
```

```yaml
# meta/main.yml — declare dependencies
dependencies:
  - role: geerlingguy.nginx
    vars:
      nginx_vhost_template: "vhosts.j2"
  - role: geerlingguy.certbot
    when: use_ssl | default(false)
```

---

## Ansible Galaxy

```bash
# Install community roles
ansible-galaxy install geerlingguy.nginx
ansible-galaxy install -r requirements.yml

# requirements.yml
roles:
  - name: geerlingguy.nginx
    version: "3.3.0"
  - name: geerlingguy.mysql
    version: "4.3.2"

collections:
  - name: community.general
    version: ">=7.0.0"
  - name: amazon.aws
    version: ">=7.0.0"

# Install to project-local directory
ansible-galaxy install -r requirements.yml -p ./roles
```

---

## Key Command Reference

```bash
# Run playbook
ansible-playbook site.yml -i inventory.ini

# Limit to specific hosts/groups
ansible-playbook site.yml --limit "web1.company.com"
ansible-playbook site.yml --limit "webservers:!web2"  # Exclude web2

# Dry run
ansible-playbook site.yml --check --diff

# Run specific tags
ansible-playbook site.yml --tags "install,configure"
ansible-playbook site.yml --skip-tags "slow-tasks"

# Ad-hoc commands
ansible webservers -m ping -i inventory.ini
ansible all -m command -a "uptime"
ansible webservers -m apt -a "name=vim state=present" --become

# Debug
ansible-playbook site.yml -v       # verbose
ansible-playbook site.yml -vvv     # very verbose
ansible-playbook site.yml --step   # Confirm each task

# Inventory info
ansible-inventory --list
ansible-inventory --graph
ansible-inventory --host web1.company.com
```
