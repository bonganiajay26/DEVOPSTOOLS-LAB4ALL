# Git Interview Questions

## Q1. What is the difference between `git merge` and `git rebase`?

**Merge**: Creates a merge commit, preserves full history, non-destructive.
**Rebase**: Rewrites commits onto a new base, creates linear history, changes commit SHAs.

```bash
# Merge — safe for shared branches
git checkout main && git merge feature/login
# Result: A → B → C → M (M is merge commit)

# Rebase — use for local/feature branches before PR
git checkout feature/login && git rebase main
# Result: A → B → C → D' → E' (feature commits replayed on top of main)

# Golden rule: NEVER rebase public/shared branches
# Rebase rewrites SHAs → breaks other developers' branches
```

---

## Q2. What does `git reset` vs `git revert` do?

```bash
# git reset — moves HEAD (rewrites history — DANGER on shared branches)
git reset HEAD~1 --soft    # Undo commit, keep changes STAGED
git reset HEAD~1 --mixed   # Undo commit, keep changes UNSTAGED (default)
git reset HEAD~1 --hard    # Undo commit, DISCARD changes completely

# git revert — creates new "undo" commit (safe for shared branches)
git revert abc1234          # Creates commit that reverses abc1234
git revert HEAD~3..HEAD     # Revert last 3 commits
```

**Interview rule**: On `main` → always `revert`. On local feature branch → `reset` is fine.

---

## Q3. How do you find which commit introduced a bug?

```bash
# git bisect — binary search through history
git bisect start
git bisect bad              # Current commit is broken
git bisect good v2.0.0      # v2.0.0 was working

# Git checks out middle commit — you test and mark:
git bisect good             # or: git bisect bad

# Repeat until found:
# "abc1234 is the first bad commit"

# Automate with a test script:
git bisect run pytest tests/test_login.py -k "test_auth"

git bisect reset            # Return to HEAD
```

---

## Q4. How do you recover a deleted branch?

```bash
# Find the commit SHA from reflog (Git keeps 90 days of reflog)
git reflog | grep "branch-name"
# abc1234 HEAD@{5}: checkout: moving from branch-name to main

# Recreate the branch at that commit
git checkout -b branch-name abc1234

# Or with git fsck (find "dangling" commits)
git fsck --lost-found | grep commit
```

---

## Q5. What is `git cherry-pick`? When would you use it?

```bash
# Apply a specific commit to current branch
git cherry-pick abc1234     # Apply that commit's changes here

# Use case: hotfix on main, need same fix on older release branch
git checkout release/v1.x
git cherry-pick abc1234     # Apply the fix from main
```

---

## Q6. How do you handle merge conflicts systematically?

```bash
# 1. See all conflicted files
git status | grep "both modified"

# 2. Use a 3-way merge tool
git mergetool               # Opens configured tool (vimdiff, kdiff3, VS Code)

# Or edit manually:
# <<<<<<< HEAD (our changes)
# current code
# =======
# their code
# >>>>>>> feature/branch (their changes)

# 3. Mark resolved
git add <resolved-file>

# 4. Complete the merge
git merge --continue

# VS Code setup as merge tool:
git config --global merge.tool vscode
git config --global mergetool.vscode.cmd 'code --wait $MERGED'
```

---

## Q7. How do you squash multiple commits before merging a PR?

```bash
# Method 1: Interactive rebase
git rebase -i HEAD~5         # Edit last 5 commits
# Change "pick" to "squash" or "s" for commits to combine
# Edit the final commit message

# Method 2: Merge with squash (GitHub/GitLab UI has this option)
git merge --squash feature/my-feature
git commit -m "feat: implement user authentication"

# Method 3: Soft reset + new commit
git reset --soft main        # Unstage all commits back to main
git commit -m "feat: implement user authentication"
```

---

## Q8. Explain `git stash`. How is it different from committing?

