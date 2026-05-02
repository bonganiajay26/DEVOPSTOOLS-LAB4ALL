#!/bin/bash
# Example 01: Production Debugging Toolkit
# A collection of diagnostic scripts for common scenarios

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── 1. Cluster Health Check ───────────────────────────────────
cluster_health() {
    info "=== Cluster Health Report ==="

    # Node status
    echo ""
    info "Nodes:"
    kubectl get nodes -o wide
    NOT_READY=$(kubectl get nodes --no-headers | grep -v " Ready" | wc -l)
    [ "$NOT_READY" -gt 0 ] && warn "$NOT_READY node(s) NOT Ready!"

    # System pods
    echo ""
    info "System pods (non-Running):"
    kubectl get pods -n kube-system | grep -v "Running\|Completed" || echo "All system pods running ✅"

    # Resource usage
    echo ""
    info "Top resource consumers:"
    kubectl top pods -A --sort-by=memory 2>/dev/null | head -15 || warn "metrics-server not available"

    # Recent warnings
    echo ""
    info "Recent Warning events:"
    kubectl get events -A --field-selector type=Warning \
        --sort-by='.lastTimestamp' 2>/dev/null | tail -15
}

# ── 2. Namespace Audit ────────────────────────────────────────
namespace_audit() {
    local NS="${1:-production}"
    info "=== Namespace Audit: $NS ==="

    echo ""
    info "Pod summary:"
    kubectl get pods -n $NS -o wide

    echo ""
    info "Pods with restarts:"
    kubectl get pods -n $NS --no-headers | \
        awk '$4 > 0 {printf "%-50s restarts: %s\n", $1, $4}'

    echo ""
    info "Services and endpoints:"
    kubectl get svc,endpoints -n $NS

    echo ""
    info "ConfigMaps and Secrets (names only):"
    kubectl get configmaps,secrets -n $NS --no-headers | awk '{print $1, $2}'

    echo ""
    info "Resource usage:"
    kubectl describe resourcequota -n $NS 2>/dev/null || echo "No resource quota set"
}

