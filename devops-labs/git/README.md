# Git

> **Master version control from daily workflows to enterprise branching strategies.**

---

## Quick Navigation

| Section | Contents |
|---------|----------|
| [docs/01-concepts.md](docs/01-concepts.md) | Git internals, object model, refs |
| [docs/02-branching-strategies.md](docs/02-branching-strategies.md) | GitFlow, trunk-based, release strategies |
| [examples/](examples/) | 10+ practical scripts and configs |
| [labs/](labs/) | 3 hands-on labs |
| [interview-prep/questions.md](interview-prep/questions.md) | 15 interview Q&A |

---

## 5-Minute Cheatsheet

```bash
# Daily workflow
git status                          # What changed?
git diff                            # What exactly changed?
git add -p                          # Stage interactively (not blindly)
git commit -m "feat: add user auth" # Conventional commits
git push origin feature/user-auth

# Branching
git checkout -b feature/my-feature main
git rebase main                     # Keep branch up to date (rebase > merge)
git push --force-with-lease         # Safe force push after rebase

# Undoing things
git restore <file>                  # Discard working dir changes
git restore --staged <file>         # Unstage
git reset HEAD~1 --soft             # Undo last commit, keep changes staged
git revert <commit-sha>             # Safe undo (creates new commit, safe for shared branches)

# Inspection
git log --oneline --graph --all     # Visual branch history
git blame <file>                    # Who wrote each line
git bisect start                    # Binary search for bug-introducing commit

# Stash
git stash push -m "WIP: feature X"
git stash list
git stash pop
```
