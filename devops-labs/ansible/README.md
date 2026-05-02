# Ansible

> **Agentless configuration management and automation. SSH in, configure everything.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | Inventory, playbooks, roles, modules |
| [examples/](examples/) | 10 production playbooks |
| [labs/](labs/) | 3 labs (server hardening, app deploy, K8s node setup) |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Quick Start

```bash
# Install
pip install ansible

# Run ad-hoc command on all web servers
ansible webservers -i inventory.ini -m ping
ansible webservers -m command -a "uptime"
ansible webservers -m apt -a "name=nginx state=present" --become

# Run a playbook
ansible-playbook -i inventory.ini playbook.yml
ansible-playbook -i inventory.ini playbook.yml --check  # Dry run
ansible-playbook -i inventory.ini playbook.yml --diff   # Show changes
ansible-playbook -i inventory.ini playbook.yml -v       # Verbose
ansible-playbook -i inventory.ini playbook.yml --limit "webservers:&production"  # Subset

# Vault
ansible-vault encrypt secrets.yml
ansible-playbook playbook.yml --ask-vault-pass
ansible-playbook playbook.yml --vault-password-file ~/.vault-pass
```
