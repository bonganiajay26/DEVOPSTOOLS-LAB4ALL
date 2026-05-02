# Git Core Concepts

## The Object Model

Everything in Git is a content-addressable object stored as SHA-1 hash.

```
Objects:
  blob    → file content
  tree    → directory listing (points to blobs + other trees)
  commit  → snapshot (points to tree + parent commits + metadata)
  tag     → named pointer to a commit

Refs:
  branch  → mutable pointer to a commit (moves forward on new commits)
  HEAD    → pointer to current branch (or commit in detached state)
  tag     → immutable pointer to a commit
  remote  → pointer to remote branch (origin/main)
```

### What a commit really is

```
commit abc1234
├── tree def5678           ← root directory snapshot
│   ├── blob aaa111  src/app.py
│   ├── blob bbb222  src/utils.py
│   └── tree ccc333  tests/
│       └── blob ddd444  tests/test_app.py
├── parent 9876543         ← previous commit
├── author  Jane Doe <jane@co.com>
├── committer Jane Doe
└── message "feat: add login endpoint"
```

Git stores **snapshots**, not diffs. Diffs are computed on-the-fly.

---

## The Three Trees

```
Working Directory  →  Index (Staging Area)  →  Repository
   (disk)                   (cache)              (.git/)

git add    moves Working Dir changes → Index
git commit moves Index changes       → Repository
git reset  moves Repository changes  → Index or Working Dir
```

---

## Branching Internals

A branch is just a 41-byte file containing a commit SHA.

```bash
cat .git/refs/heads/main
# abc1234def5678...

# Create a branch = write a new file
echo "abc1234..." > .git/refs/heads/my-branch
# (git branch does this safely)
```

Merging strategies:
```
Fast-forward merge (no divergence):
  main:    A → B → C
  branch:  A → B → C → D → E
  result:  A → B → C → D → E  (main pointer moves forward, no merge commit)

3-way merge (diverged):
  main:    A → B → C → M (merge commit)
  branch:  A → B → D → E ↗
  
Rebase (rewrites history):
  Before: main: A → B → C
          feat: A → D → E
  After:  main: A → B → C
          feat: A → B → C → D' → E'  (D,E rewritten with C as new base)
  Advantage: Linear history, easier to read, easier to bisect
```

---

## Conventional Commits

Industry standard for commit messages:
```
<type>(<scope>): <description>

[optional body]

[optional footer]

Types:
  feat     → new feature (triggers minor version bump)
  fix      → bug fix (triggers patch version bump)
  docs     → documentation only
  style    → formatting, no logic change
  refactor → code change, no feature/fix
  test     → adding/changing tests
  chore    → build, CI, deps
  perf     → performance improvement
  ci       → CI configuration changes
  BREAKING CHANGE → major version bump

Examples:
  feat(auth): add OAuth2 login with Google
  fix(api): handle null response from payment gateway
  chore(deps): upgrade flask from 2.2 to 3.0
  feat!: rename /users endpoint to /accounts (BREAKING CHANGE)
```

---

## Git Hooks

Automate quality checks before/after git operations.

```bash
# .git/hooks/pre-commit  (runs before commit)
#!/bin/bash
# Run tests
pytest tests/ -q --tb=short
if [ $? -ne 0 ]; then
  echo "Tests failed — commit aborted"
  exit 1
fi

# Run linter
flake8 src/
if [ $? -ne 0 ]; then
  echo "Lint errors — commit aborted"
  exit 1
fi

# .git/hooks/commit-msg  (validates commit message format)
#!/bin/bash
commit_msg=$(cat "$1")
pattern="^(feat|fix|docs|style|refactor|test|chore|perf|ci)(\(.+\))?: .{1,72}"
if ! echo "$commit_msg" | grep -qE "$pattern"; then
  echo "Commit message must follow conventional commits format"
  exit 1
fi
```

Use **pre-commit** framework for team-shared hooks:
```yaml
# .pre-commit-config.yaml
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v4.5.0
  hooks:
  - id: trailing-whitespace
  - id: end-of-file-fixer
  - id: check-yaml
  - id: check-merge-conflict
  - id: detect-private-key        # Prevent committing secrets!
- repo: https://github.com/psf/black
  rev: 23.12.0
  hooks:
  - id: black
```

---

## .gitignore Patterns

```gitignore
# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
dist/
.pytest_cache/

# Node
node_modules/
.next/
dist/
*.log

# Environment (NEVER commit these)
.env
.env.local
.env.*.local
*.pem
*.key
secrets/

# IDE
.idea/
.vscode/
*.swp

# OS
.DS_Store
Thumbs.db

# Build
*.o
*.so
build/
target/
```
