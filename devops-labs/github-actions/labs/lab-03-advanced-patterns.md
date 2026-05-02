# Lab 03: Advanced GitHub Actions Patterns

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Build reusable workflows, implement OIDC auth, dynamic matrices, and self-hosted runners.

---

## Part 1: Reusable Workflow Library

### Create a shared workflow repository

```bash
# In your organization: create repo called .github
# This is a special repo for org-wide defaults

mkdir -p .github/workflows

# .github/workflows/reusable-python-test.yml
cat > .github/workflows/reusable-python-test.yml << 'EOF'
name: Reusable Python Test

on:
  workflow_call:
    inputs:
      python-versions:
        type: string
        default: '["3.11", "3.12"]'
      test-path:
        type: string
        default: tests/
      coverage-min:
        type: number
        default: 80
      working-directory:
        type: string
        default: .
    secrets:
      DB_URL:
        required: false
    outputs:
      coverage-pct:
        description: "Test coverage percentage"
        value: ${{ jobs.test.outputs.coverage }}

jobs:
  test:
    runs-on: ubuntu-latest
    outputs:
      coverage: ${{ steps.cov.outputs.pct }}

    strategy:
      matrix:
        python-version: ${{ fromJSON(inputs.python-versions) }}

    defaults:
      run:
        working-directory: ${{ inputs.working-directory }}

    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: ${{ matrix.python-version }}
        cache: pip

    - run: pip install -r requirements-dev.txt

    - id: cov
      run: |
        pytest ${{ inputs.test-path }} \
          --cov=. \
          --cov-report=xml \
          --cov-fail-under=${{ inputs.coverage-min }}
        PCT=$(python -c "import xml.etree.ElementTree as ET; t=ET.parse('coverage.xml').getroot(); print(round(float(t.get('line-rate', 0))*100))")
        echo "pct=$PCT" >> $GITHUB_OUTPUT
      env:
        DATABASE_URL: ${{ secrets.DB_URL }}
EOF
```

### Call the reusable workflow

```yaml
# In any repo: .github/workflows/ci.yml
name: CI

on: [push, pull_request]

jobs:
  test:
    uses: myorg/.github/.github/workflows/reusable-python-test.yml@main
    with:
      python-versions: '["3.12"]'
      coverage-min: 85
      test-path: tests/unit/
    secrets:
      DB_URL: ${{ secrets.TEST_DATABASE_URL }}

  report:
    needs: test
    runs-on: ubuntu-latest
    steps:
    - run: echo "Coverage: ${{ needs.test.outputs.coverage-pct }}%"
```

---

## Part 2: Dynamic Matrix from Changed Files

```bash
cat > .github/workflows/monorepo-ci.yml << 'EOF'
name: Monorepo CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  # Step 1: Detect which services changed
  changes:
    runs-on: ubuntu-latest
    outputs:
      services: ${{ steps.detect.outputs.services }}
      has-changes: ${{ steps.detect.outputs.has-changes }}

    steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0    # Need full history for diff

    - id: detect
      run: |
        # Get changed files
        BASE="${{ github.event.pull_request.base.sha || 'HEAD~1' }}"

        # Find changed service directories
        SERVICES=$(git diff --name-only $BASE HEAD | \
          grep "^services/" | \
          awk -F/ '{print $2}' | \
          sort -u | \
          jq -Rcs 'split("\n")[:-1]')

        echo "services=$SERVICES" >> $GITHUB_OUTPUT

        if [ "$SERVICES" = "[]" ]; then
          echo "has-changes=false" >> $GITHUB_OUTPUT
        else
          echo "has-changes=true" >> $GITHUB_OUTPUT
          echo "Changed services: $SERVICES"
        fi

  # Step 2: Test only changed services
  test-services:
    needs: changes
    if: needs.changes.outputs.has-changes == 'true'
    strategy:
      fail-fast: false
      matrix:
        service: ${{ fromJSON(needs.changes.outputs.services) }}

    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: services/${{ matrix.service }}

    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: '3.12'
        cache: pip
    - run: pip install -r requirements.txt
    - run: pytest tests/ -v
    - name: Build Docker image for changed service
      run: docker build -t ${{ matrix.service }}:test .
EOF
```

---

## Part 3: OIDC + Multiple Cloud Providers

