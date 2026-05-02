#!/bin/bash
# Example 02: Trunk-Based Development Workflow Scripts
# These scripts enforce team branching conventions

set -e

# ── new-feature: create a feature branch ──────────────────────
new_feature() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Usage: new_feature <feature-name>"
        exit 1
    fi

    # Always branch from fresh main
    git checkout main
    git pull origin main

    git checkout -b "feature/${name}"
    echo "✅ Created branch: feature/${name}"
    echo "   Base commit: $(git rev-parse --short HEAD)"
}

# ── sync-branch: keep branch up-to-date ───────────────────────
sync_branch() {
    local current=$(git branch --show-current)

    if [ "$current" = "main" ]; then
        echo "❌ Already on main. Use git pull."
        exit 1
    fi

    echo "Syncing $current with main..."
    git fetch origin main
    git rebase origin/main
    echo "✅ Synced. You are $(git rev-list HEAD ^origin/main --count) commits ahead of main."
}

# ── finish-feature: clean up and prepare PR ───────────────────
finish_feature() {
    local current=$(git branch --show-current)

    echo "Preparing $current for PR..."

    # Run tests first
    echo "→ Running tests..."
    if command -v pytest &>/dev/null; then
        pytest tests/ -q || { echo "❌ Tests failed!"; exit 1; }
    fi

    # Sync with main one more time
    git fetch origin main
    git rebase origin/main

    # Interactive rebase to clean up commits
    local commit_count=$(git rev-list HEAD ^origin/main --count)
    echo "→ You have $commit_count commits. Opening interactive rebase..."
    git rebase -i HEAD~${commit_count}

    # Push
    git push origin "$current" --force-with-lease
    echo "✅ Branch ready for PR!"
    echo "   Create PR at: https://github.com/YOUR_ORG/YOUR_REPO/compare/$current"
}

# ── hotfix: create and push a hotfix ──────────────────────────
hotfix() {
    local version="$1"
    local name="$2"

    if [ -z "$version" ] || [ -z "$name" ]; then
        echo "Usage: hotfix <tag-version> <fix-name>"
        echo "Example: hotfix v2.3.0 fix-null-pointer"
        exit 1
    fi

    git fetch --tags
    git checkout -b "hotfix/${name}" "${version}"
    echo "✅ Created hotfix branch from tag ${version}"
    echo "   Edit your fix, then run: git commit -m 'fix: ...'"
}

# ── show help ──────────────────────────────────────────────────
case "${1:-help}" in
    new)      new_feature "$2" ;;
    sync)     sync_branch ;;
    finish)   finish_feature ;;
    hotfix)   hotfix "$2" "$3" ;;
    *)
        echo "Git Workflow Helper"
        echo ""
        echo "Commands:"
        echo "  new <name>           Create new feature branch from main"
        echo "  sync                 Rebase current branch onto main"
        echo "  finish               Clean up and push for PR"
        echo "  hotfix <tag> <name>  Create hotfix from a release tag"
        ;;
esac
