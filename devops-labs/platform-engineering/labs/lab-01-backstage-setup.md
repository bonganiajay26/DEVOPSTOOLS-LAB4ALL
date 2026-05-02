# Lab 01: Set Up Backstage Developer Portal

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Install Backstage locally, add a service catalog, and create a golden-path software template.

---

## Part 1: Install Backstage

```bash
# Prerequisites
node --version    # >= 18
yarn --version    # >= 1.22

# Create a new Backstage app
npx @backstage/create-app@latest --skip-install

# Enter a name: my-developer-portal
cd my-developer-portal

# Install dependencies
yarn install

# Start the development server
yarn dev
# Open: http://localhost:3000
```

---

## Part 2: Add Your First Component to the Catalog

```bash
mkdir -p examples/catalog
cat > examples/catalog/api-service.yaml << 'EOF'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: api-service
  title: API Service
  description: Core REST API for the platform
  annotations:
    github.com/project-slug: myorg/api-service
    backstage.io/techdocs-ref: dir:.
  tags:
    - python
    - flask
    - production
  links:
    - url: https://grafana.company.com
      title: Grafana Dashboard
      icon: dashboard
spec:
  type: service
  lifecycle: production
  owner: group:backend-team
  system: main-platform
---
apiVersion: backstage.io/v1alpha1
kind: Group
metadata:
  name: backend-team
  title: Backend Team
spec:
  type: team
  profile:
    displayName: Backend Team
  members:
    - user:alice
    - user:bob
---
apiVersion: backstage.io/v1alpha1
kind: User
metadata:
  name: alice
spec:
  profile:
    displayName: Alice Developer
    email: alice@company.com
  memberOf:
    - backend-team
EOF
```

```yaml
# app-config.yaml — add catalog locations
catalog:
  locations:
    - type: file
      target: ../../examples/catalog/*.yaml
      rules:
        - allow: [Component, System, API, Group, User, Resource, Location]
```

```bash
# Restart Backstage
yarn dev
# Visit http://localhost:3000/catalog
# You should see "api-service" in the catalog!
```

---

## Part 3: Add TechDocs

```bash
# TechDocs: write docs in markdown, serve from Backstage

mkdir -p docs
cat > docs/index.md << 'EOF'
# API Service Documentation

## Overview
The API Service is the core REST API for our platform.

## Architecture
```
Client → Load Balancer → API Service → PostgreSQL
                               ↓
                             Redis (cache)
```

## Getting Started
1. Clone the repository
2. Install dependencies: `pip install -r requirements.txt`
3. Run locally: `python app.py`

## API Reference
| Endpoint | Method | Description |
|----------|--------|-------------|
| /health  | GET    | Health check |
| /api/v1/users | GET | List users |
| /api/v1/users | POST | Create user |
EOF

cat > mkdocs.yml << 'EOF'
site_name: API Service
docs_dir: docs
nav:
  - Home: index.md
plugins:
  - techdocs-core
EOF

# Add mkdocs annotation to catalog entry
# backstage.io/techdocs-ref: dir:.

# Install techdocs CLI
pip install mkdocs mkdocs-techdocs-core

# Preview docs locally
npx @techdocs/cli serve
# Open: http://localhost:3000/docs/default/component/api-service
```

---

## Part 4: Create a Software Template (Golden Path)

