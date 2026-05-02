#!/bin/bash
# Example 02: Complete IRSA (IAM Roles for Service Accounts) Setup
# Grants specific AWS permissions to individual K8s pods

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-production}"
REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="${NAMESPACE:-production}"
SA_NAME="${SA_NAME:-myapp-sa}"
POLICY_ARN="${POLICY_ARN:-}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="${CLUSTER_NAME}-${NAMESPACE}-${SA_NAME}-role"

echo "=== IRSA Setup ==="
echo "Cluster:   $CLUSTER_NAME"
echo "Namespace: $NAMESPACE"
echo "SA Name:   $SA_NAME"
echo "Role:      $ROLE_NAME"

# ── Step 1: Enable OIDC Provider ──────────────────────────────
echo ""
echo "Step 1: Enabling OIDC provider..."
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve 2>/dev/null || echo "OIDC already enabled"

OIDC_PROVIDER=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')

echo "OIDC Provider: $OIDC_PROVIDER"

# ── Step 2: Create IAM Trust Policy ───────────────────────────
echo ""
echo "Step 2: Creating IAM trust policy..."
TRUST_POLICY=$(cat << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SA_NAME}"
        }
      }
    }
  ]
}
EOF
)

# ── Step 3: Create IAM Role ───────────────────────────────────
echo ""
echo "Step 3: Creating IAM role $ROLE_NAME..."
if aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
  echo "Role already exists, updating trust policy..."
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "$TRUST_POLICY"
else
  aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --description "IRSA role for $NAMESPACE/$SA_NAME in $CLUSTER_NAME"
fi

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
echo "Role ARN: $ROLE_ARN"

# ── Step 4: Attach Policy ─────────────────────────────────────
if [ -n "$POLICY_ARN" ]; then
  echo ""
  echo "Step 4: Attaching policy $POLICY_ARN..."
  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN"
else
  # Create a minimal custom policy example (S3 read-only for a specific bucket)
  CUSTOM_POLICY=$(cat << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::my-app-bucket",
        "arn:aws:s3:::my-app-bucket/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": ["arn:aws:secretsmanager:us-east-1:*:secret:production/myapp/*"]
    }
  ]
}
EOF
  )

  POLICY_NAME="${ROLE_NAME}-policy"
  echo ""
  echo "Step 4: Creating and attaching custom policy $POLICY_NAME..."

  POLICY_ARN_NEW=$(aws iam create-policy \
    --policy-name "$POLICY_NAME" \
    --policy-document "$CUSTOM_POLICY" \
    --query "Policy.Arn" \
    --output text 2>/dev/null || \
    aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN_NEW"
fi

# ── Step 5: Create K8s ServiceAccount ────────────────────────
echo ""
echo "Step 5: Creating Kubernetes ServiceAccount..."
kubectl create namespace "$NAMESPACE" 2>/dev/null || true

cat << EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: ${NAMESPACE}
  annotations:
    eks.amazonaws.com/role-arn: "${ROLE_ARN}"
    eks.amazonaws.com/token-expiration: "86400"
automountServiceAccountToken: false
EOF

echo ""
echo "✅ IRSA setup complete!"
echo ""
echo "=== Test with a pod ==="
cat << EOF
kubectl run irsa-test --image=amazon/aws-cli:latest \\
  --serviceaccount=${SA_NAME} \\
  -n ${NAMESPACE} \\
  --rm -it \\
  --restart=Never \\
  -- aws sts get-caller-identity

# Should show: ${ROLE_ARN}
EOF
