#!/bin/bash
# Example 02: GCP Workload Identity Federation Setup
# Grants K8s pods access to GCP services without credentials

set -euo pipefail

PROJECT=$(gcloud config get-value project)
CLUSTER="${CLUSTER:-my-cluster}"
REGION="${REGION:-us-central1}"
NAMESPACE="${NAMESPACE:-production}"
K8S_SA="${K8S_SA:-myapp-sa}"
GCP_SA_NAME="${GCP_SA_NAME:-myapp-gcp-sa}"

GCP_SA="${GCP_SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "=== GCP Workload Identity Setup ==="
echo "Project:   $PROJECT"
echo "Cluster:   $CLUSTER"
echo "K8s SA:    $K8S_SA (namespace: $NAMESPACE)"
echo "GCP SA:    $GCP_SA"

# ── Step 1: Enable Workload Identity on cluster ───────────────
echo ""
echo "Step 1: Enabling Workload Identity..."
gcloud container clusters update "$CLUSTER" \
  --workload-pool="${PROJECT}.svc.id.goog" \
  --region="$REGION" \
  --quiet || echo "Already enabled"

# ── Step 2: Create GCP Service Account ───────────────────────
echo ""
echo "Step 2: Creating GCP Service Account..."
gcloud iam service-accounts create "$GCP_SA_NAME" \
  --display-name="Workload Identity for K8s $NAMESPACE/$K8S_SA" \
  --project="$PROJECT" 2>/dev/null || echo "Service account already exists"

# ── Step 3: Grant GCP permissions ────────────────────────────
echo ""
echo "Step 3: Granting GCP permissions..."

# Secret Manager access
gcloud projects add-iam-policy-binding "$PROJECT" \
  --role="roles/secretmanager.secretAccessor" \
  --member="serviceAccount:${GCP_SA}" \
  --condition=None

# Cloud Storage read access
gcloud projects add-iam-policy-binding "$PROJECT" \
  --role="roles/storage.objectViewer" \
  --member="serviceAccount:${GCP_SA}" \
  --condition=None

# Optional: BigQuery access
# gcloud projects add-iam-policy-binding "$PROJECT" \
#   --role="roles/bigquery.dataViewer" \
#   --member="serviceAccount:${GCP_SA}"

echo "Permissions granted to: $GCP_SA"

# ── Step 4: Bind K8s SA to GCP SA ────────────────────────────
echo ""
echo "Step 4: Creating Workload Identity binding..."
gcloud iam service-accounts add-iam-policy-binding "${GCP_SA}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT}.svc.id.goog[${NAMESPACE}/${K8S_SA}]" \
  --project="$PROJECT"

echo "Binding created: $NAMESPACE/$K8S_SA → $GCP_SA"

# ── Step 5: Create annotated K8s ServiceAccount ───────────────
echo ""
echo "Step 5: Creating Kubernetes ServiceAccount..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || true

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${K8S_SA}
  namespace: ${NAMESPACE}
  annotations:
    iam.gke.io/gcp-service-account: "${GCP_SA}"
automountServiceAccountToken: false
EOF

echo ""
echo "✅ Workload Identity setup complete!"
echo ""
echo "=== Verify with a test pod ==="
cat << EOF
kubectl run wli-test \\
  --image=google/cloud-sdk:slim \\
  --serviceaccount=${K8S_SA} \\
  -n ${NAMESPACE} \\
  --rm -it \\
  --restart=Never \\
  -- gcloud auth print-identity-token

# Should show a valid token for: ${GCP_SA}

# Test Secret Manager access:
kubectl run secret-test \\
  --image=google/cloud-sdk:slim \\
  --serviceaccount=${K8S_SA} \\
  -n ${NAMESPACE} \\
  --rm -it \\
  --restart=Never \\
  -- gcloud secrets list --project=${PROJECT}
EOF
