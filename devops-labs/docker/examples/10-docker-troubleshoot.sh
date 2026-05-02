#!/bin/bash
# Example 10: Docker Troubleshooting Toolkit

IMAGE="${1:-nginx:alpine}"
CONTAINER="${2:-web}"

echo "=== Docker Troubleshooting Toolkit ==="
echo "Target: Image=$IMAGE, Container=$CONTAINER"
echo ""

# ── 1. Container health and status ────────────────────────────
health_check() {
    echo "--- Container Status ---"
    docker ps -a --filter name=$CONTAINER \
        --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo ""
    echo "--- Health Check Status ---"
    docker inspect $CONTAINER \
        --format='{{.State.Health.Status}} | LastCheck: {{(index .State.Health.Log 0).End}}' \
        2>/dev/null || echo "No health check configured"
}

# ── 2. Resource usage ─────────────────────────────────────────
resource_check() {
    echo "--- Real-time resource usage ---"
    docker stats $CONTAINER --no-stream \
        --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.NetIO}}\t{{.BlockIO}}"
}

# ── 3. Log analysis ───────────────────────────────────────────
log_analysis() {
    echo "--- Recent Logs (last 50 lines) ---"
    docker logs $CONTAINER --tail=50 --timestamps 2>&1

    echo ""
    echo "--- Error count in logs ---"
    docker logs $CONTAINER 2>&1 | grep -ciE "error|ERROR|FATAL|exception" || echo "0 errors"
}

# ── 4. Network diagnostics ────────────────────────────────────
network_check() {
    echo "--- Container network config ---"
    docker inspect $CONTAINER --format='
Networks: {{range $k, $v := .NetworkSettings.Networks}}
  {{$k}}: {{$v.IPAddress}}
{{end}}
Ports: {{.NetworkSettings.Ports}}
' 2>/dev/null

    echo ""
    echo "--- Listening ports ---"
    docker exec $CONTAINER sh -c "netstat -tlnp 2>/dev/null || ss -tlnp" 2>/dev/null || \
        echo "netstat not available in this container"

    echo ""
    echo "--- DNS resolution test ---"
    docker exec $CONTAINER sh -c "nslookup google.com" 2>/dev/null || \
        echo "nslookup not available"
}

# ── 5. Filesystem inspection ──────────────────────────────────
fs_check() {
    echo "--- Filesystem usage ---"
    docker exec $CONTAINER df -h 2>/dev/null

    echo ""
    echo "--- Large files in container ---"
    docker exec $CONTAINER find / -size +10M -type f 2>/dev/null | head -10

    echo ""
    echo "--- Recent file changes (container writable layer) ---"
    docker diff $CONTAINER 2>/dev/null | head -20
}

# ── 6. Process inspection ─────────────────────────────────────
process_check() {
    echo "--- Running processes ---"
    docker top $CONTAINER 2>/dev/null

    echo ""
    echo "--- Process tree ---"
    docker exec $CONTAINER ps aux 2>/dev/null | head -20
}

# ── 7. Override entrypoint for debug shell ────────────────────
debug_shell() {
    echo "--- Launching debug shell ---"
    echo "Starting a bash/sh shell in the container..."

    # Try bash first, fall back to sh
    docker run -it --rm \
        --entrypoint /bin/bash \
        $IMAGE || \
    docker run -it --rm \
        --entrypoint /bin/sh \
        $IMAGE
}

# ── 8. Image analysis ─────────────────────────────────────────
image_analysis() {
    echo "--- Image layers ---"
    docker history $IMAGE --no-trunc | head -20

    echo ""
    echo "--- Image size breakdown ---"
    docker inspect $IMAGE --format='
Size: {{.Size | printf "%.2f" | printf "%.0f"}} bytes
Architecture: {{.Architecture}}
OS: {{.Os}}
Created: {{.Created}}
' 2>/dev/null

    echo ""
    echo "--- Environment variables ---"
    docker inspect $IMAGE --format='{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' 2>/dev/null
}

# ── 9. Copy files out of container ────────────────────────────
extract_files() {
    local dest="${1:-./debug-output}"
    mkdir -p $dest

    echo "Extracting logs and configs to $dest..."
    docker cp $CONTAINER:/var/log $dest/ 2>/dev/null || true
    docker cp $CONTAINER:/etc $dest/ 2>/dev/null || true
    echo "✅ Files extracted to $dest"
}

# ── Main menu ─────────────────────────────────────────────────
case "${3:-all}" in
    health)   health_check ;;
    resources) resource_check ;;
    logs)     log_analysis ;;
    network)  network_check ;;
    fs)       fs_check ;;
    processes) process_check ;;
    shell)    debug_shell ;;
    image)    image_analysis ;;
    extract)  extract_files "$4" ;;
    all)
        health_check
        echo ""; resource_check
        echo ""; log_analysis
        echo ""; network_check
        ;;
    *)
        echo "Usage: $0 [image] [container] [command]"
        echo "Commands: health resources logs network fs processes shell image extract all"
        ;;
esac