```bash
cat > .github/workflows/multi-cloud-oidc.yml << 'EOF'
name: Multi-Cloud Deploy with OIDC

on:
  workflow_dispatch:
    inputs:
      cloud:
        type: choice
        options: [aws, gcp, azure, all]
        description: Target cloud

jobs:
  deploy-aws:
    if: inputs.cloud == 'aws' || inputs.cloud == 'all'
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
    - uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
        aws-region: us-east-1
    - run: aws sts get-caller-identity
    - run: aws eks update-kubeconfig --name prod-cluster --region us-east-1
    - run: kubectl apply -f k8s/

  deploy-gcp:
    if: inputs.cloud == 'gcp' || inputs.cloud == 'all'
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
    - uses: google-github-actions/auth@v2
      with:
        workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
        service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
    - uses: google-github-actions/setup-gcloud@v2
    - run: gcloud container clusters get-credentials prod-cluster --region us-central1
    - run: kubectl apply -f k8s/

  deploy-azure:
    if: inputs.cloud == 'azure' || inputs.cloud == 'all'
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read

    steps:
    - uses: azure/login@v2
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    - uses: azure/aks-set-context@v3
      with:
        resource-group: prod-rg
        cluster-name: prod-cluster
    - run: kubectl apply -f k8s/
EOF
```

---

## Part 4: Self-Hosted Runner Setup

```bash
# On a server/VM with special requirements (GPU, private network):

# 1. Register the runner in GitHub:
# Settings → Actions → Runners → New self-hosted runner

# 2. Install runner
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64-2.313.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.313.0/actions-runner-linux-x64-2.313.0.tar.gz
tar xzf ./actions-runner-linux-x64-2.313.0.tar.gz

# 3. Configure (token from GitHub Settings)
./config.sh \
  --url https://github.com/YOUR_ORG/YOUR_REPO \
  --token YOUR_TOKEN \
  --name my-gpu-runner \
  --labels self-hosted,linux,gpu,private-network \
  --work _work

# 4. Install as service
sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status

# 5. Use in workflow:
cat > .github/workflows/gpu-training.yml << 'EOF'
name: GPU Training Job

on:
  workflow_dispatch:

jobs:
  train:
    runs-on: [self-hosted, linux, gpu]    # Requires our GPU runner

    steps:
    - uses: actions/checkout@v4
    - run: nvidia-smi
    - run: python train.py --epochs 100 --batch-size 64
    - uses: actions/upload-artifact@v4
      with:
        name: trained-model
        path: models/
EOF

# Scale with Kubernetes (Actions Runner Controller):
# helm repo add actions-runner-controller \
#   https://actions-runner-controller.github.io/actions-runner-controller
# helm install arc actions-runner-controller/actions-runner-controller \
#   --namespace arc-systems --create-namespace
```

---

## Part 5: Workflow Debugging

```bash
cat > .github/workflows/debug-workflow.yml << 'EOF'
name: Debug Pipeline Issue

on:
  workflow_dispatch:

jobs:
  debug:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    # Enable debug logging
    - name: Enable debug
      run: echo "ACTIONS_RUNNER_DEBUG=true" >> $GITHUB_ENV

    # Print all context info
    - name: Dump GitHub Context
      run: |
        echo "github.actor:      ${{ github.actor }}"
        echo "github.event_name: ${{ github.event_name }}"
        echo "github.ref:        ${{ github.ref }}"
        echo "github.sha:        ${{ github.sha }}"
        echo "github.run_id:     ${{ github.run_id }}"
        echo "runner.os:         ${{ runner.os }}"
        echo "runner.arch:       ${{ runner.arch }}"

    - name: Print environment
      run: env | sort | grep -v SECRET

    - name: Check available tools
      run: |
        which docker && docker --version
        which kubectl && kubectl version --client
        which helm && helm version
        which terraform && terraform version
        which python3 && python3 --version

    # SSH debug session on failure (interactive debugging)
    - name: SSH Debug Session
      if: failure()
      uses: mxschmitt/action-tmate@v3
      timeout-minutes: 15
      with:
        limit-access-to-actor: true   # Only the workflow actor can SSH in
EOF
```

---

## What You Learned

- [x] Building and calling reusable workflows
- [x] Dynamic matrix from changed files (monorepo pattern)
- [x] OIDC authentication for AWS, GCP, and Azure
- [x] Self-hosted runner setup and management
- [x] Workflow debugging with tmate SSH session
- [x] Composite actions for DRY step sequences