# ── 3. Pod Deep Dive ──────────────────────────────────────────
pod_deep_dive() {
    local NS="${1:-production}"
    local LABEL="${2:-app=myapp}"
    info "=== Pod Analysis: $LABEL in $NS ==="

    PODS=$(kubectl get pods -n $NS -l $LABEL -o name 2>/dev/null)
    if [ -z "$PODS" ]; then
        error "No pods found with label $LABEL in namespace $NS"
        return 1
    fi

    for POD in $PODS; do
        POD_NAME=$(echo $POD | cut -d/ -f2)
        echo ""
        info "--- Pod: $POD_NAME ---"

        # Status
        STATUS=$(kubectl get pod $POD_NAME -n $NS -o jsonpath='{.status.phase}')
        RESTARTS=$(kubectl get pod $POD_NAME -n $NS -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
        echo "Status: $STATUS | Restarts: $RESTARTS"

        # Last exit code
        EXIT_CODE=$(kubectl get pod $POD_NAME -n $NS \
            -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}' 2>/dev/null)
        [ -n "$EXIT_CODE" ] && echo "Last exit code: $EXIT_CODE"

        # Resources
        echo "Resources:"
        kubectl get pod $POD_NAME -n $NS \
            -o jsonpath='{range .spec.containers[*]}  {.name}: cpu={.resources.requests.cpu}/{.resources.limits.cpu} mem={.resources.requests.memory}/{.resources.limits.memory}{"\n"}{end}' 2>/dev/null

        # Recent logs (errors only)
        echo "Recent errors:"
        kubectl logs $POD_NAME -n $NS --tail=50 2>/dev/null | \
            grep -iE "error|fatal|panic|exception" | tail -5 || echo "  No errors in recent logs"
    done
}

# ── 4. Network Diagnostics ────────────────────────────────────
network_check() {
    local SVC="${1}"
    local NS="${2:-production}"
    local PORT="${3:-80}"

    if [ -z "$SVC" ]; then
        error "Usage: network_check <service-name> [namespace] [port]"
        return 1
    fi

    info "=== Network Check: $SVC.$NS:$PORT ==="

    # Check endpoints
    echo ""
    info "Service endpoints:"
    kubectl get endpoints $SVC -n $NS 2>/dev/null || warn "Service not found"

    # Test from inside the cluster
    echo ""
    info "DNS resolution test:"
    kubectl run net-test-$RANDOM --image=curlimages/curl:latest \
        --rm -it --restart=Never \
        -n $NS -- sh -c "
nslookup $SVC.$NS.svc.cluster.local 2>&1 | head -5
echo ''
echo 'HTTP test:'
curl -sv http://$SVC.$NS.svc.cluster.local:$PORT/health 2>&1 | tail -10
" 2>/dev/null || warn "Network test pod failed (normal if cluster unreachable)"
}

# ── 5. Resource Analysis ──────────────────────────────────────
resource_analysis() {
    local NS="${1:-production}"
    info "=== Resource Analysis: $NS ==="

    echo ""
    info "Pods without resource limits (DANGEROUS!):"
    kubectl get pods -n $NS -o json 2>/dev/null | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for pod in data.get('items', []):
    for c in pod['spec']['containers']:
        if not c.get('resources', {}).get('limits'):
            print(f'  {pod[\"metadata\"][\"name\"]} / {c[\"name\"]}: NO LIMITS SET')
" || echo "Cannot check (jq not available)"

    echo ""
    info "Nodes resource allocation:"
    kubectl describe nodes 2>/dev/null | grep -A5 "Allocated resources:" | \
        grep -E "Name:|cpu|memory" | head -30
}

# ── 6. Secret Audit ───────────────────────────────────────────
secret_audit() {
    local NS="${1:-production}"
    info "=== Secret Audit: $NS ==="
    warn "Checking for secrets exposed as env vars..."

    # Find pods with secrets as environment variables
    kubectl get pods -n $NS -o json 2>/dev/null | \
        python3 -c "
import json, sys, re
data = json.load(sys.stdin)
sensitive = re.compile(r'PASSWORD|SECRET|KEY|TOKEN|CREDENTIAL', re.I)
for pod in data.get('items', []):
    for c in pod['spec']['containers']:
        for env in c.get('env', []):
            if env.get('value') and sensitive.search(env.get('name', '')):
                print(f'  WARN: {pod[\"metadata\"][\"name\"]} has {env[\"name\"]} as plain env var!')
" 2>/dev/null || echo "Script unavailable"

    echo ""
    info "Secrets in namespace (names only - not values):"
    kubectl get secrets -n $NS --no-headers | awk '{print $1, $2}'
}

# ── 7. Recent Changes ─────────────────────────────────────────
recent_changes() {
    local HOURS="${1:-2}"
    info "=== Changes in last ${HOURS} hours ==="

    echo ""
    info "Deployment rollouts:"
    kubectl rollout history deployment -A 2>/dev/null | head -30

    echo ""
    info "Recent events:"
    kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | \
        tail -20

    echo ""
    if command -v git &>/dev/null && [ -d .git ]; then
        info "Git commits:"
        git log --oneline --since="${HOURS} hours ago"
    fi
}

# ── Main menu ─────────────────────────────────────────────────
case "${1:-help}" in
    health)    cluster_health ;;
    ns)        namespace_audit "${2:-production}" ;;
    pod)       pod_deep_dive "${2:-production}" "${3:-app=myapp}" ;;
    network)   network_check "$2" "${3:-production}" "${4:-80}" ;;
    resources) resource_analysis "${2:-production}" ;;
    secrets)   secret_audit "${2:-production}" ;;
    changes)   recent_changes "${2:-2}" ;;
    all)
        cluster_health
        namespace_audit "${2:-production}"
        resource_analysis "${2:-production}"
        recent_changes
        ;;
    help|*)
        echo "Production Debugging Toolkit"
        echo ""
        echo "Usage: $0 <command> [args]"
        echo ""
        echo "Commands:"
        echo "  health              Cluster-wide health check"
        echo "  ns     [namespace]  Namespace audit"
        echo "  pod    [ns] [label] Pod deep dive"
        echo "  network [svc] [ns]  Network connectivity check"
        echo "  resources [ns]      Resource usage analysis"
        echo "  secrets [ns]        Secret exposure audit"
        echo "  changes [hours]     Show recent changes"
        echo "  all    [namespace]  Run all checks"
        ;;
esac
