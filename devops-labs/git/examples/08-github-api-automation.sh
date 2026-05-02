#!/bin/bash
# Example 08: GitHub API Automation via CLI (gh)
# Requires: gh CLI installed and authenticated
# Install: https://cli.github.com/

set -e
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

# ── Repository setup automation ───────────────────────────────

setup_branch_protection() {
    local branch="${1:-main}"
    echo "Setting up branch protection for $branch..."

    gh api \
        --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/$REPO/branches/$branch/protection" \
        --input - << 'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["ci/test", "ci/lint", "ci/security"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
    echo "✅ Branch protection set for $branch"
}

# ── PR automation ─────────────────────────────────────────────

create_pr() {
    local title="$1"
    local body_file="${2:-/dev/stdin}"

    gh pr create \
        --title "$title" \
        --body-file "$body_file" \
        --assignee "@me" \
        --label "needs-review"
}

# Auto-assign reviewers based on CODEOWNERS
assign_reviewers() {
    local pr_number="$1"
    local reviewers="$2"    # comma-separated

    gh pr edit "$pr_number" \
        --add-reviewer "$reviewers"
}

# ── Release automation ────────────────────────────────────────

create_release() {
    local tag="$1"
    local title="$2"
    local notes_file="${3:-CHANGELOG.md}"

    gh release create "$tag" \
        --title "$title" \
        --notes-file "$notes_file" \
        --generate-notes \
        --draft

    echo "✅ Draft release created: $tag"
    echo "   Review and publish at: https://github.com/$REPO/releases"
}

# ── Bulk operations ───────────────────────────────────────────

# List all open PRs with status
list_prs() {
    gh pr list \
        --json number,title,author,createdAt,reviewDecision \
        --template \
        '{{range .}}#{{.number}} | {{.author.login}} | {{.reviewDecision}} | {{.title}}{{"\n"}}{{end}}'
}

# Close stale PRs (no activity in 30 days)
close_stale_prs() {
    local days="${1:-30}"
    local cutoff=$(date -v -${days}d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                   date -d "$days days ago" +%Y-%m-%dT%H:%M:%SZ)

    gh pr list --json number,updatedAt,title \
        --jq ".[] | select(.updatedAt < \"$cutoff\") | .number" | \
    while read pr_num; do
        echo "Closing stale PR #$pr_num..."
        gh pr close "$pr_num" \
            --comment "Closing due to inactivity (no updates in $days days)"
    done
}

# ── Repo analytics ────────────────────────────────────────────

repo_stats() {
    echo "=== Repository Stats: $REPO ==="
    gh repo view --json stargazerCount,forkCount,openIssues,watchers \
        --template \
        '⭐ Stars:   {{.stargazerCount}}
🍴 Forks:   {{.forkCount}}
👀 Watchers: {{.watchers.totalCount}}
🐛 Issues:  {{.openIssues.totalCount}}
'

    echo ""
    echo "=== Open PRs ==="
    list_prs

    echo ""
    echo "=== Recent Releases ==="
    gh release list --limit 5
}

# ── Secrets management ────────────────────────────────────────

sync_secrets() {
    # Sync secrets from .env.production to GitHub Secrets
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue  # Skip comments
        [[ -z "$key" ]] && continue         # Skip empty lines

        echo "Setting secret: $key"
        echo "$value" | gh secret set "$key"
    done < .env.production

    echo "✅ Secrets synced to GitHub"
}

case "${1:-stats}" in
    protect)   setup_branch_protection "${2:-main}" ;;
    pr)        create_pr "$2" "$3" ;;
    release)   create_release "$2" "$3" "$4" ;;
    prs)       list_prs ;;
    stale)     close_stale_prs "${2:-30}" ;;
    stats)     repo_stats ;;
    secrets)   sync_secrets ;;
    *)
        echo "GitHub Automation"
        echo "  protect [branch]         Set up branch protection"
        echo "  pr <title> [body-file]   Create pull request"
        echo "  release <tag> <title>    Create draft release"
        echo "  prs                      List open PRs"
        echo "  stale [days]             Close stale PRs"
        echo "  stats                    Repository analytics"
        echo "  secrets                  Sync .env.production to GitHub Secrets"
        ;;
esac
