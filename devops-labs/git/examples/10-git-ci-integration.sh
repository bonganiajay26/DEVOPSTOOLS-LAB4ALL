#!/bin/bash
# Example 10: Git Integration Scripts for CI/CD Pipelines

set -e

# ── Get metadata for CI pipelines ────────────────────────────

ci_metadata() {
    echo "=== CI/CD Git Metadata ==="
    echo "Branch:      $(git branch --show-current 2>/dev/null || echo $CI_COMMIT_BRANCH)"
    echo "Commit SHA:  $(git rev-parse HEAD)"
    echo "Short SHA:   $(git rev-parse --short HEAD)"
    echo "Tag:         $(git describe --tags --exact-match 2>/dev/null || echo 'no-tag')"
    echo "Version:     $(git describe --tags --always --dirty)"
    echo "Author:      $(git log -1 --format='%an <%ae>')"
    echo "Commit Msg:  $(git log -1 --format='%s')"
    echo "Changed files:"
    git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "  (no parent commit)"
}

# ── Detect what changed (monorepo path filtering) ─────────────

detect_changes() {
    local base_ref="${1:-origin/main}"
    local head_ref="${2:-HEAD}"

    echo "Files changed between $base_ref and $head_ref:"
    git diff --name-only "$base_ref...$head_ref"

    echo ""
    echo "Services affected:"
    git diff --name-only "$base_ref...$head_ref" | \
        grep "^services/" | \
        cut -d/ -f2 | \
        sort -u | \
        while read svc; do echo "  → $svc"; done
}

# ── Version tagging for releases ─────────────────────────────

tag_release() {
    local version="$1"
    local message="${2:-Release $version}"

    if [ -z "$version" ]; then
        echo "Usage: tag_release <version> [message]"
        exit 1
    fi

    # Ensure clean working tree
    if ! git diff --quiet; then
        echo "❌ Working tree is dirty. Commit changes first."
        exit 1
    fi

    git tag -a "v${version}" -m "$message"
    git push origin "v${version}"
    echo "✅ Tagged and pushed: v${version}"
}

# ── Auto-tag based on conventional commits ────────────────────

auto_version_bump() {
    local latest_tag=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    local version="${latest_tag#v}"
    local major minor patch
    IFS='.' read -r major minor patch <<< "$version"

    # Check commits since last tag
    local has_breaking=$(git log "${latest_tag}..HEAD" --pretty="%s" | grep -c "BREAKING CHANGE\|!:" || true)
    local has_feat=$(git log "${latest_tag}..HEAD" --pretty="%s" | grep -c "^feat" || true)
    local has_fix=$(git log "${latest_tag}..HEAD" --pretty="%s" | grep -c "^fix" || true)

    if [ "$has_breaking" -gt 0 ]; then
        major=$((major + 1)); minor=0; patch=0
        echo "MAJOR bump: breaking change detected"
    elif [ "$has_feat" -gt 0 ]; then
        minor=$((minor + 1)); patch=0
        echo "MINOR bump: new features detected"
    elif [ "$has_fix" -gt 0 ]; then
        patch=$((patch + 1))
        echo "PATCH bump: bug fixes detected"
    else
        echo "No version bump needed"
        echo "$latest_tag"
        return
    fi

    echo "v${major}.${minor}.${patch}"
}

# ── Changelog generation ──────────────────────────────────────

generate_release_notes() {
    local from="${1:-$(git describe --tags --abbrev=0 HEAD~1 2>/dev/null || echo "")}"
    local to="${2:-HEAD}"
    local range="${from:+${from}..}${to}"

    cat << EOF
## What's Changed

### 🚀 New Features
$(git log $range --pretty="- %s (%h)" --grep="^feat" | sed 's/feat[^:]*: //')

### 🐛 Bug Fixes
$(git log $range --pretty="- %s (%h)" --grep="^fix" | sed 's/fix[^:]*: //')

### 📦 Dependencies
$(git log $range --pretty="- %s (%h)" --grep="^chore(deps)" | sed 's/chore(deps): //')

### 🔧 Other Changes
$(git log $range --pretty="- %s (%h)" --grep="^chore\|^docs\|^refactor" | grep -v "deps")

### 👥 Contributors
$(git log $range --pretty="%an" | sort -u | while read author; do echo "- @$author"; done)

**Full Changelog**: https://github.com/ORG/REPO/compare/${from}...${to}
EOF
}

# ── Commit validation for CI ──────────────────────────────────

validate_commits() {
    local base="${1:-origin/main}"
    local pattern="^(feat|fix|docs|style|refactor|test|chore|perf|ci|build|revert)(\(.+\))?(!)?: .{1,72}"

    echo "Validating commit messages..."
    local failed=0

    git log "$base..HEAD" --format="%H %s" | while read sha msg; do
        if ! echo "$msg" | grep -qE "$pattern"; then
            echo "❌ Invalid: [$sha] $msg"
            failed=$((failed + 1))
        else
            echo "✅ Valid:   $msg"
        fi
    done

    if [ "$failed" -gt 0 ]; then
        echo ""
        echo "❌ $failed commit(s) have invalid messages. Fix with: git rebase -i $base"
        exit 1
    fi

    echo "✅ All commits have valid messages!"
}

case "${1:-metadata}" in
    metadata)   ci_metadata ;;
    changes)    detect_changes "$2" "$3" ;;
    tag)        tag_release "$2" "$3" ;;
    bump)       auto_version_bump ;;
    notes)      generate_release_notes "$2" "$3" ;;
    validate)   validate_commits "$2" ;;
    *)
        echo "CI/CD Git Integration"
        echo "  metadata           Show branch/commit/tag info"
        echo "  changes [base]     Show changed files vs base ref"
        echo "  tag <version>      Create and push annotated tag"
        echo "  bump               Auto-detect version bump from commits"
        echo "  notes [from] [to]  Generate release notes"
        echo "  validate [base]    Validate conventional commit messages"
        ;;
esac
