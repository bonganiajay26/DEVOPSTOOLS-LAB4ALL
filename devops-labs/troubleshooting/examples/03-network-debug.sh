#!/bin/bash
# Example 03: Network Debugging in Kubernetes
# Complete toolkit for diagnosing connectivity issues

set -euo pipefail

# ── Start a debug pod with networking tools ───────────────────
start_debug_pod() {
    local NS="${1:-default}"
    local POD_NAME="netdebug-$(date +%s)"

    echo "Starting debug pod in namespace: $NS"
    kubectl run "$POD_NAME" \
        --image=nicolaka/netshoot:latest \
        --namespace="$NS" \
        --rm -it \
        --restart=Never \
        --labels="purpose=network-debug" \
        -- /bin/bash
}

# ── DNS debugging ─────────────────────────────────────────────
debug_dns() {
    local SERVICE="${1}"
    local NS="${2:-production}"

    echo "=== DNS Debug: $SERVICE in $NS ==="

    kubectl run dns-debug-$RANDOM \
        --image=busybox:1.36 \
        --namespace="$NS" \
        --rm -it \
        --restart=Never \
        -- sh -c "
echo '=== /etc/resolv.conf ==='
cat /etc/resolv.conf

echo ''
echo '=== DNS lookups ==='
# Short form (within same namespace)
nslookup $SERVICE

# Fully qualified
nslookup $SERVICE.$NS.svc.cluster.local

# CoreDNS server
nslookup $SERVICE 10.96.0.10 2>/dev/null || nslookup $SERVICE \$(cat /etc/resolv.conf | grep nameserver | awk '{print \$2}' | head -1)

echo ''
echo '=== Pod network info ==='
ip addr show eth0 | grep 'inet '
ip route show default
"
}

# ── Service connectivity test ─────────────────────────────────
test_service_connectivity() {
    local SERVICE="${1}"
    local NS="${2:-production}"
    local PORT="${3:-80}"
    local PATH_URL="${4:-/health}"

    echo "=== Service Connectivity: $SERVICE:$PORT$PATH_URL ==="

    kubectl run conn-test-$RANDOM \
        --image=curlimages/curl:latest \
        --namespace="$NS" \
        --rm -it \
        --restart=Never \
        -- sh -c "
# Test 1: TCP connectivity
echo 'TCP test:'
nc -zv $SERVICE $PORT 2>&1 && echo 'TCP: OPEN' || echo 'TCP: CLOSED/FILTERED'

echo ''
# Test 2: HTTP response
echo 'HTTP test:'
curl -v --max-time 10 http://$SERVICE:$PORT$PATH_URL 2>&1

echo ''
# Test 3: Response time
echo 'Response time:'
curl -o /dev/null -s -w 'Connect: %{time_connect}s\\nTTFB: %{time_starttransfer}s\\nTotal: %{time_total}s\\n' http://$SERVICE:$PORT$PATH_URL
"
}

# ── Network policy analysis ───────────────────────────────────
analyze_network_policies() {
    local NS="${1:-production}"

    echo "=== Network Policy Analysis: $NS ==="

    POLICIES=$(kubectl get networkpolicy -n "$NS" -o json 2>/dev/null)
    POLICY_COUNT=$(echo "$POLICIES" | python3 -c "import json,sys; data=json.load(sys.stdin); print(len(data['items']))")

    echo "Found $POLICY_COUNT network policies in $NS"

    if [ "$POLICY_COUNT" -eq 0 ]; then
        echo "⚠️  No network policies — ALL traffic allowed by default"
        return
    fi

    # Check for default-deny
    if echo "$POLICIES" | grep -q '"podSelector": {}'; then
        echo "✅ Default deny policy found"
    else
        echo "⚠️  No default deny policy"
    fi

    echo ""
    echo "Policies:"
    kubectl get networkpolicy -n "$NS" \
        -o custom-columns="NAME:.metadata.name,POD-SELECTOR:.spec.podSelector,POLICY-TYPES:.spec.policyTypes"

    echo ""
    echo "Ingress rules summary:"
    kubectl get networkpolicy -n "$NS" -o json | \
        python3 -c "
import json, sys
data = json.load(sys.stdin)
for policy in data['items']:
    name = policy['metadata']['name']
    ingress = policy['spec'].get('ingress', [])
    egress = policy['spec'].get('egress', [])
    print(f'  {name}:')
    print(f'    Ingress rules: {len(ingress)}')
    print(f'    Egress rules:  {len(egress)}')
    for rule in ingress:
        frm = rule.get('from', [{'all': 'traffic'}])
        ports = rule.get('ports', [{'all': 'ports'}])
        print(f'    Allow from: {json.dumps(frm)[:80]}')
"
}