```bash
mkdir -p examples/templates

cat > examples/templates/python-service-template.yaml << 'EOF'
apiVersion: scaffolder.backstage.io/v1beta3
kind: Template
metadata:
  name: python-microservice
  title: Python Microservice
  description: Creates a production-ready Python Flask microservice
  tags:
    - python
    - flask
    - recommended
spec:
  owner: group:platform-team
  type: service

  parameters:
    - title: Service Information
      required:
        - name
        - description
        - owner
      properties:
        name:
          title: Service Name
          type: string
          description: Lowercase letters and hyphens only
          pattern: '^[a-z][a-z0-9-]{2,30}$'
          ui:autofocus: true
        description:
          title: Description
          type: string
          description: What does this service do?
        owner:
          title: Team Owner
          type: string
          ui:field: OwnerPicker
          ui:options:
            catalogFilter:
              - kind: Group
        needs_database:
          title: Needs PostgreSQL?
          type: boolean
          default: false

    - title: Repository
      required:
        - repoUrl
      properties:
        repoUrl:
          title: Repository Location
          type: string
          ui:field: RepoUrlPicker
          ui:options:
            allowedHosts:
              - github.com

  steps:
    - id: fetch-base
      name: Fetch Base Template
      action: fetch:template
      input:
        url: ./skeleton
        values:
          name: ${{ parameters.name }}
          description: ${{ parameters.description }}
          owner: ${{ parameters.owner }}
          has_database: ${{ parameters.needs_database }}

    - id: publish
      name: Publish to GitHub
      action: publish:github
      input:
        allowedHosts: ['github.com']
        description: ${{ parameters.description }}
        repoUrl: ${{ parameters.repoUrl }}
        defaultBranch: main
        topics:
          - python
          - microservice

    - id: register
      name: Register Component in Catalog
      action: catalog:register
      input:
        repoContentsUrl: ${{ steps.publish.output.repoContentsUrl }}
        catalogInfoPath: /catalog-info.yaml

  output:
    links:
      - title: Repository
        url: ${{ steps.publish.output.remoteUrl }}
        icon: github
      - title: Open in Backstage
        url: ${{ steps.register.output.entityRef }}
        icon: catalog
EOF
```

### Create the template skeleton

```bash
mkdir -p examples/templates/skeleton

cat > examples/templates/skeleton/catalog-info.yaml << 'EOF'
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: ${{ values.name }}
  description: ${{ values.description }}
  annotations:
    github.com/project-slug: ${{ values.repoUrl | parseRepoUrl | pick('owner', 'repo') | join('/') }}
spec:
  type: service
  lifecycle: experimental
  owner: ${{ values.owner }}
EOF

cat > examples/templates/skeleton/README.md << 'EOF'
# ${{ values.name }}

${{ values.description }}

## Getting Started

```bash
pip install -r requirements.txt
python app.py
```

## API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | /health | Health check |
EOF

cat > examples/templates/skeleton/app.py << 'EOF'
from flask import Flask, jsonify
import os

app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify({"status": "healthy", "service": "${{ values.name }}"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", 8080)))
EOF
```

```yaml
# Add template to app-config.yaml
catalog:
  locations:
    - type: file
      target: ../../examples/templates/python-service-template.yaml
```

```bash
# Restart and visit: http://localhost:3000/create
# You should see "Python Microservice" template!
# Fill in the form → creates GitHub repo + registers in catalog
```

---

## Part 5: Add Plugins

```bash
# Install GitHub plugin (shows PRs, build status)
yarn add --cwd packages/app @backstage/plugin-github-pull-requests-board
yarn add --cwd packages/backend @backstage/plugin-catalog-backend-module-github

# Install Kubernetes plugin (shows pod status)
yarn add --cwd packages/app @backstage/plugin-kubernetes
yarn add --cwd packages/backend @backstage/plugin-kubernetes-backend

# Configure Kubernetes in app-config.yaml:
# kubernetes:
#   serviceLocatorMethod:
#     type: multiTenant
#   clusterLocatorMethods:
#     - type: config
#       clusters:
#         - url: https://my-k8s-cluster-api
#           name: production
#           authProvider: serviceAccount
#           serviceAccountToken: <token>
#           caData: <base64-ca>

# Annotate your catalog component:
# annotations:
#   backstage.io/kubernetes-id: my-service-name
#   backstage.io/kubernetes-namespace: production
```

---

## Cleanup

```bash
# Stop the dev server
# Ctrl+C

# Optional: remove the app
# cd ..
# rm -rf my-developer-portal
```

## What You Learned

- [x] Installing and running Backstage locally
- [x] Adding components to the software catalog
- [x] TechDocs for documentation-as-code
- [x] Creating a software template (golden path)
- [x] Template skeleton for consistent new service creation
- [x] Adding Kubernetes and GitHub plugins
