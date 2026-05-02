#!/bin/bash
# Example 07: Docker Security Scanning Script
# Scan images before deploying to production

set -e

IMAGE="${1:-myapp:latest}"
FAIL_ON_HIGH="${2:-true}"

echo "=== Docker Security Scan: $IMAGE ==="
echo ""

# ── 1. Trivy — CVE Scanning ───────────────────────────────────
echo "--- Trivy CVE Scan ---"
if command -v trivy &>/dev/null; then
    trivy image \
        --severity HIGH,CRITICAL \
        --exit-code 0 \
        --format table \
        $IMAGE

    if [ "$FAIL_ON_HIGH" = "true" ]; then
        trivy image \
            --severity CRITICAL \
            --exit-code 1 \
            --quiet \
            $IMAGE && echo "✅ No CRITICAL CVEs found" || echo "❌ CRITICAL CVEs found!"
    fi
else
    echo "Trivy not installed. Install: brew install trivy"
fi

echo ""

# ── 2. Hadolint — Dockerfile Best Practices ───────────────────
echo "--- Hadolint Dockerfile Lint ---"
if command -v hadolint &>/dev/null; then
    hadolint Dockerfile || true
else
    docker run --rm -i hadolint/hadolint < Dockerfile || true
fi
echo ""

# ── 3. Docker Scout ───────────────────────────────────────────
echo "--- Docker Scout Analysis ---"
if command -v docker &>/dev/null && docker scout version &>/dev/null 2>&1; then
    docker scout cves $IMAGE --only-severity critical,high || true
    docker scout recommendations $IMAGE || true
else
    echo "Docker Scout not available (requires Docker Desktop 4.17+)"
fi
echo ""

# ── 4. Image inspection ───────────────────────────────────────
echo "--- Image Metadata ---"
echo "Size: $(docker inspect $IMAGE --format='{{.Size}}' | numfmt --to=iec)"
echo "Layers: $(docker inspect $IMAGE --format='{{len .RootFS.Layers}}')"
echo "User: $(docker inspect $IMAGE --format='{{.Config.User}}')"

# Check if running as root (bad!)
USER=$(docker inspect $IMAGE --format='{{.Config.User}}')
if [ -z "$USER" ] || [ "$USER" = "root" ] || [ "$USER" = "0" ]; then
    echo "⚠️  WARNING: Container runs as root!"
fi

echo ""

# ── 5. SBOM Generation ────────────────────────────────────────
echo "--- SBOM (Software Bill of Materials) ---"
if command -v syft &>/dev/null; then
    syft $IMAGE -o spdx-json > sbom.spdx.json
    echo "✅ SBOM generated: sbom.spdx.json"
    echo "Packages: $(cat sbom.spdx.json | jq '.packages | length')"
elif command -v docker &>/dev/null; then
    docker sbom $IMAGE || echo "docker sbom not available"
else
    echo "syft not installed: brew install syft"
fi

echo ""
echo "=== Security scan complete ==="
