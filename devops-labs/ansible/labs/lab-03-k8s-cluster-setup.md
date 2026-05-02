# Lab 03: Ansible for Kubernetes Cluster Bootstrap

**Difficulty**: Advanced | **Time**: 90 minutes  
**Goal**: Use Ansible to bootstrap a production-ready Kubernetes cluster from bare Ubuntu nodes.

---

## Architecture

```
3 Ubuntu 22.04 nodes (AWS EC2 / DigitalOcean / VMs):
  master-01  — Control plane node
  worker-01  — Worker node 1
  worker-02  — Worker node 2
```

---

## Part 1: Inventory and Configuration

```bash
mkdir k8s-ansible && cd k8s-ansible

cat > inventory.ini << 'EOF'
[k8s_masters]
master-01 ansible_host=10.0.1.10

[k8s_workers]
worker-01 ansible_host=10.0.1.20
worker-02 ansible_host=10.0.1.21

[k8s_cluster:children]
k8s_masters
k8s_workers

[all:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=~/.ssh/k8s-key
ansible_python_interpreter=/usr/bin/python3
EOF

cat > group_vars/all.yml << 'EOF'
k8s_version: "1.29"
pod_network_cidr: "10.244.0.0/16"
service_cidr: "10.96.0.0/12"
container_runtime: containerd
cni_plugin: flannel
EOF
```

---

## Part 2: Prerequisites Playbook

```bash
cat > playbooks/01-prerequisites.yml << 'EOF'
---
- name: Configure Kubernetes Prerequisites
  hosts: k8s_cluster
  become: true
  gather_facts: true

  tasks:
  # System requirements
  - name: Update and upgrade packages
    apt:
      update_cache: yes
      upgrade: dist
      autoremove: yes

  - name: Install required packages
    apt:
      name:
        - apt-transport-https
        - ca-certificates
        - curl
        - gnupg
        - lsb-release
        - socat
        - conntrack
        - ipset
      state: present

  # Disable swap (REQUIRED for K8s)
  - name: Disable swap
    command: swapoff -a
    changed_when: false

  - name: Remove swap from fstab
    replace:
      path: /etc/fstab
      regexp: '^([^#].*\s+swap\s+.*)$'
      replace: '# \1'

  - name: Verify swap is off
    command: free -h
    register: swap_status
    changed_when: false

  - name: Show swap status
    debug:
      msg: "{{ swap_status.stdout }}"

  # Kernel modules for Kubernetes networking
  - name: Load kernel modules
    modprobe:
      name: "{{ item }}"
      state: present
    loop:
      - overlay
      - br_netfilter

  - name: Persist kernel modules
    copy:
      dest: /etc/modules-load.d/k8s.conf
      content: |
        overlay
        br_netfilter

  # Sysctl settings
  - name: Configure sysctl for Kubernetes
    sysctl:
      name: "{{ item.key }}"
      value: "{{ item.value }}"
      state: present
      reload: yes
    loop:
      - { key: "net.bridge.bridge-nf-call-iptables",  value: "1" }
      - { key: "net.bridge.bridge-nf-call-ip6tables", value: "1" }
      - { key: "net.ipv4.ip_forward",                 value: "1" }

  # Set hostname from inventory
  - name: Set hostname
    hostname:
      name: "{{ inventory_hostname }}"

  - name: Update /etc/hosts
    lineinfile:
      path: /etc/hosts
      regexp: '^127\.0\.1\.1'
      line: "127.0.1.1 {{ inventory_hostname }}"
EOF
```

---

## Part 3: Container Runtime Playbook

```bash
cat > playbooks/02-containerd.yml << 'EOF'
---
- name: Install containerd container runtime
  hosts: k8s_cluster
  become: true

  tasks:
  - name: Add Docker GPG key
    apt_key:
      url: https://download.docker.com/linux/ubuntu/gpg
      state: present

  - name: Add Docker repository
    apt_repository:
      repo: "deb [arch=amd64] https://download.docker.com/linux/ubuntu {{ ansible_distribution_release }} stable"
      state: present

  - name: Install containerd
    apt:
      name: containerd.io
      state: present
      update_cache: yes

  - name: Create containerd config directory
    file:
      path: /etc/containerd
      state: directory

  - name: Generate default containerd config
    command: containerd config default
    register: containerd_config
    changed_when: false

  - name: Write containerd config with SystemdCgroup
    copy:
      content: "{{ containerd_config.stdout | regex_replace('SystemdCgroup = false', 'SystemdCgroup = true') }}"
      dest: /etc/containerd/config.toml
    notify: Restart containerd

  - name: Start containerd
    service:
      name: containerd
      state: started
      enabled: yes

  handlers:
  - name: Restart containerd
    service:
      name: containerd
      state: restarted
EOF
```

