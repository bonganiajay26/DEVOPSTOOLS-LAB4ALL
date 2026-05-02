#!/bin/bash
# Example 03: Automated Runbook Execution
# Automates common remediation actions with safety checks

set -euo pipefail

LOG_FILE="/tmp/runbook-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Runbook Execution: $(date -u) ==="
echo "Log file: $LOG_FILE"

# ── Safety checks ─────────────────────────────────────────────
assert_cluster_healthy() {
    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l || echo "999")
    if [ "$NOT_READY" -gt 1 ]; then
        echo "❌ SAFETY: $NOT_READY nodes NOT ready. Refusing to run remediation."
        exit 1
    fi
    echo "✅ Cluster health: OK ($NOT_READY nodes not ready)"
}

assert_namespace_exists() {
    local ns="$1"
    kubectl get namespace "$ns" &>/dev/null || {
        echo "❌ Namespace '$ns' does not exist"
        exit 1
    }
}

# ── Runbook 1: Restart deployment with high restart count ─────
runbook_restart_crashloop() {
    local NS="${1:-production}"
    local THRESHOLD="${2:-5}"
    echo ""
    echo "=== Runbook: Restart CrashLoop Pods ==="
    echo "Namespace: $NS | Restart threshold: $THRESHOLD"

    assert_cluster_healthy
    assert_namespace_exists "$NS"

    # Find pods exceeding restart threshold
    CRASHLOOP_PODS=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | \
        awk -v threshold="$THRESHOLD" '$4 > threshold {print $1}')

    if [ -z "$CRASHLOOP_PODS" ]; then
        echo "✅ No pods with restarts > $THRESHOLD in $NS"
        return 0
    fi

    echo "Found pods with high restarts:"
    echo "$CRASHLOOP_PODS"

    # Delete pods (Deployment controller recreates them)
    echo "$CRASHLOOP_PODS" | while read POD; do
        echo "  Deleting pod: $POD"
        kubectl delete pod "$POD" -n "$NS" --grace-period=30
    done

    # Wait for pods to come back
    sleep 10
    kubectl rollout status deployment -n "$NS" --timeout=2m || true

    echo "✅ Restart complete"
}

# ── Runbook 2: Scale deployment on traffic spike ──────────────
runbook_scale_for_traffic() {
    local NS="${1:-production}"
    local DEPLOYMENT="${2}"
    local REPLICAS="${3:-10}"

    echo ""
    echo "=== Runbook: Emergency Scale ==="

    [ -z "$DEPLOYMENT" ] && { echo "Usage: runbook_scale_for_traffic <ns> <deployment> <replicas>"; exit 1; }

    assert_cluster_healthy
    assert_namespace_exists "$NS"

    CURRENT=$(kubectl get deployment "$DEPLOYMENT" -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "unknown")
    echo "Current replicas: $CURRENT → Target: $REPLICAS"

    kubectl scale deployment "$DEPLOYMENT" -n "$NS" --replicas="$REPLICAS"
    kubectl rollout status deployment/"$DEPLOYMENT" -n "$NS" --timeout=3m

    echo "✅ Scaled to $REPLICAS replicas"
}

# ── Runbook 3: Emergency rollback ────────────────────────────
runbook_emergency_rollback() {
    local NS="${1:-production}"
    local DEPLOYMENT="${2}"
    local REVISION="${3:-}"  # Empty = previous version

    echo ""
    echo "=== Runbook: Emergency Rollback ==="

    [ -z "$DEPLOYMENT" ] && { echo "Usage: runbook_emergency_rollback <ns> <deployment> [revision]"; exit 1; }

    assert_cluster_healthy
    assert_namespace_exists "$NS"

    echo "Current deployment history:"
    kubectl rollout history deployment/"$DEPLOYMENT" -n "$NS"

    if [ -n "$REVISION" ]; then
        echo "Rolling back to revision $REVISION..."
        kubectl rollout undo deployment/"$DEPLOYMENT" -n "$NS" --to-revision="$REVISION"
    else
        echo "Rolling back to previous version..."
        kubectl rollout undo deployment/"$DEPLOYMENT" -n "$NS"
    fi

    kubectl rollout status deployment/"$DEPLOYMENT" -n "$NS" --timeout=5m
    echo "✅ Rollback complete"
}

# ── Runbook 4: Clear disk on a node ──────────────────────────
runbook_clear_node_disk() {
    local NODE="${1}"

    [ -z "$NODE" ] && { echo "Usage: runbook_clear_node_disk <node-name>"; exit 1; }

    echo ""
    echo "=== Runbook: Clear Node Disk ==="
    echo "Node: $NODE"

    # Cordon the node first
    kubectl cordon "$NODE"
    echo "Node cordoned (no new pods will be scheduled)"

    # Run cleanup job on the node
    kubectl run disk-cleanup-$RANDOM \
        --image=ubuntu:22.04 \
        --overrides="{
            \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"$NODE\"},
                \"tolerations\": [{\"operator\": \"Exists\"}],
                \"hostPID\": true,
                \"containers\": [{
                    \"name\": \"cleanup\",
                    \"image\": \"ubuntu:22.04\",
                    \"command\": [\"nsenter\", \"-m/proc/1/ns/mnt\", \"--\", \"bash\", \"-c\",
                        \"journalctl --vacuum-size=500M && crictl rmi --prune && echo done\"],
                    \"securityContext\": {\"privileged\": true}
                }],
                \"restartPolicy\": \"Never\"
            }
        }" \
        --restart=Never \
        --rm -it 2>/dev/null || true

    # Check disk after cleanup
    echo "Disk usage after cleanup:"
    kubectl debug node/"$NODE" -it --image=ubuntu -- df -h /host 2>/dev/null | grep "/$" || echo "Check node manually"

    # Uncordon if disk is OK
    read -p "Uncordon node? (yes/no): " confirm
    if [ "$confirm" = "yes" ]; then
        kubectl uncordon "$NODE"
        echo "✅ Node uncordoned"
    fi
}

# ── Runbook 5: Force garbage collection on cluster ───────────
runbook_gc_cluster() {
    echo ""
    echo "=== Runbook: Cluster Garbage Collection ==="

    # Remove completed/failed jobs older than 1 hour
    kubectl delete jobs -A --field-selector=status.completionTime!="" \
        2>/dev/null || true

    # Remove evicted pods
    kubectl get pods -A --field-selector=status.phase=Failed \
        -o 'jsonpath={range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' | \
    while read NS POD; do
        kubectl delete pod "$POD" -n "$NS" 2>/dev/null && echo "Deleted: $NS/$POD" || true
    done

    echo "✅ Garbage collection complete"
}

# ── Main entry ────────────────────────────────────────────────
case "${1:-help}" in
    crashloop) runbook_restart_crashloop "${2:-production}" "${3:-5}" ;;
    scale)     runbook_scale_for_traffic "${2:-production}" "${3}" "${4:-10}" ;;
    rollback)  runbook_emergency_rollback "${2:-production}" "${3}" "${4:-}" ;;
    disk)      runbook_clear_node_disk "${2}" ;;
    gc)        runbook_gc_cluster ;;
    help|*)
        echo "Runbook Automation"
        echo ""
        echo "  crashloop [ns] [threshold]      Restart crash-looping pods"
        echo "  scale [ns] <deploy> <replicas>  Emergency scale a deployment"
        echo "  rollback [ns] <deploy> [rev]    Emergency rollback"
        echo "  disk <node>                     Clear disk space on a node"
        echo "  gc                              Cluster garbage collection"
        echo ""
        echo "All actions are logged to: $LOG_FILE"
        ;;
esac
