# GitHub Actions Interview Questions

## Q1. What is the difference between `needs`, `if`, and `depends_on` in GitHub Actions?

```yaml
jobs:
  test:
    runs-on: ubuntu-latest
    steps: [...]

  build:
    needs: test                    # Only runs if 'test' succeeds
    if: github.ref == 'refs/heads/main'  # Additional condition
    runs-on: ubuntu-latest
    steps: [...]

  notify:
    needs: [test, build]           # Waits for BOTH
    if: always()                   # Runs even if test/build failed
    steps: [...]
```

`needs` = ordering/data dependency
`if` = conditional execution
No `depends_on` in Actions — that's Terraform terminology.

---

## Q2. How do you pass data between jobs?

```yaml
jobs:
  build:
    outputs:
      image-tag: ${{ steps.meta.outputs.version }}  # Job output
    steps:
    - id: meta
      run: echo "version=abc1234" >> $GITHUB_OUTPUT  # Set step output

  deploy:
    needs: build
    steps:
    - run: echo "Deploying ${{ needs.build.outputs.image-tag }}"
```

---

## Q3. How do you cache dependencies in GitHub Actions?

```yaml
# Python
- uses: actions/setup-python@v5
  with:
    python-version: "3.12"
    cache: pip                     # Built-in cache

# Node.js
- uses: actions/setup-node@v4
  with:
    node-version: "20"
    cache: npm

# Custom cache key
- uses: actions/cache@v4
  with:
    path: ~/.cache/pip
    key: ${{ runner.os }}-pip-${{ hashFiles('requirements.txt') }}
    restore-keys: |
      ${{ runner.os }}-pip-        # Fallback partial match

# Docker layer cache
- uses: docker/build-push-action@v5
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

---

## Q4. How do you use GitHub Actions with AWS securely (no long-lived credentials)?

```yaml
# Use OIDC — GitHub gets a short-lived token from AWS
# No AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY needed!

permissions:
  id-token: write                  # Required for OIDC
  contents: read

steps:
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789:role/github-actions-role
    aws-region: us-east-1
    # GitHub exchanges OIDC token for AWS credentials automatically

# AWS IAM Trust Policy (allows GitHub Actions to assume role):
# {
#   "Principal": {
#     "Federated": "arn:aws:iam::123456789:oidc-provider/token.actions.githubusercontent.com"
#   },
#   "Condition": {
#     "StringEquals": {
#       "token.actions.githubusercontent.com:sub": "repo:myorg/myrepo:ref:refs/heads/main"
#     }
#   }
# }
```

---

## Q5. What is a matrix strategy? When do you use it?

```yaml
# Test against multiple versions/platforms simultaneously
jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        python: ["3.10", "3.11", "3.12"]
        exclude:
          - os: windows-latest
            python: "3.10"
      fail-fast: false             # Don't cancel others if one fails
    runs-on: ${{ matrix.os }}
    steps:
    - uses: actions/setup-python@v5
      with:
        python-version: ${{ matrix.python }}
    - run: pytest tests/

# Use for: cross-platform testing, multi-version compatibility
# Cost: 3 OS × 3 Python versions = 9 parallel jobs
```

---

## Q6. How do you handle secrets in GitHub Actions?

```yaml
# Secrets: Settings → Secrets and variables → Actions
# Environment secrets: only available to specific environments (with protection rules)

steps:
- name: Use secret
  env:
    DB_PASSWORD: ${{ secrets.DB_PASSWORD }}  # Available as env var
  run: echo "DB_PASSWORD is ${#DB_PASSWORD} chars"  # Never echo the value!

# Mask custom values from logs
- run: echo "::add-mask::$MY_DYNAMIC_SECRET"

# NEVER do:
# run: echo "${{ secrets.MY_SECRET }}"     ← visible in logs!
# run: curl https://api.com?key=$SECRET   ← visible in logs!
```

---

## Q7. How do you run jobs on self-hosted runners?

```yaml
# Use self-hosted runners for:
# - Access to private resources (internal APIs, databases)
# - Specific hardware (GPU, ARM, high-memory)
# - Cost savings at high volumes

jobs:
  build:
    runs-on: [self-hosted, linux, gpu]  # Label-based runner selection

# Runner setup:
# Settings → Actions → Runners → New self-hosted runner
# Install runner app, configure labels
# Run as service: ./svc.sh install && ./svc.sh start

# Security: self-hosted runners should NOT be shared across repos
# Malicious PR can run arbitrary code on your runner
```

---

## Q8. What are composite actions and when do you create one?

```yaml
# Composite action = reusable step sequence
# Create in: .github/actions/setup-app/action.yml

name: Setup Application
description: Install and configure the application

inputs:
  python-version:
    default: "3.12"

