#!/bin/bash
# Example 06: Advanced Git Log, Search, and Audit Scripts

# ── Pretty log formats ────────────────────────────────────────

# Compact graph view
alias glog='git log --oneline --graph --all --decorate'

# Detailed log with author, date, files changed
alias gfull='git log --pretty=format:"%C(yellow)%h%Creset %C(blue)%an%Creset %C(green)%ar%Creset - %s" --stat'

# Show only my commits today
alias gtoday='git log --oneline --since=midnight --author=$(git config user.email)'

# ── Search through history ────────────────────────────────────

# Find commits that introduced/removed a string (pickaxe)
search_code_history() {
    local search_term="$1"
    echo "Commits that changed occurrences of: '$search_term'"
    git log -S "$search_term" --oneline --all
}

# Find commits by regex pattern (more powerful than -S)
search_regex_history() {
    local pattern="$1"
    git log -G "$pattern" --oneline --all
}

# Search commit messages
search_commits() {
    local pattern="$1"
    git log --oneline --all --grep="$pattern"
}

# ── Blame and ownership ───────────────────────────────────────

# Who wrote each line (with date and commit)
annotate_file() {
    local file="$1"
    git blame "$file" -w --ignore-rev HEAD --date=short
}

# Find who wrote the most code in a directory
top_contributors() {
    local path="${1:-.}"
    echo "Top contributors in $path:"
    git log --format='%an' -- "$path" | sort | uniq -c | sort -rn | head -10
}

# Who changed a specific function?
blame_function() {
    local function_name="$1"
    local file="$2"
    git log -L ":${function_name}:${file}" --oneline
}

# ── Audit and compliance ──────────────────────────────────────

# All commits in last month with author and files
monthly_audit() {
    local month="${1:-$(date +%Y-%m)}"
    echo "Commits in $month:"
    git log \
        --after="${month}-01" \
        --before="${month}-31" \
        --pretty=format:"%h | %an | %ad | %s" \
        --date=short \
        --name-only
}

# Files changed most often (hot files = high change rate = risk)
hot_files() {
    local limit="${1:-20}"
    echo "Top $limit most-changed files:"
    git log --name-only --format="" | \
        grep -v "^$" | \
        sort | uniq -c | sort -rn | \
        head "$limit"
}

# Find large files in history (before they pollute the repo)
find_large_files() {
    local threshold="${1:-1048576}"  # 1MB default
    echo "Files over $(($threshold/1024))KB in git history:"
    git rev-list --objects --all | \
        git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' | \
        awk -v threshold="$threshold" '$1=="blob" && $3>=threshold {print $3, $4}' | \
        sort -rn | \
        head -20
}

# ── Release notes generation ──────────────────────────────────

# Generate changelog between two tags
generate_changelog() {
    local from="${1:-$(git describe --tags --abbrev=0 HEAD~1)}"
    local to="${2:-HEAD}"

    echo "# Changelog: $from → $to"
    echo ""
    echo "## Features"
    git log --oneline "$from..$to" --grep="^feat" | sed 's/^/- /'
    echo ""
    echo "## Bug Fixes"
    git log --oneline "$from..$to" --grep="^fix" | sed 's/^/- /'
    echo ""
    echo "## Breaking Changes"
    git log --oneline "$from..$to" --grep="BREAKING CHANGE" | sed 's/^/- /'
    echo ""
    echo "## Other Changes"
    git log --oneline "$from..$to" --grep="^chore\|^docs\|^refactor\|^perf" | sed 's/^/- /'
}

# ── Main: show examples ───────────────────────────────────────
case "${1:-help}" in
    search)     search_code_history "$2" ;;
    blame)      annotate_file "$2" ;;
    contrib)    top_contributors "$2" ;;
    blame-fn)   blame_function "$2" "$3" ;;
    audit)      monthly_audit "$2" ;;
    hot)        hot_files "$2" ;;
    large)      find_large_files "$2" ;;
    changelog)  generate_changelog "$2" "$3" ;;
    *)
        echo "Git History & Audit Tools"
        echo ""
        echo "  search   <term>       Find commits that changed a string"
        echo "  blame    <file>       Annotated blame with dates"
        echo "  contrib  [path]       Top contributors"
        echo "  blame-fn <fn> <file>  Track a function's history"
        echo "  audit    [YYYY-MM]    Monthly commit audit"
        echo "  hot      [N]          Most changed files"
        echo "  large    [bytes]      Large files in history"
        echo "  changelog [v1] [v2]   Generate release notes"
        ;;
esac