```bash
# Stash: temporarily save uncommitted changes
git stash push -m "WIP: auth middleware"
git stash list               # stash@{0}: WIP: auth middleware
git stash apply stash@{0}    # Apply (keep in stash)
git stash pop                # Apply + remove from stash
git stash drop stash@{0}     # Delete without applying

# Difference from commit:
# Stash = local only, not pushed, meant to be temporary
# Commit = permanent record, part of history, pushed to remote
```

---

## Q9. How would you set up a monorepo with multiple services in Git?

```
monorepo/
├── services/
│   ├── auth-service/
│   ├── product-service/
│   └── order-service/
├── libs/
│   ├── common-utils/
│   └── shared-models/
├── .github/workflows/
│   ├── auth-service.yml    # Only runs when services/auth-service/** changes
│   └── product-service.yml
└── tools/

# GitHub Actions path filters:
on:
  push:
    paths:
    - 'services/auth-service/**'
    - 'libs/**'
```

---

## Q10. What is `git worktree` and when is it useful?

```bash
# Multiple working directories from one repository
# Use case: working on a hotfix while feature is in progress

git worktree add ../hotfix hotfix/critical-bug
# Now you have:
# /projects/myapp          ← feature/my-feature
# /projects/hotfix         ← hotfix/critical-bug

# Both share the same .git directory
# No stashing needed, no context switching

git worktree list
git worktree remove ../hotfix
```

---

## Q11. How do you handle large binary files in Git?

```bash
# Git LFS (Large File Storage)
git lfs install
git lfs track "*.psd" "*.zip" "*.tar.gz" "*.mp4"
git add .gitattributes
git add large-file.psd
git commit -m "Add design assets"
git push                     # Uploads to LFS server

# Check what's tracked
git lfs ls-files

# Migrate existing large files (rewrite history)
git lfs migrate import --include="*.psd" --everything
```

---

## Q12. Explain `.gitattributes`. What problems does it solve?

```bash
# .gitattributes: tells Git how to handle specific files

# Line ending normalization (Windows vs Unix)
* text=auto                  # Auto-detect text files, normalize line endings
*.sh text eol=lf             # Always LF for shell scripts
*.bat text eol=crlf          # Always CRLF for Windows batch

# Mark binary files (don't show useless diffs)
*.png binary
*.jar binary
*.pdf binary

# Custom diff for specific file types
*.py diff=python
*.md diff=markdown

# Exclude from archive
.github/ export-ignore
tests/ export-ignore
```

---

## Q13. What is `git blame` and how do you use it effectively?

```bash
# Show who changed each line and when
git blame src/auth.py

# Output: SHA  (Author  Date)  line-number  content
# abc1234 (Jane 2024-01-15 42)  def authenticate(user, password):

# Ignore whitespace changes
git blame -w src/auth.py

# Show blame for specific lines
git blame -L 42,60 src/auth.py

# Follow renames/moves
git blame -M -C src/auth.py

# Find original file (if moved from another file)
git log --follow -p src/auth.py
```

---

## Q14. How do you set up signed commits?

```bash
# GPG signing — proves you are who you say you are
gpg --full-generate-key
gpg --list-secret-keys --keyid-format=long
# Outputs: sec 4096R/ABC123DEF456

# Configure Git
git config --global user.signingkey ABC123DEF456
git config --global commit.gpgsign true
git config --global tag.gpgsign true

# Add public key to GitHub: Settings → SSH and GPG keys

# Verify commits show "Verified" badge on GitHub
git log --show-signature
```

---

## Q15. How do you clean up a repository that has had secrets committed?

```bash
# Scenario: someone committed .env with passwords
# Step 1: Rotate ALL compromised credentials IMMEDIATELY

# Step 2: Remove from history using git-filter-repo (modern tool)
pip install git-filter-repo
git filter-repo --path .env --invert-paths

# Step 3: Force push to all branches (coordinate with team)
git push --force-with-lease --all

# Step 4: Notify everyone to re-clone (their local history is now diverged)
# All team members: git fetch --all; git reset --hard origin/main

# Step 5: Prevent future occurrences
# Add to .gitignore
echo ".env" >> .gitignore
# Install pre-commit hook with detect-secrets
pip install detect-secrets
detect-secrets scan > .secrets.baseline
```
