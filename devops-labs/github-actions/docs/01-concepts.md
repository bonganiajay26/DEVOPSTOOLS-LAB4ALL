# GitHub Actions Core Concepts

## Architecture

```
GitHub Event (push, PR, schedule, manual)
         │
         ▼
   Workflow (.github/workflows/*.yml)
         │
    ┌────┴────┐
    │         │
  Job 1     Job 2     ← Run in parallel by default
    │         │        ← or in sequence with needs:
  Step 1   Step 1
  Step 2   Step 2
  Step 3   Step 3
```

---

## Key Components

### Workflows
YAML files in `.github/workflows/`. Triggered by events.

```yaml
name: My Workflow
on: [push, pull_request]  # Triggers

jobs:
  my-job:
    runs-on: ubuntu-latest
    steps:
    - name: My Step
      run: echo "Hello!"
```

### Events (Triggers)

```yaml
on:
  # Git events
  push:
    branches: [main, 'release/**']
    tags: ['v*']
    paths: ['src/**', '!docs/**']   # paths-ignore also available

  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
    branches: [main]

  # Manual trigger
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [staging, production]
        required: true

  # Scheduled
  schedule:
  - cron: '0 6 * * 1-5'    # Weekdays 6 AM UTC

  # Called by another workflow
  workflow_call:
    inputs:
      version:
        type: string
        required: true

  # External trigger via API
  repository_dispatch:
    types: [deploy, rollback]
```

### Jobs

```yaml
jobs:
  build:
    runs-on: ubuntu-latest   # GitHub-hosted runner
    # runs-on: [self-hosted, linux, gpu]  # Self-hosted
    
    timeout-minutes: 30      # Kill job after 30 min
    
    strategy:
      fail-fast: false        # Don't cancel sibling jobs on failure
      matrix:
        node: [18, 20]
        os: [ubuntu-latest, windows-latest]
    
    permissions:
      contents: read
      packages: write
    
    env:
      NODE_VERSION: ${{ matrix.node }}
```

### Steps

```yaml
steps:
# Use a public action
- uses: actions/checkout@v4
  with:
    fetch-depth: 0   # Full history (needed for some tools)

# Run a shell command
- name: Install deps
  run: npm ci
  working-directory: ./frontend

# Multi-line script
- name: Build and test
  shell: bash
  run: |
    set -e
    npm run build
    npm test

# Conditional step
- name: Deploy
  if: github.ref == 'refs/heads/main' && github.event_name == 'push'
  run: ./deploy.sh

# Step with output
- name: Get version
  id: version
  run: echo "version=$(cat VERSION)" >> $GITHUB_OUTPUT

- name: Use version
  run: echo "Deploying ${{ steps.version.outputs.version }}"
```

---

## Contexts

GitHub Actions exposes rich context via `${{ }}` syntax:

```yaml
# github context — event and repo info
github.actor           # Who triggered the workflow
github.event_name      # push, pull_request, etc.
github.ref             # refs/heads/main
github.sha             # Full commit SHA
github.repository      # org/repo
github.run_id          # Unique workflow run ID
github.run_number      # Incrementing run count

# env context
env.MY_VAR

# job context
job.status             # success, failure, cancelled

# steps context
steps.my-step.outputs.my-output
steps.my-step.conclusion   # success, failure, skipped

# runner context
runner.os              # Linux, Windows, macOS
runner.arch            # X64, ARM64
runner.temp            # Temp directory path

# secrets context
secrets.MY_SECRET      # Masked in logs

# matrix context
matrix.node            # Current matrix value

# needs context (job outputs)
needs.build.outputs.image-tag
needs.build.result     # success, failure
```

---

## Expressions

```yaml
# Conditionals
if: success()
if: failure()
if: always()        # Run even if previous steps failed
if: cancelled()

# Combined conditions
if: github.event_name == 'push' && github.ref == 'refs/heads/main'
if: contains(github.event.pull_request.labels.*.name, 'deploy')
if: startsWith(github.ref, 'refs/tags/v')

# Ternary-like
- run: echo "${{ github.event_name == 'push' && 'pushed' || 'not pushed' }}"

# fromJSON
- run: echo "${{ fromJSON('["a","b","c"]')[0] }}"
```

---

## Environment Variables

```yaml
# Workflow-level (all jobs inherit)
env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}

jobs:
  build:
    # Job-level (this job only)
    env:
      BUILD_ENV: production

    steps:
    - name: Set dynamic env
      run: echo "TIMESTAMP=$(date +%s)" >> $GITHUB_ENV
    
    - name: Use it
      run: echo $TIMESTAMP   # Available in subsequent steps
```

---

## Artifacts and Caching

```yaml
# Upload artifact (persist between jobs or download after workflow)
- uses: actions/upload-artifact@v4
  with:
    name: build-output
    path: dist/
    retention-days: 7

# Download artifact
- uses: actions/download-artifact@v4
  with:
    name: build-output
    path: dist/

# Cache dependencies (across workflow runs)
- uses: actions/cache@v4
  with:
    path: ~/.npm
    key: ${{ runner.os }}-npm-${{ hashFiles('package-lock.json') }}
    restore-keys: |
      ${{ runner.os }}-npm-

# Cache Docker layers
- uses: docker/build-push-action@v5
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

---

## Secrets and Variables

```yaml
# GitHub Settings → Secrets and variables → Actions

# Repository secret (all workflows in repo)
- run: echo ${{ secrets.DATABASE_PASSWORD }}

# Environment secret (only for specific environment)
jobs:
  deploy:
    environment: production      # Uses production env secrets
    steps:
    - run: echo ${{ secrets.PROD_DB_URL }}

# Configuration variables (non-sensitive, visible in logs)
vars.APP_VERSION    # Set in Settings → Variables

# Auto-generated per-run
secrets.GITHUB_TOKEN   # Scoped to repo, expires after run

# Organization secrets (all repos in org)
# Set in: Organization Settings → Secrets
```

---

## Composite Actions (Reusable Steps)

```yaml
# .github/actions/setup-node/action.yml
name: 'Setup Node.js App'
description: 'Install Node.js and dependencies'

inputs:
  node-version:
    description: 'Node.js version'
    default: '20'
  install-command:
    description: 'Install command'
    default: 'npm ci'

outputs:
  cache-hit:
    description: 'Whether cache was used'
    value: ${{ steps.cache.outputs.cache-hit }}

runs:
  using: composite
  steps:
  - uses: actions/setup-node@v4
    with:
      node-version: ${{ inputs.node-version }}
  - id: cache
    uses: actions/cache@v4
    with:
      path: node_modules
      key: node-${{ inputs.node-version }}-${{ hashFiles('package-lock.json') }}
  - run: ${{ inputs.install-command }}
    shell: bash
    if: steps.cache.outputs.cache-hit != 'true'

# Use it:
# - uses: ./.github/actions/setup-node
#   with:
#     node-version: '20'
```
