# Lab 03: Advanced Git — Bisect, LFS, Hooks, and Security

**Difficulty**: Advanced | **Time**: 60 minutes  
**Goal**: Master advanced Git features used daily in production engineering teams.

---

## Part 1: Git Bisect — Automated Bug Hunting

```bash
mkdir bisect-lab && cd bisect-lab
git init && git config user.email "test@test.com" && git config user.name "Test"

# Create a project with known-good state
cat > calculator.py << 'EOF'
def add(a, b): return a + b
def subtract(a, b): return a - b
def multiply(a, b): return a * b
def divide(a, b): return a / b
EOF

cat > test_calculator.py << 'EOF'
from calculator import add, subtract, multiply, divide
assert add(2, 3) == 5
assert subtract(5, 3) == 2
assert multiply(3, 4) == 12
assert divide(10, 2) == 5.0
print("All tests PASSED")
EOF

git add . && git commit -m "feat: initial calculator"
git tag v1.0.0  # This works

# Simulate 10 more commits, one introducing a bug
for i in {1..10}; do
    echo "# commit $i" >> calculator.py
    git add . && git commit -m "chore: update $i"
    
    # Introduce bug at commit 6
    if [ $i -eq 6 ]; then
        # "Accidentally" break multiply
        sed -i 's/def multiply(a, b): return a \* b/def multiply(a, b): return a + b  # BUG!/' calculator.py
        git add . && git commit -m "refactor: clean up multiply (this is the bug)"
    fi
done

echo "Current state:"
python3 test_calculator.py || echo "Tests FAILING"

# Use bisect to find the bug
git bisect start
git bisect bad HEAD                    # Current commit is broken
git bisect good v1.0.0                 # Tag v1.0.0 was good

# Automated bisect with the test script!
git bisect run python3 test_calculator.py
# Git automatically tests each midpoint
# Output: "X is the first bad commit"

git bisect reset

echo "Found the breaking commit! Check with: git show"
```

---

## Part 2: pre-commit Hooks — Prevent Bad Commits

```bash
cd ..
mkdir hooks-lab && cd hooks-lab
git init && git config user.email "test@test.com" && git config user.name "Test"

# Install pre-commit framework
pip install pre-commit detect-secrets 2>/dev/null || echo "pip not available, showing config only"

# Create .pre-commit-config.yaml
cat > .pre-commit-config.yaml << 'EOF'
repos:
- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v4.5.0
  hooks:
  - id: trailing-whitespace
  - id: end-of-file-fixer
  - id: check-merge-conflict
  - id: detect-private-key
  - id: check-added-large-files
    args: ['--maxkb=500']
  - id: no-commit-to-branch
    args: ['--branch', 'main']
EOF

git add .pre-commit-config.yaml
git commit -m "chore: add pre-commit configuration"

# Install the hooks
# pre-commit install
# pre-commit install --hook-type commit-msg

# Manual hook to block secrets
mkdir -p .git/hooks
cat > .git/hooks/pre-commit << 'HOOK'
#!/bin/bash
set -e

# Check for obvious secrets
patterns=(
    "password\s*=\s*['\"][^'\"]\+['\"]"
    "api_key\s*=\s*['\"][^'\"]\+['\"]"
    "secret\s*=\s*['\"][^'\"]\+['\"]"
    "AWS_SECRET_ACCESS_KEY\s*=\s*['\"][^'\"]\+['\"]"
    "PRIVATE KEY"
    "BEGIN RSA PRIVATE"
)

for pattern in "${patterns[@]}"; do
    if git diff --cached | grep -qi "$pattern"; then
        echo "❌ Possible secret detected! Pattern: $pattern"
        echo "   Review your staged changes: git diff --cached"
        exit 1
    fi
done

echo "✅ No secrets detected"
HOOK
chmod +x .git/hooks/pre-commit

# Test it — try to commit a "secret"
cat > config.py << 'EOF'
DATABASE_URL = "postgresql://user:password@localhost/db"
API_KEY = "sk-1234567890abcdef"  # This should be blocked!
EOF

git add config.py
git commit -m "feat: add config"  # Should be blocked!

# Fix it properly
cat > config.py << 'EOF'
import os
DATABASE_URL = os.environ.get("DATABASE_URL")
API_KEY = os.environ.get("API_KEY")
EOF

git add config.py
git commit -m "feat: add config using env vars"
```

---

## Part 3: Advanced Log and Blame