---

## Part 4: Kubernetes Install Playbook

```bash
cat > playbooks/03-kubernetes.yml << 'EOF'
---
- name: Install Kubernetes components
  hosts: k8s_cluster
  become: true

  tasks:
  - name: Add Kubernetes apt key
    apt_key:
      url: "https://pkgs.k8s.io/core:/stable:/v{{ k8s_version }}/deb/Release.key"
      state: present

  - name: Add Kubernetes repository
    apt_repository:
      repo: "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v{{ k8s_version }}/deb/ /"
      state: present

  - name: Install kubelet, kubeadm, kubectl
    apt:
      name:
        - "kubelet={{ k8s_version }}.*"
        - "kubeadm={{ k8s_version }}.*"
        - "kubectl={{ k8s_version }}.*"
      state: present
      update_cache: yes

  # Pin versions — prevent accidental upgrades
  - name: Hold kubelet
    dpkg_selections:
      name: "{{ item }}"
      selection: hold
    loop: [kubelet, kubeadm, kubectl]

  - name: Enable kubelet service
    service:
      name: kubelet
      enabled: yes
EOF
```

---

## Part 5: Cluster Init and Join

```bash
cat > playbooks/04-cluster-init.yml << 'EOF'
---
- name: Initialize Kubernetes control plane
  hosts: k8s_masters
  become: true
  run_once: true  # Only run on first master

  tasks:
  - name: Check if cluster already initialized
    stat:
      path: /etc/kubernetes/admin.conf
    register: k8s_admin

  - name: Initialize cluster with kubeadm
    command: >
      kubeadm init
        --pod-network-cidr={{ pod_network_cidr }}
        --service-cidr={{ service_cidr }}
        --node-name={{ inventory_hostname }}
    register: kubeadm_output
    when: not k8s_admin.stat.exists

  - name: Create .kube directory for root
    file:
      path: /root/.kube
      state: directory
      mode: "0700"

  - name: Copy admin.conf to root's kube config
    copy:
      src: /etc/kubernetes/admin.conf
      dest: /root/.kube/config
      remote_src: yes
      owner: root
      mode: "0600"

  - name: Install Flannel CNI
    command: kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
    environment:
      KUBECONFIG: /etc/kubernetes/admin.conf

  - name: Get join command
    command: kubeadm token create --print-join-command
    register: join_command
    changed_when: false

  - name: Save join command for workers
    add_host:
      name: "K8S_TOKEN_HOLDER"
      join_cmd: "{{ join_command.stdout }}"

---
- name: Join workers to cluster
  hosts: k8s_workers
  become: true

  tasks:
  - name: Check if already joined
    stat:
      path: /etc/kubernetes/kubelet.conf
    register: kubelet_conf

  - name: Join cluster
    command: "{{ hostvars['K8S_TOKEN_HOLDER']['join_cmd'] }}"
    when: not kubelet_conf.stat.exists

---
- name: Verify cluster
  hosts: k8s_masters[0]
  become: true

  tasks:
  - name: Wait for all nodes to be Ready
    command: kubectl get nodes
    environment:
      KUBECONFIG: /etc/kubernetes/admin.conf
    register: nodes
    until: "'NotReady' not in nodes.stdout"
    retries: 20
    delay: 15

  - name: Show cluster status
    debug:
      msg: "{{ nodes.stdout_lines }}"

  - name: Copy kubeconfig to local machine
    fetch:
      src: /etc/kubernetes/admin.conf
      dest: "./kubeconfig"
      flat: yes
EOF
```

---

## Part 6: Run the Full Setup

```bash
# Create main playbook that calls all others in order
cat > site.yml << 'EOF'
---
- import_playbook: playbooks/01-prerequisites.yml
- import_playbook: playbooks/02-containerd.yml
- import_playbook: playbooks/03-kubernetes.yml
- import_playbook: playbooks/04-cluster-init.yml
EOF

# Run the entire setup
ansible-playbook site.yml -i inventory.ini

# After completion:
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
kubectl get pods -A

# Deploy a test workload
kubectl create deployment nginx --image=nginx:alpine --replicas=3
kubectl get pods -o wide    # Pods distributed across workers
```

---

## Cleanup

```bash
cd ..
rm -rf k8s-ansible
```

## What You Learned

- [x] Multi-play playbooks with ordered execution
- [x] `run_once` for single-node operations
- [x] `add_host` to pass data between plays
- [x] Fetching files from remote hosts
- [x] Conditional tasks based on existing state
- [x] Using `until` for polling readiness