runs:
  using: composite
  steps:
  - uses: actions/setup-python@v5
    with:
      python-version: ${{ inputs.python-version }}
      cache: pip
  - run: pip install -r requirements.txt
    shell: bash
  - run: cp .env.example .env
    shell: bash

# Use in workflow:
steps:
- uses: ./.github/actions/setup-app
  with:
    python-version: "3.12"

# Create when: 5+ steps repeated across multiple workflows
```

---

## Q9. How do you implement manual approval gates?

```yaml
# Use environments with protection rules
# Settings → Environments → production → Required reviewers

jobs:
  deploy-production:
    environment:
      name: production             # Pauses here until reviewer approves
      url: https://api.company.com
    runs-on: ubuntu-latest
    steps:
    - name: Deploy
      run: ./deploy.sh

# For more control:
jobs:
  approval-check:
    runs-on: ubuntu-latest
    steps:
    - uses: trstringer/manual-approval@v1
      with:
        secret: ${{ secrets.GITHUB_TOKEN }}
        approvers: senior-engineer,team-lead
        minimum-approvals: 1
        issue-title: "Deploy v${{ github.sha }} to production?"
```

---

## Q10. How do you debug a failing GitHub Actions workflow?

```yaml
# 1. Enable debug logging
# Add secret: ACTIONS_RUNNER_DEBUG = true
# Add secret: ACTIONS_STEP_DEBUG = true

# 2. Check step outputs carefully
- run: |
    echo "Working directory: $(pwd)"
    ls -la
    env | sort

# 3. Use tmate for SSH debugging (interactive session)
- uses: mxschmitt/action-tmate@v3
  if: failure()                    # Only open SSH if workflow fails

# 4. Re-run with debug mode enabled
# Actions UI → Re-run jobs → Enable debug logging

# 5. Check runner logs
# Actions UI → job → failed step → click to expand → scroll to error
```

---

## Q11. How do you trigger workflows between repositories?

```yaml
# Method 1: repository_dispatch (explicit trigger)
# From external system:
curl -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  https://api.github.com/repos/myorg/myrepo/dispatches \
  -d '{"event_type":"deploy","client_payload":{"version":"1.2.3"}}'

# In target repo:
on:
  repository_dispatch:
    types: [deploy]
steps:
- run: echo "Version: ${{ github.event.client_payload.version }}"

# Method 2: workflow_dispatch (manual trigger with inputs)
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [staging, production]
      version:
        type: string
        required: true
```

---

## Q12. What is the GITHUB_TOKEN and what can it do?

```yaml
# Automatically created per workflow run
# Permissions scoped to the repository
# Expires when workflow ends

permissions:
  contents: read        # Default: can read repo
  packages: write       # Push to GHCR
  pull-requests: write  # Comment on PRs
  issues: write         # Create/update issues
  id-token: write       # OIDC for AWS/GCP

# Use it:
steps:
- uses: actions/checkout@v4
  with:
    token: ${{ secrets.GITHUB_TOKEN }}  # Implicit — checkout uses this by default

# Best practice: request minimum permissions
# Set at workflow level or job level
```

---

## Q13. How do you prevent a workflow from running on draft PRs?

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

jobs:
  test:
    if: github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    steps: [...]
```

---

## Q14. How do you implement a monorepo CI strategy?

```yaml
on:
  push:
    paths:
      - 'services/api/**'
      - 'libs/common/**'  # Also trigger if shared lib changes

jobs:
  detect-changes:
    outputs:
      api: ${{ steps.filter.outputs.api }}
      frontend: ${{ steps.filter.outputs.frontend }}
    steps:
    - uses: dorny/paths-filter@v3
      id: filter
      with:
        filters: |
          api:
          - 'services/api/**'
          - 'libs/common/**'
          frontend:
          - 'services/frontend/**'
          - 'libs/common/**'

  test-api:
    needs: detect-changes
    if: needs.detect-changes.outputs.api == 'true'
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: services/api
    steps:
    - uses: actions/checkout@v4
    - run: npm test
```

---

## Q15. What are GitHub Actions best practices for security?

```yaml
# 1. Pin action versions to SHA, not tags (prevent supply chain attacks)
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.1.1
# NOT: uses: actions/checkout@v4  (tag can be moved by attacker)

# 2. Use minimum permissions
permissions:
  contents: read           # Least privilege

# 3. Never trust PR from fork with secrets
# Forks don't get secrets by default — good!
# Use pull_request_target carefully (has access to secrets)

# 4. Review third-party actions before using
# Check: stars, last update, source code, permissions requested

# 5. Use environments for production with protection rules
# Required reviewers, deployment branches restriction

# 6. Audit your workflows regularly
# Settings → Actions → General → Allow actions from verified creators only
```
