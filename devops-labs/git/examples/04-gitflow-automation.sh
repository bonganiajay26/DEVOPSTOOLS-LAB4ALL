#!/bin/bash
# Example 04: GitFlow Branch Management Scripts

set -e

VERSION_FILE="VERSION"
MAIN_BRANCH="main"
DEVELOP_BRANCH="develop"

# ── Get current version ───────────────────────────────────────
get_version() {
    cat "$VERSION_FILE" 2>/dev/null || echo "0.0.0"
}

# ── Bump version ──────────────────────────────────────────────
bump_version() {
    local type="$1"   # major | minor | patch
    local version=$(get_version)
    local major minor patch

    IFS='.' read -r major minor patch <<< "$version"

    case "$type" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) echo "Invalid type: major|minor|patch"; exit 1 ;;
    esac

    echo "${major}.${minor}.${patch}"
}

# ── Start release ─────────────────────────────────────────────
start_release() {
    local type="${1:-minor}"

    git checkout "$DEVELOP_BRANCH"
    git pull origin "$DEVELOP_BRANCH"

    local new_version=$(bump_version "$type")
    local branch="release/v${new_version}"

    git checkout -b "$branch" "$DEVELOP_BRANCH"
    echo "$new_version" > "$VERSION_FILE"
    git add "$VERSION_FILE"
    git commit -m "chore: bump version to ${new_version}"

    echo "✅ Release branch created: $branch"
    echo "   Version: $new_version"
    echo "   Now: fix bugs, update CHANGELOG, then run: finish_release"
}

# ── Finish release ────────────────────────────────────────────
finish_release() {
    local version=$(get_version)
    local branch="release/v${version}"

    # Merge to main
    git checkout "$MAIN_BRANCH"
    git pull origin "$MAIN_BRANCH"
    git merge --no-ff "$branch" -m "chore: release v${version}"
    git tag -a "v${version}" -m "Release v${version}"

    # Merge back to develop
    git checkout "$DEVELOP_BRANCH"
    git merge --no-ff "$branch" -m "chore: merge release v${version} back to develop"

    # Delete release branch
    git branch -d "$branch"

    # Push everything
    git push origin "$MAIN_BRANCH" "$DEVELOP_BRANCH"
    git push origin "v${version}"

    echo "✅ Release v${version} complete!"
}

# ── Start hotfix ──────────────────────────────────────────────
start_hotfix() {
    local name="$1"

    git checkout "$MAIN_BRANCH"
    git pull origin "$MAIN_BRANCH"

    local current_version=$(get_version)
    local new_version=$(bump_version patch)
    local branch="hotfix/v${new_version}-${name}"

    git checkout -b "$branch"
    echo "$new_version" > "$VERSION_FILE"
    git add "$VERSION_FILE"
    git commit -m "chore: start hotfix v${new_version}"

    echo "✅ Hotfix branch: $branch"
}

# ── Finish hotfix ─────────────────────────────────────────────
finish_hotfix() {
    local version=$(get_version)
    local branch=$(git branch --show-current)

    # Merge to main
    git checkout "$MAIN_BRANCH"
    git merge --no-ff "$branch" -m "hotfix: merge ${branch}"
    git tag -a "v${version}" -m "Hotfix v${version}"

    # Merge to develop
    git checkout "$DEVELOP_BRANCH"
    git merge --no-ff "$branch" -m "hotfix: merge ${branch} to develop"

    git branch -d "$branch"
    git push origin "$MAIN_BRANCH" "$DEVELOP_BRANCH" "v${version}"

    echo "✅ Hotfix v${version} deployed!"
}

case "$1" in
    start-release) start_release "${2:-minor}" ;;
    finish-release) finish_release ;;
    start-hotfix) start_hotfix "$2" ;;
    finish-hotfix) finish_hotfix ;;
    version) get_version ;;
    *) echo "Usage: $0 {start-release|finish-release|start-hotfix|finish-hotfix|version}" ;;
esac
