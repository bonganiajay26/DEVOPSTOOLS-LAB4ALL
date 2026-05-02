# GitHub Actions Use Cases

## 1. Automated Dependency Updates

```yaml
# .github/workflows/dependency-update.yml
name: Weekly Dependency Update

on:
  schedule:
  - cron: '0 9 * * 1'  # Monday 9 AM
  workflow_dispatch:

jobs:
  update-python:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
      with:
        token: ${{ secrets.GITHUB_TOKEN }}

    - uses: actions/setup-python@v5
      with:
        python-version: '3.12'

    - name: Update dependencies
      run: |
        pip install pip-tools
        pip-compile --upgrade requirements.in -o requirements.txt
        pip-compile --upgrade requirements-dev.in -o requirements-dev.txt

    - name: Run tests with new deps
      run: pytest tests/ -q

    - name: Create PR if changes
      uses: peter-evans/create-pull-request@v6
      with:
        token: ${{ secrets.GITHUB_TOKEN }}
        branch: chore/dependency-update-${{ github.run_number }}
        title: 'chore(deps): weekly dependency update'
        body: |
          Automated weekly dependency update.
          
          - [ ] Review changes
          - [ ] Tests pass
          - [ ] Check security advisories
        labels: dependencies, automated
        assignees: platform-team
```

---

## 2. Infrastructure Drift Detection

```yaml
# .github/workflows/infra-drift.yml
name: Infrastructure Drift Check

on:
  schedule:
  - cron: '0 */4 * * *'  # Every 4 hours
  workflow_dispatch:

jobs:
  terraform-plan:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
      issues: write

    strategy:
      matrix:
        environment: [staging, production]

    steps:
    - uses: actions/checkout@v4

    - uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: ${{ vars[format('AWS_ROLE_{0}', matrix.environment)] }}
        aws-region: us-east-1

    - uses: hashicorp/setup-terraform@v3

    - name: Terraform plan
      id: plan
      run: |
        cd environments/${{ matrix.environment }}
        terraform init
        terraform plan -out=plan.tfplan -detailed-exitcode 2>&1
        echo "exitcode=$?" >> $GITHUB_OUTPUT
      continue-on-error: true

    - name: Create issue on drift
      if: steps.plan.outputs.exitcode == '2'
      uses: actions/github-script@v7
      with:
        script: |
          const title = `🔀 Infrastructure drift detected in ${{ matrix.environment }}`;
          const body = `## Drift Detection Alert
          
          Terraform plan shows changes not in Git.
          
          **Environment**: ${{ matrix.environment }}
          **Detected at**: ${new Date().toISOString()}
          
          Run \`terraform plan\` in \`environments/${{ matrix.environment }}\` to see details.
          
          Assign to infrastructure team to review and reconcile.`;
          
          // Check if issue already exists
          const issues = await github.rest.issues.listForRepo({
            ...context.repo,
            state: 'open',
            labels: 'infrastructure-drift'
          });
          
          if (!issues.data.some(i => i.title === title)) {
            await github.rest.issues.create({
              ...context.repo,
              title,
              body,
              labels: ['infrastructure-drift', '${{ matrix.environment }}']
            });
          }
```

---

## 3. Release Automation

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      packages: write

    steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0    # Full history for changelog

    - name: Generate changelog
      id: changelog
      run: |
        PREV_TAG=$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo "")
        {
          echo "notes<<EOF"
          echo "## What's Changed"
          echo ""
          echo "### 🚀 Features"
          git log ${PREV_TAG:+$PREV_TAG..}HEAD --pretty="- %s (%h)" --grep="^feat" | sed 's/feat[^:]*: //'
          echo ""
          echo "### 🐛 Bug Fixes"
          git log ${PREV_TAG:+$PREV_TAG..}HEAD --pretty="- %s (%h)" --grep="^fix" | sed 's/fix[^:]*: //'
          echo "EOF"
        } >> $GITHUB_OUTPUT

    - name: Build Docker image
      run: |
        docker build -t ghcr.io/${{ github.repository }}:${{ github.ref_name }} .
        docker push ghcr.io/${{ github.repository }}:${{ github.ref_name }}

    - name: Create GitHub Release
      uses: actions/create-release@v1
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      with:
        tag_name: ${{ github.ref_name }}
        release_name: Release ${{ github.ref_name }}
        body: ${{ steps.changelog.outputs.notes }}
        draft: false
        prerelease: ${{ contains(github.ref_name, '-rc') || contains(github.ref_name, '-beta') }}
```

