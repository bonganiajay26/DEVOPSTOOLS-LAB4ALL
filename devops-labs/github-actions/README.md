# GitHub Actions

> **Automate every step of your software lifecycle — from PR to production.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | Workflows, jobs, steps, events, runners |
| [docs/02-advanced.md](docs/02-advanced.md) | Reusable workflows, matrix, caching, OIDC |
| [examples/](examples/) | 10 production pipeline templates |
| [labs/](labs/) | 3 hands-on labs |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## Core Syntax

```yaml
# .github/workflows/ci.yml
name: CI

on:                               # Trigger events
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 6 * * 1'          # Every Monday 6am UTC

jobs:
  test:
    runs-on: ubuntu-latest        # Runner
    steps:
    - uses: actions/checkout@v4  # Checkout code
    - run: npm ci                 # Shell command
    - run: npm test
```
