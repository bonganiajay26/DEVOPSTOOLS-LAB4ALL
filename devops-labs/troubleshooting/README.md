# Troubleshooting

> **Production war stories, systematic debugging methodologies, and quick-reference playbooks.**

---

## The Troubleshooting Mindset

```
1. STAY CALM — panicking makes things worse
2. ASSESS IMPACT first — how many users? Revenue impact?
3. DON'T GUESS — use data (metrics, logs, events)
4. CHANGE ONE THING AT A TIME — otherwise you don't know what fixed it
5. DOCUMENT AS YOU GO — future you will thank present you
6. COMMUNICATE — update stakeholders even before you have answers
```

---

## Quick Navigation

| Playbook | Symptoms |
|---------|---------|
| [kubernetes-debug.md](labs/kubernetes-debug.md) | Pod failures, service issues, cluster problems |
| [docker-debug.md](labs/docker-debug.md) | Container issues, image problems |
| [network-debug.md](labs/network-debug.md) | DNS failures, connectivity, timeouts |
| [performance-debug.md](labs/performance-debug.md) | High CPU, memory, slow responses |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 scenario-based questions |

---

## Universal Debug Checklist

```bash
# For ANY production issue, collect this data FIRST:

# 1. When did it start?
kubectl get events --sort-by=.lastTimestamp -n production | tail -30

# 2. What changed recently?
git log --oneline --since="2 hours ago"
kubectl rollout history deployment -A

# 3. What's the current state?
kubectl get pods -A | grep -v Running
kubectl get nodes

# 4. What do logs say?
kubectl logs -l app=affected-service --tail=100 -n production | grep -i error

# 5. What do metrics show?
kubectl top pods -n production
kubectl top nodes
```