# ── iptables / conntrack check ────────────────────────────────
check_node_networking() {
    local NODE="${1}"

    echo "=== Node Networking: $NODE ==="

    # Run privileged pod on the specific node
    kubectl run node-net-debug-$RANDOM \
        --image=ubuntu:22.04 \
        --overrides="{
            \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"$NODE\"},
                \"tolerations\": [{\"operator\": \"Exists\"}],
                \"hostNetwork\": true,
                \"hostPID\": true,
                \"containers\": [{
                    \"name\": \"debug\",
                    \"image\": \"ubuntu:22.04\",
                    \"securityContext\": {\"privileged\": true},
                    \"command\": [\"bash\", \"-c\",
                        \"echo '=== iptables rules (kube-proxy)' && iptables -n -L KUBE-SERVICES | head -20 && echo '' && echo '=== kube-proxy health' && netstat -tlnp | grep kube-proxy && echo '' && echo '=== Network interfaces' && ip addr show\"]
                }],
                \"restartPolicy\": \"Never\"
            }
        }" \
        --rm -it \
        --restart=Never
}

# ── Packet capture ────────────────────────────────────────────
capture_traffic() {
    local NS="${1:-production}"
    local POD="${2}"
    local PORT="${3:-80}"
    local DURATION="${4:-30}"

    echo "=== Packet Capture: $POD port $PORT for ${DURATION}s ==="

    # Check if pod has tcpdump
    kubectl exec -it "$POD" -n "$NS" -- which tcpdump 2>/dev/null || {
        echo "tcpdump not found in pod. Starting sidecar capture..."
        # Use kubectl debug to add ephemeral container with tcpdump
        kubectl debug -it "$POD" -n "$NS" \
            --image=nicolaka/netshoot \
            --target="app" \
            -- tcpdump -i any -w /tmp/capture.pcap port "$PORT" &
        sleep "$DURATION"
        kill %1
        kubectl cp "$NS/$POD:/tmp/capture.pcap" "./capture-$(date +%s).pcap"
        echo "Capture saved locally. Open with Wireshark."
        return
    }

    # Run tcpdump directly in pod
    kubectl exec -it "$POD" -n "$NS" -- \
        timeout "$DURATION" tcpdump -i any port "$PORT" -A 2>/dev/null | head -100
}

# ── Endpoint chain debug ──────────────────────────────────────
debug_endpoint_chain() {
    local SERVICE="${1}"
    local NS="${2:-production}"

    echo "=== Endpoint Chain Debug: $SERVICE in $NS ==="

    # Step 1: Service exists?
    echo "Step 1: Service configuration:"
    kubectl get svc "$SERVICE" -n "$NS" -o yaml | grep -E "port:|targetPort:|selector:|type:" || {
        echo "❌ Service '$SERVICE' not found in namespace '$NS'"
        return 1
    }

    # Step 2: Endpoints populated?
    echo ""
    echo "Step 2: Endpoints:"
    ENDPOINTS=$(kubectl get endpoints "$SERVICE" -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
    if [ -z "$ENDPOINTS" ]; then
        echo "❌ No endpoints! The service has no ready pods."
        echo ""
        echo "Checking pods that should match..."
        SELECTOR=$(kubectl get svc "$SERVICE" -n "$NS" -o jsonpath='{.spec.selector}' 2>/dev/null)
        echo "Service selector: $SELECTOR"
        kubectl get pods -n "$NS" --show-labels | head -20
    else
        echo "✅ Endpoints found: $ENDPOINTS"
    fi

    # Step 3: Pod readiness
    echo ""
    echo "Step 3: Pod readiness:"
    kubectl get pods -n "$NS" -l "$(kubectl get svc "$SERVICE" -n "$NS" -o jsonpath='{.spec.selector}' 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(f'{k}={v}' for k,v in d.items()))" 2>/dev/null)"
}

# ── Main ──────────────────────────────────────────────────────
case "${1:-help}" in
    debug)    start_debug_pod "${2:-default}" ;;
    dns)      debug_dns "$2" "${3:-production}" ;;
    connect)  test_service_connectivity "$2" "${3:-production}" "${4:-80}" "${5:-/health}" ;;
    policies) analyze_network_policies "${2:-production}" ;;
    node)     check_node_networking "$2" ;;
    capture)  capture_traffic "${2:-production}" "$3" "${4:-80}" "${5:-30}" ;;
    chain)    debug_endpoint_chain "$2" "${3:-production}" ;;
    *)
        echo "Network Debugging Toolkit"
        echo ""
        echo "  debug  [ns]                    Start interactive debug pod"
        echo "  dns    <svc> [ns]              Debug DNS resolution"
        echo "  connect <svc> [ns] [port] [path]  Test HTTP connectivity"
        echo "  policies [ns]                  Analyze network policies"
        echo "  node   <node-name>             Check node-level networking"
        echo "  capture [ns] <pod> [port]      Packet capture"
        echo "  chain  <svc> [ns]              Debug full endpoint chain"
        ;;
esac
