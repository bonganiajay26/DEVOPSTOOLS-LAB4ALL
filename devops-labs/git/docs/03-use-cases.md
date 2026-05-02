# Git Real-World Use Cases

## 1. Monorepo with Path-Based CI

```bash
# Large company: 50+ services in one repo
# Challenge: don't run all CI on every commit
# Solution: path filters

# .github/workflows/api-service.yml
on:
  push:
    paths:
      - 'services/api/**'
      - 'libs/common/**'
      - '.github/workflows/api-service.yml'

# Check what changed in last commit
git diff --name-only HEAD~1 HEAD

# Find all services that changed in a PR
git diff --name-only origin/main...HEAD | \
  grep "^services/" | \
  cut -d/ -f1-2 | sort -u
# services/api
# services/payment
```

---

## 2. Feature Flags + Trunk-Based Development

```bash
# Never long-lived branches. Ship to main daily.
# Incomplete features hidden behind flags.

# 1. Create short-lived branch
git checkout -b feat/new-checkout-flow main

# 2. Implement behind feature flag
# if feature_flag('new_checkout_v2'):
#     return new_checkout()
# return old_checkout()

# 3. Commit small, often
git commit -m "feat(checkout): add new payment UI skeleton (flag: new_checkout_v2)"

# 4. Rebase + squash before merge (clean history)
git rebase -i origin/main
# Squash all WIP commits into one clean commit

# 5. Merge same day
git push origin feat/new-checkout-flow
# Create PR → approve → merge (same day)

# 6. Enable flag in production when ready
# Remove flag and old code in separate cleanup PR
```

---

## 3. Git Bisect for Bug Hunting

```bash
# Bug report: "search is broken, worked 2 weeks ago"
# 500 commits in last 2 weeks — binary search finds it in ~10 steps

git bisect start
git bisect bad HEAD                    # Current commit is broken
git bisect good v2.1.0                 # This version worked

# Git checks out middle commit
# Test it → broken or working?
git bisect bad                         # This one is broken too
# or
git bisect good                        # This one works

# Repeat 8-10 times...
# abc1234 is the first bad commit

git show abc1234                       # See what changed
git bisect reset                       # Return to HEAD

# Automate with a test script:
git bisect run pytest tests/test_search.py -k "test_basic_search"
# Git automatically tests each commit → finds bad commit in seconds
```

---

## 4. Emergency Hotfix Process

```bash
# Scenario: Critical security bug in production
# Production is on v2.3.0 tag

# 1. Create hotfix branch from the production tag
git checkout -b hotfix/cve-2024-1234 v2.3.0

# 2. Fix the bug
vim src/auth/jwt.py
git add src/auth/jwt.py
git commit -m "fix(security): prevent JWT algorithm confusion attack (CVE-2024-1234)"

# 3. Tag the hotfix release
git tag -a v2.3.1 -m "Security fix: CVE-2024-1234"

# 4. Push to trigger deployment pipeline
git push origin hotfix/cve-2024-1234
git push origin v2.3.1

# 5. Also apply to main (cherry-pick to avoid merge conflicts)
git checkout main
git cherry-pick abc1234   # The fix commit

# 6. Delete hotfix branch
git branch -d hotfix/cve-2024-1234
git push origin --delete hotfix/cve-2024-1234
```

---

## 5. Interactive Rebase — Clean Up Messy History

```bash
# Typical messy feature branch history:
# abc1234  WIP
# def5678  fix typo
# ghi9012  actually fix the bug
# jkl3456  add test
# mno7890  oops forgot to save
# pqr2345  finally works

# Clean it up before merging to main:
git rebase -i origin/main

# In the editor, change:
# pick abc1234  WIP
# pick def5678  fix typo          → squash (s)
# pick ghi9012  actually fix bug  → squash (s)
# pick jkl3456  add test          → squash (s)
# pick mno7890  oops forgot       → squash (s)
# pick pqr2345  finally works     → reword (r)

# Result: ONE clean commit:
# feat(auth): implement refresh token rotation with 24h expiry
```

---

## 6. Managing Large Files with Git LFS

