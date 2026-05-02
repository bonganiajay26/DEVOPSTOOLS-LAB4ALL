# GitHub Actions Advanced Patterns

## 1. Dynamic Matrix from Files/API

```yaml
jobs:
  # Step 1: discover what to build
  detect:
    runs-on: ubuntu-latest
    outputs:
      matrix: ${{ steps.set-matrix.outputs.matrix }}
    steps:
    - uses: actions/checkout@v4
    - id: set-matrix
      run: |
        # Build matrix from changed services
        CHANGED=$(git diff --name-only origin/main...HEAD | \
          grep "^services/" | cut -d/ -f2 | sort -u | jq -Rcs 'split("\n")[:-1]')
        echo "matrix={\"service\":$CHANGED}" >> $GITHUB_OUTPUT

  # Step 2: build each changed service
  build:
    needs: detect
    if: needs.detect.outputs.matrix != '{"service":[]}'
    strategy:
      matrix: ${{ fromJSON(needs.detect.outputs.matrix) }}
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - run: docker build services/${{ matrix.service }}
```

---

## 2. Workflow Dispatch with Approval Gate

```yaml
name: Production Deploy

on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to deploy (e.g., v1.2.3)'
        required: true
      reason:
        description: 'Reason for deploy'
        required: true

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
    - name: Validate version tag exists
      run: |
        git ls-remote --tags origin "refs/tags/${{ inputs.version }}" | grep -q . || \
          (echo "❌ Tag ${{ inputs.version }} not found" && exit 1)
        echo "✅ Tag ${{ inputs.version }} exists"

  deploy:
    needs: validate
    runs-on: ubuntu-latest
    environment:
      name: production        # Requires manual approval in GitHub settings
      url: https://api.company.com
    steps:
    - run: echo "Deploying ${{ inputs.version }} because: ${{ inputs.reason }}"
    - run: ./scripts/deploy.sh ${{ inputs.version }}
```

---

## 3. Concurrency — Cancel Redundant Runs

```yaml
# Cancel in-progress run for same branch on new push
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

# But DON'T cancel production deploys
jobs:
  deploy:
    concurrency:
      group: deploy-production
      cancel-in-progress: false  # Queue: don't cancel, wait for previous to finish
```

---

## 4. OIDC Authentication (No Long-Lived Keys)

```yaml
# AWS
permissions:
  id-token: write    # Required for OIDC
  contents: read

steps:
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789:role/github-deploy
    aws-region: us-east-1
# Now AWS CLI/SDK work without any stored credentials!

# Google Cloud
- uses: google-github-actions/auth@v2
  with:
    workload_identity_provider: projects/123/locations/global/workloadIdentityPools/github/providers/github
    service_account: deploy@project.iam.gserviceaccount.com

# Azure
- uses: azure/login@v2
  with:
    client-id: ${{ secrets.AZURE_CLIENT_ID }}
    tenant-id: ${{ secrets.AZURE_TENANT_ID }}
    subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
```

---

## 5. Self-Hosted Runners with Auto-Scaling

```yaml
# Use self-hosted runner for:
# - Private network access
# - Specific hardware (GPU, ARM)
# - Cost savings at scale

jobs:
  gpu-training:
    runs-on: [self-hosted, linux, gpu]
    steps:
    - run: nvidia-smi    # Only works on GPU runner

# Auto-scaling with Actions Runner Controller (Kubernetes):
# kubectl apply -f https://github.com/actions/actions-runner-controller/releases/latest
#
# RunnerDeployment:
# spec:
#   template:
#     spec:
#       repository: myorg/myrepo
#
# HorizontalRunnerAutoscaler:
# spec:
#   scaleTargetRef:
#     name: my-runner
#   minReplicas: 0    # Scale to zero
#   maxReplicas: 20
#   metrics:
#   - type: TotalNumberOfQueuedAndInProgressWorkflowRuns
#     repositoryNames: [myrepo]
```

---

## 6. Reusable Workflows — Full Example

