#!/bin/bash
# Example 01: Complete Git Configuration for Production Development
# Run: bash 01-gitconfig.sh

set -e

echo "=== Configuring Git for Production Development ==="

# Identity
git config --global user.name "Your Name"
git config --global user.email "you@company.com"

# Default branch
git config --global init.defaultBranch main

# Editor
git config --global core.editor "code --wait"    # VS Code
# git config --global core.editor "vim"          # Vim

# Diff and merge tools
git config --global diff.tool vscode
git config --global difftool.vscode.cmd 'code --wait --diff $LOCAL $REMOTE'
git config --global merge.tool vscode
git config --global mergetool.vscode.cmd 'code --wait $MERGED'

# Line endings (critical for cross-platform teams)
git config --global core.autocrlf input    # macOS/Linux: convert CRLF → LF on commit
# git config --global core.autocrlf true  # Windows: auto-convert

# Always pull with rebase (cleaner history)
git config --global pull.rebase true
git config --global rebase.autoStash true   # Auto-stash before rebase

# Push: only push current branch (safer default)
git config --global push.default current

# Show submodule diffs
git config --global diff.submodule log

# Sign commits with GPG (optional but recommended)
# git config --global commit.gpgsign true
# git config --global user.signingkey YOUR_GPG_KEY_ID

# Color output
git config --global color.ui auto
git config --global color.branch.current "yellow bold"
git config --global color.branch.remote "cyan"

# Better diffs with word-level highlighting
git config --global diff.wordRegex '[^[:space:]<>]+'

# Speed up large repos
git config --global feature.manyFiles true
git config --global core.fsmonitor true       # File system monitor (macOS/Windows)
git config --global core.untrackedCache true  # Cache untracked files

# Useful aliases
git config --global alias.lg "log --oneline --graph --all --decorate"
git config --global alias.st "status -sb"
git config --global alias.co "checkout"
git config --global alias.br "branch"
git config --global alias.unstage "restore --staged"
git config --global alias.last "log -1 HEAD --stat"
git config --global alias.visual "!gitk"
git config --global alias.undo "reset HEAD~1 --soft"
git config --global alias.cleanup "!git branch --merged main | grep -v main | xargs git branch -d"
git config --global alias.today "log --oneline --since=midnight --author=$(git config user.email)"
git config --global alias.week "log --oneline --since='1 week ago'"
git config --global alias.rbi "!f() { git rebase -i HEAD~${1:-5}; }; f"
git config --global alias.save "!f() { git stash push -m \"$1\"; }; f"

echo ""
echo "=== Git Configuration Complete ==="
git config --global --list | grep -v "credential"
