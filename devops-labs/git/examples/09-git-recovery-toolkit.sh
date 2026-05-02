#!/bin/bash
# Example 09: Git Recovery Toolkit — Fix Common Disasters

set -e
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
danger()  { echo -e "${RED}🚨 $1${NC}"; }

# ── Scenario 1: Undo last commit (keep changes) ───────────────
undo_last_commit() {
    warn "Undoing last commit (changes will be staged)..."
    git reset HEAD~1 --soft
    success "Last commit undone. Changes are staged."
    echo "Run 'git status' to see staged changes."
}

# ── Scenario 2: Undo last N commits ──────────────────────────
undo_n_commits() {
    local n="${1:-1}"
    warn "Undoing last $n commits..."
    git reset HEAD~$n --soft
    success "Last $n commits undone. Changes are staged."
}

# ── Scenario 3: Completely discard last commit and changes ────
discard_last_commit() {
    danger "This will PERMANENTLY discard the last commit and all changes!"
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    [ "$confirm" = "yes" ] || { echo "Aborted."; exit 0; }
    git reset HEAD~1 --hard
    success "Last commit and changes discarded."
}

# ── Scenario 4: Recover deleted branch ───────────────────────
recover_branch() {
    local branch_name="${1:-recovered-branch}"
    echo "Searching reflog for lost commits..."

    echo "Recent HEAD positions:"
    git reflog --format="%C(yellow)%h%Creset %gd %s" | head -20

    read -p "Enter SHA to recover from (from reflog above): " sha

    if [ -z "$sha" ]; then
        echo "No SHA provided. Aborted."
        exit 1
    fi

    git checkout -b "$branch_name" "$sha"
    success "Branch '$branch_name' created at $sha"
}

# ── Scenario 5: Remove file from entire git history ──────────
remove_file_from_history() {
    local file="$1"
    danger "This rewrites ALL git history. Coordinate with team first!"

    if [ -z "$file" ]; then
        echo "Usage: $0 remove-file <path/to/file>"
        exit 1
    fi

    # Check git-filter-repo is installed
    if ! command -v git-filter-repo &>/dev/null; then
        echo "Install: pip install git-filter-repo"
        exit 1
    fi

    read -p "Remove '$file' from ALL history? Type 'yes': " confirm
    [ "$confirm" = "yes" ] || { echo "Aborted."; exit 0; }

    git filter-repo --path "$file" --invert-paths
    success "File removed from history. Force push required."
    warn "All team members must re-clone the repository!"
}

# ── Scenario 6: Recover accidentally staged file ─────────────
unstage_file() {
    local file="${1:-.}"
    git restore --staged "$file"
    success "Unstaged: $file"
}

# ── Scenario 7: Recover deleted file ─────────────────────────
recover_file() {
    local file="$1"

    if [ -z "$file" ]; then
        echo "Usage: $0 recover-file <path/to/file>"
        exit 1
    fi

    # Find last commit that had this file
    local last_commit=$(git log --oneline --all -- "$file" | head -1 | awk '{print $1}')

    if [ -z "$last_commit" ]; then
        echo "File '$file' not found in history"
        exit 1
    fi

    echo "Last seen in commit: $last_commit"
    git checkout "$last_commit" -- "$file"
    success "Recovered: $file"
}

# ── Scenario 8: Fix wrong author on commits ───────────────────
fix_author() {
    local old_email="$1"
    local new_name="$2"
    local new_email="$3"

    if [ -z "$old_email" ]; then
        echo "Usage: $0 fix-author <old-email> <new-name> <new-email>"
        exit 1
    fi

    git filter-repo --commit-callback "
if commit.author_email == b'$old_email':
    commit.author_name = b'$new_name'
    commit.author_email = b'$new_email'
    commit.committer_name = b'$new_name'
    commit.committer_email = b'$new_email'
"
    success "Author information updated in history"
}

# ── Scenario 9: Interactive rebase fix ───────────────────────
fix_recent_commits() {
    local n="${1:-5}"
    echo "Opening interactive rebase for last $n commits..."
    echo "Commands: pick, reword, edit, squash, fixup, drop"
    git rebase -i HEAD~$n
}

# ── Scenario 10: Abort stuck rebase/merge ────────────────────
abort_operation() {
    if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ]; then
        git rebase --abort
        success "Rebase aborted"
    elif [ -f ".git/MERGE_HEAD" ]; then
        git merge --abort
        success "Merge aborted"
    elif [ -f ".git/CHERRY_PICK_HEAD" ]; then
        git cherry-pick --abort
        success "Cherry-pick aborted"
    else
        echo "No ongoing operation to abort"
    fi
}

case "${1:-help}" in
    undo)           undo_last_commit ;;
    undo-n)         undo_n_commits "$2" ;;
    discard)        discard_last_commit ;;
    recover-branch) recover_branch "$2" ;;
    remove-file)    remove_file_from_history "$2" ;;
    unstage)        unstage_file "$2" ;;
    recover-file)   recover_file "$2" ;;
    fix-author)     fix_author "$2" "$3" "$4" ;;
    fix-commits)    fix_recent_commits "$2" ;;
    abort)          abort_operation ;;
    *)
        echo "Git Recovery Toolkit"
        echo ""
        echo "  undo              Undo last commit (keep changes staged)"
        echo "  undo-n <N>        Undo last N commits (keep changes)"
        echo "  discard           Permanently discard last commit + changes"
        echo "  recover-branch    Recover a deleted branch from reflog"
        echo "  remove-file <f>   Remove a file from ALL history"
        echo "  unstage [file]    Unstage a file"
        echo "  recover-file <f>  Restore a deleted file from history"
        echo "  fix-author        Fix wrong author email in history"
        echo "  fix-commits [N]   Interactive rebase last N commits"
        echo "  abort             Abort stuck rebase/merge/cherry-pick"
        ;;
esac