```bash
cd ..
mkdir log-lab && cd log-lab
git init && git config user.email "test@test.com" && git config user.name "Test"

# Create multi-author history
for i in {1..5}; do
    cat > feature_$i.py << EOF
def feature_$i():
    """Feature $i implementation."""
    return "feature_$i_result"
EOF
    git add .
    git config user.name "Dev${i}"
    git config user.email "dev${i}@company.com"
    git commit -m "feat: add feature $i"
done

# Reset to single author for clarity
git config user.name "Test" && git config user.email "test@test.com"

# Introduce a "bug"
echo "# BUG: off-by-one error here" >> feature_3.py
git add . && git commit -m "fix: (actually introduces bug)"

# Advanced log techniques

echo "=== Graph view ==="
git log --oneline --graph --all

echo ""
echo "=== Find commits by author ==="
git log --oneline --author="Dev3"

echo ""
echo "=== Find commits that changed specific text ==="
git log --oneline -S "feature_3"    # Commits that added/removed this string

echo ""
echo "=== Blame with date ==="
git blame feature_3.py --date=short

echo ""
echo "=== Blame specific lines ==="
git blame -L 1,3 feature_3.py

echo ""
echo "=== Find the commit that introduced a line ==="
git log -S "off-by-one" --oneline
```

---

## Part 4: Git Reflog — The Safety Net

```bash
cd ..
mkdir reflog-lab && cd reflog-lab
git init && git config user.email "test@test.com" && git config user.name "Test"

# Build history
for i in {1..5}; do
    echo "commit $i" >> history.txt
    git add . && git commit -m "commit $i"
done

echo "Current log:"
git log --oneline

# DISASTER: reset hard to 2 commits ago
git reset --hard HEAD~3
echo "After reset --hard HEAD~3:"
git log --oneline
# Only 2 commits visible!

echo ""
echo "=== But reflog has everything ==="
git reflog

# Find the SHA of the commit we "lost"
LOST_SHA=$(git reflog | grep "commit 5" | head -1 | awk '{print $1}')
echo "Lost commit SHA: $LOST_SHA"

# Recover it!
git reset --hard $LOST_SHA
echo ""
echo "=== After recovery ==="
git log --oneline

# Advanced reflog usage
echo ""
echo "=== What I did yesterday (last 24h) ==="
git reflog --since="24 hours ago"

echo ""
echo "=== Reflog shows ALL operations ==="
git checkout HEAD~2
git reflog | head -5
# Shows: detach, previous reset, commits, etc.

git checkout -  # Go back
```

---

## Part 5: Git Large File Simulation

```bash
cd ..
mkdir lfs-lab && cd lfs-lab
git init && git config user.email "test@test.com" && git config user.name "Test"

# Simulate the problem: large binary files bloating a repo
# Create fake "large" files
dd if=/dev/zero bs=1024 count=2048 2>/dev/null > model_v1.bin   # 2MB
dd if=/dev/zero bs=1024 count=2048 2>/dev/null > model_v2.bin   # 2MB

git add model_v1.bin
git commit -m "ml: add model v1"

git add model_v2.bin  
git commit -m "ml: add model v2"

echo "Repo size with large files:"
du -sh .git/objects

# Remove large files from history using filter-repo
# (shows the approach; requires git-filter-repo)
echo ""
echo "To use Git LFS in a real project:"
echo ""
cat << 'INSTRUCTIONS'
# 1. Install and initialize LFS
git lfs install

# 2. Track large file types
git lfs track "*.bin" "*.pth" "*.pkl" "*.h5" "*.onnx"

# 3. Commit the tracking config
git add .gitattributes
git commit -m "chore: configure Git LFS for ML model files"

# 4. Now add large files (they're stored in LFS)
git add model_v3.bin
git commit -m "ml: add model v3 (stored in LFS)"

# 5. Verify
git lfs ls-files

# 6. Migrate EXISTING files to LFS (rewrites history!)
git lfs migrate import --include="*.bin" --everything
git push --force-with-lease origin main
INSTRUCTIONS

echo ""
echo "Lab 03 complete!"
```

---

## Cleanup

```bash
cd ~
rm -rf bisect-lab hooks-lab log-lab reflog-lab lfs-lab
```

## What You Learned

- [x] `git bisect run` for automated regression finding
- [x] Pre-commit hooks to block secrets and bad code
- [x] `git log -S` and `git blame` for code archaeology
- [x] Reflog as the ultimate safety net
- [x] Git LFS workflow for large binary files
