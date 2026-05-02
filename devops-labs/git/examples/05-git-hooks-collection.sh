#!/bin/bash
# Example 05: Collection of Production Git Hooks
# Install all: bash 05-git-hooks-collection.sh install

HOOKS_DIR=".git/hooks"

install_hooks() {
    mkdir -p "$HOOKS_DIR"

    # ── pre-commit hook ───────────────────────────────────────
    cat > "$HOOKS_DIR/pre-commit" << 'HOOK'
#!/bin/bash
set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

fail() { echo -e "${RED}❌ $1${NC}"; exit 1; }
pass() { echo -e "${GREEN}✅ $1${NC}"; }

# Get staged Python files
STAGED_PY=$(git diff --cached --name-only --diff-filter=ACM | grep "\.py$" || true)

if [ -n "$STAGED_PY" ]; then
    echo "→ Checking Python files..."
    command -v ruff &>/dev/null && ruff check $STAGED_PY || fail "Ruff lint failed"
    pass "Python lint passed"
fi

# Check for debug statements
if git diff --cached | grep -E "^\+.*(pdb\.set_trace|breakpoint\(\)|console\.log\(|debugger;)" | grep -v "test_"; then
    fail "Debug statement found in staged changes"
fi

# Check for TODO in new code (warning only)
if git diff --cached | grep -E "^\+.*TODO"; then
    echo "⚠️  Warning: TODO found in staged changes"
fi

pass "pre-commit checks passed"
HOOK

    # ── commit-msg hook ───────────────────────────────────────
    cat > "$HOOKS_DIR/commit-msg" << 'HOOK'
#!/bin/bash
commit_msg=$(cat "$1")
pattern="^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\(.+\))?(!)?: .{1,72}"

# Allow merge commits and revert commits
if echo "$commit_msg" | grep -qE "^Merge |^Revert "; then
    exit 0
fi

if ! echo "$commit_msg" | grep -qE "$pattern"; then
    echo "❌ Invalid commit message format!"
    echo ""
    echo "Expected: <type>(<scope>): <description>"
    echo "Types: feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert"
    echo ""
    echo "Examples:"
    echo "  feat(auth): add JWT refresh token rotation"
    echo "  fix(api): handle null response from payment gateway"
    echo "  docs: update installation guide"
    echo "  chore!: drop support for Python 3.8 (BREAKING CHANGE)"
    exit 1
fi

echo "✅ Commit message format is valid"
HOOK

    # ── pre-push hook ─────────────────────────────────────────
    cat > "$HOOKS_DIR/pre-push" << 'HOOK'
#!/bin/bash
set -e

protected_branches="main master production"
current_branch=$(git branch --show-current)

for branch in $protected_branches; do
    if [ "$current_branch" = "$branch" ]; then
        echo "❌ Direct push to $branch is not allowed!"
        echo "   Use a pull request."
        exit 1
    fi
done

# Run full test suite before pushing
echo "→ Running full test suite before push..."
if command -v pytest &>/dev/null; then
    pytest tests/ -q --tb=short
fi

echo "✅ pre-push checks passed"
HOOK

    # ── post-checkout hook ────────────────────────────────────
    cat > "$HOOKS_DIR/post-checkout" << 'HOOK'
#!/bin/bash
# Install dependencies if package files changed
prev_head="$1"
new_head="$2"
branch_checkout="$3"

if [ "$branch_checkout" = "1" ]; then
    # Check if requirements changed
    if git diff --name-only "$prev_head" "$new_head" | grep -qE "requirements.*\.txt|pyproject\.toml|package\.json"; then
        echo "📦 Dependency files changed. Installing..."
        [ -f "requirements.txt" ] && pip install -r requirements.txt -q
        [ -f "package.json" ] && npm install --silent
        echo "✅ Dependencies updated"
    fi
fi
HOOK

    chmod +x "$HOOKS_DIR/pre-commit" "$HOOKS_DIR/commit-msg" \
             "$HOOKS_DIR/pre-push" "$HOOKS_DIR/post-checkout"

    echo "✅ All hooks installed in $HOOKS_DIR"
    ls -la "$HOOKS_DIR"
}

remove_hooks() {
    rm -f "$HOOKS_DIR/pre-commit" "$HOOKS_DIR/commit-msg" \
          "$HOOKS_DIR/pre-push" "$HOOKS_DIR/post-checkout"
    echo "✅ Hooks removed"
}

case "${1:-install}" in
    install) install_hooks ;;
    remove)  remove_hooks ;;
    *) echo "Usage: $0 {install|remove}" ;;
esac