```yaml
# .github/workflows/reusable-test.yml
name: Reusable Test Workflow

on:
  workflow_call:
    inputs:
      python-version:
        type: string
        default: '3.12'
      test-path:
        type: string
        default: 'tests/'
      coverage-threshold:
        type: number
        default: 80
    secrets:
      TEST_DATABASE_URL:
        required: true
    outputs:
      coverage:
        description: Coverage percentage
        value: ${{ jobs.test.outputs.coverage }}

jobs:
  test:
    runs-on: ubuntu-latest
    outputs:
      coverage: ${{ steps.coverage.outputs.pct }}

    services:
      postgres:
        image: postgres:15-alpine
        env:
          POSTGRES_PASSWORD: testpassword
        ports: ['5432:5432']
        options: --health-cmd pg_isready --health-interval 5s

    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: ${{ inputs.python-version }}
        cache: pip
    - run: pip install -r requirements.txt pytest pytest-cov
    - id: coverage
      env:
        DATABASE_URL: ${{ secrets.TEST_DATABASE_URL }}
      run: |
        pytest ${{ inputs.test-path }} \
          --cov=src \
          --cov-report=term \
          --cov-fail-under=${{ inputs.coverage-threshold }}
        PCT=$(coverage report | tail -1 | awk '{print $4}' | tr -d '%')
        echo "pct=$PCT" >> $GITHUB_OUTPUT
```

---

## 7. Status Checks and PR Gates

```yaml
# Make sure every PR passes before merge
# Settings → Branches → Protection → Status checks:
# Required: ci/test, ci/lint, ci/security

name: PR Checks

on:
  pull_request:
    branches: [main]

jobs:
  # Lint
  lint:
    name: ci/lint
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - run: pip install ruff && ruff check .

  # Test
  test:
    name: ci/test
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - run: pytest tests/ -v

  # Security scan
  security:
    name: ci/security
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - uses: trufflesecurity/trufflehog@main
      with:
        base: ${{ github.event.pull_request.base.sha }}
        head: ${{ github.event.pull_request.head.sha }}

  # Add PR comment with test results
  comment-results:
    needs: [lint, test, security]
    if: always()
    runs-on: ubuntu-latest
    steps:
    - uses: actions/github-script@v7
      with:
        script: |
          const results = {
            lint: '${{ needs.lint.result }}',
            test: '${{ needs.test.result }}',
            security: '${{ needs.security.result }}'
          };
          const emoji = r => r === 'success' ? '✅' : r === 'skipped' ? '⏭️' : '❌';
          const body = `## PR Check Results\n
          | Check | Status |
          |-------|--------|
          | Lint | ${emoji(results.lint)} ${results.lint} |
          | Test | ${emoji(results.test)} ${results.test} |
          | Security | ${emoji(results.security)} ${results.security} |`;
          
          github.rest.issues.createComment({
            ...context.repo,
            issue_number: context.issue.number,
            body
          });
```

---

## 8. Multi-Cloud Deployment Matrix

```yaml
name: Multi-Cloud Deploy

on:
  workflow_dispatch:
    inputs:
      clouds:
        description: 'Clouds to deploy to (json array)'
        default: '["aws", "azure", "gcp"]'

jobs:
  deploy:
    strategy:
      matrix:
        cloud: ${{ fromJSON(github.event.inputs.clouds) }}
        include:
        - cloud: aws
          region: us-east-1
          cluster: eks-prod
        - cloud: azure
          region: eastus
          cluster: aks-prod
        - cloud: gcp
          region: us-central1
          cluster: gke-prod

    runs-on: ubuntu-latest
    environment: production-${{ matrix.cloud }}

    steps:
    - uses: actions/checkout@v4

    - name: Deploy to AWS
      if: matrix.cloud == 'aws'
      run: |
        aws eks update-kubeconfig --name ${{ matrix.cluster }} --region ${{ matrix.region }}
        kubectl apply -f k8s/

    - name: Deploy to Azure
      if: matrix.cloud == 'azure'
      run: |
        az aks get-credentials --name ${{ matrix.cluster }} --resource-group prod-rg
        kubectl apply -f k8s/

    - name: Deploy to GCP
      if: matrix.cloud == 'gcp'
      run: |
        gcloud container clusters get-credentials ${{ matrix.cluster }} --region ${{ matrix.region }}
        kubectl apply -f k8s/
```