```bash
# Problem: designers commit 100MB Figma exports → repo is 5GB
# Solution: Git LFS stores large files on a separate server

# Setup (once per repo)
git lfs install
git lfs track "*.psd" "*.sketch" "*.zip" "*.tar.gz" "*.mp4" "*.mov"
git add .gitattributes
git commit -m "chore: configure Git LFS for binary assets"

# Now large files are stored as pointer files in git:
# version https://git-lfs.github.com/spec/v1
# oid sha256:abc123...
# size 104857600

# LFS server stores the actual file
# Clone is fast (pointers are tiny)

# Stats
git lfs ls-files          # List LFS files
du -sh .git/lfs/objects   # LFS local cache size

# Migrate existing history
git lfs migrate import --include="*.psd" --everything
git push --force-with-lease
```

---

## 7. Git Worktrees — Work on Multiple Branches Simultaneously

```bash
# Scenario: writing a blog post in branch 'blog/new-post'
# Urgent fix needed on 'hotfix/login-crash'
# Without worktree: stash → checkout → fix → unstash
# With worktree: two directories, both active at once

git worktree add ../hotfix hotfix/login-crash
# Creates: /projects/hotfix/ pointing to that branch

# Now you have:
# /projects/myapp          ← blog/new-post
# /projects/hotfix         ← hotfix/login-crash

# Work in hotfix directory
cd ../hotfix
vim src/auth.py
git commit -m "fix: prevent login crash on null email"
git push

# Back to blog post (no stash needed)
cd ../myapp
git worktree list
git worktree remove ../hotfix
```

---

## 8. Submodules — Sharing Code Across Repos

```bash
# Scenario: shared library used by 5 services
# Each service pins a specific version

# Add shared library as submodule
git submodule add https://github.com/myorg/shared-utils libs/shared-utils

# Commit pins the exact commit SHA
git add .gitmodules libs/shared-utils
git commit -m "chore: add shared-utils library as submodule"

# Clone with submodules
git clone --recurse-submodules https://github.com/myorg/myapp

# Update submodule to latest
cd libs/shared-utils
git pull origin main
cd ../..
git add libs/shared-utils
git commit -m "chore: update shared-utils to v2.1.0"

# View submodule status
git submodule status
# abc1234 libs/shared-utils (v2.1.0)
```

---

## 9. Git Hooks for Automated Quality Gates

```bash
# pre-commit: run before every commit
cat > .git/hooks/pre-commit << 'EOF'
#!/bin/bash
set -e

echo "Running pre-commit checks..."

# Run tests
echo "→ Running tests..."
pytest tests/ -x -q
if [ $? -ne 0 ]; then
  echo "❌ Tests failed. Commit aborted."
  exit 1
fi

# Lint
echo "→ Running linter..."
ruff check .
if [ $? -ne 0 ]; then
  echo "❌ Lint errors. Commit aborted."
  exit 1
fi

# Check for secrets
echo "→ Scanning for secrets..."
detect-secrets scan --baseline .secrets.baseline
if [ $? -ne 0 ]; then
  echo "❌ Possible secrets detected. Commit aborted."
  exit 1
fi

echo "✅ All checks passed!"
EOF
chmod +x .git/hooks/pre-commit

# Share hooks with team using pre-commit framework:
# .pre-commit-config.yaml
# pip install pre-commit && pre-commit install
```

---

## 10. Recovering Lost Work

```bash
# Scenario: accidentally ran git reset --hard
# "I deleted 3 days of work!"

# 1. Check reflog immediately (90-day history of all HEAD positions)
git reflog | head -20
# abc1234 HEAD@{1}: reset: moving to HEAD~5
# def5678 HEAD@{2}: commit: feat: add payment integration  ← LOST COMMITS HERE

# 2. Restore to before the reset
git reset --hard def5678   # SHA of the commit before the bad reset

# Or create a branch pointing to the lost work
git checkout -b recovery def5678

# 3. If commit was never committed (only staged):
git fsck --lost-found
# Dangling blobs and commits appear in .git/lost-found/

# 4. If file was deleted but git-tracked:
git checkout HEAD -- path/to/deleted/file.py

# Prevention:
# git stash before any risky operation
# git tag backup-$(date +%Y%m%d) before rebasing
```