---

## 4. Automated Security Scanning

```yaml
# .github/workflows/security.yml
name: Security Scans

on:
  push:
    branches: [main]
  pull_request:
  schedule:
  - cron: '0 0 * * 0'  # Weekly full scan

jobs:
  # SAST - Static Application Security Testing
  codeql:
    runs-on: ubuntu-latest
    permissions:
      security-events: write
    steps:
    - uses: actions/checkout@v4
    - uses: github/codeql-action/init@v3
      with:
        languages: python,javascript
    - uses: github/codeql-action/autobuild@v3
    - uses: github/codeql-action/analyze@v3

  # Container image scanning
  trivy:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Build image
      run: docker build -t myapp:scan .
    - uses: aquasecurity/trivy-action@master
      with:
        image-ref: myapp:scan
        format: sarif
        output: trivy.sarif
        severity: CRITICAL,HIGH
        exit-code: 1
    - uses: github/codeql-action/upload-sarif@v3
      if: always()
      with:
        sarif_file: trivy.sarif

  # Dependency vulnerability scanning
  snyk:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - uses: snyk/actions/python@master
      env:
        SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
      with:
        args: --severity-threshold=high

  # Secret scanning
  secrets:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - uses: trufflesecurity/trufflehog@main
      with:
        base: ${{ github.event.pull_request.base.sha }}
        extra_args: --results=verified,unknown
```

---

## 5. Deployment Pipeline with Progressive Rollout

```yaml
# .github/workflows/progressive-deploy.yml
name: Progressive Deployment

on:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image: ${{ steps.image.outputs.ref }}
    steps:
    - uses: actions/checkout@v4
    - id: image
      run: |
        IMAGE=ghcr.io/${{ github.repository }}:${{ github.sha }}
        docker build -t $IMAGE .
        docker push $IMAGE
        echo "ref=$IMAGE" >> $GITHUB_OUTPUT

  # Stage 1: Deploy to 10% canary
  canary:
    needs: build
    runs-on: ubuntu-latest
    environment: canary
    steps:
    - uses: actions/checkout@v4
    - run: |
        # Update canary deployment to new image
        kubectl set image deployment/api-canary \
          api=${{ needs.build.outputs.image }} -n production
        kubectl rollout status deployment/api-canary -n production

    - name: Wait and check error rate
      run: |
        sleep 300    # 5 minutes
        ERROR_RATE=$(curl -s "http://prometheus/api/v1/query" \
          --data-urlencode 'query=rate(http_errors_total{deployment="canary"}[5m])' | \
          jq '.data.result[0].value[1]')
        echo "Canary error rate: $ERROR_RATE"
        if (( $(echo "$ERROR_RATE > 0.01" | bc -l) )); then
          echo "❌ Canary error rate too high!"
          exit 1
        fi
        echo "✅ Canary healthy, proceeding to full rollout"

  # Stage 2: Full rollout (requires healthy canary)
  production:
    needs: [build, canary]
    runs-on: ubuntu-latest
    environment: production
    steps:
    - run: |
        kubectl set image deployment/api \
          api=${{ needs.build.outputs.image }} -n production
        kubectl rollout status deployment/api -n production --timeout=10m
    - name: Rollback on failure
      if: failure()
      run: kubectl rollout undo deployment/api -n production
```
