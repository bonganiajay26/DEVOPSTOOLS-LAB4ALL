# Git Branching Strategies

## 1. Trunk-Based Development (Recommended for CI/CD)

```
main (trunk)
  │
  ├── Short-lived feature branches (< 2 days)
  │     feature/add-login   →  PR  →  merge to main
  │     fix/null-pointer    →  PR  →  merge to main
  │
  └── Release tags
        v1.0.0, v1.1.0, v1.2.0
```

**Rules:**
- Everyone commits to main frequently (at least daily)
- Feature branches live < 2 days
- Feature flags hide incomplete features
- Every commit to main → triggers CI → deploys to staging

**Why it wins:** Eliminates merge hell, forces small PRs, enables true CI/CD.

---

## 2. GitFlow (Legacy — complex releases)

```
main         ●────────────────────────────────●  (production)
              \                              /
develop        ●────●────●────●────●────●──  (integration)
                    \         \
feature             ●──●──●    ●──●          (features)
                             \
release                       ●──●──●        (stabilization)
                                         \
hotfix                                    ●──●  (emergency fix)
```

**Branch types:**
- `main` — production only, tagged releases
- `develop` — integration branch
- `feature/*` — new features from develop
- `release/*` — stabilization, minor bug fixes only
- `hotfix/*` — emergency production fixes

**When to use:** When you support multiple production versions simultaneously (e.g., enterprise software).

---

## 3. GitHub Flow (Simple, good for web apps)

```
main
 │
 ├── feature/auth     (PR → review → merge)
 ├── fix/login-bug    (PR → review → merge)
 └── feature/payments (PR → review → merge)

Deploy happens when PR merges to main.
```

**Rules:**
- main is always deployable
- All work in branches
- Open PR early (draft PRs for WIP)
- Deploy after merge, not before

---

## Choosing Your Strategy

| Strategy | Release Cadence | Team Size | Complexity |
|----------|----------------|-----------|------------|
| Trunk-Based | Continuous (multiple/day) | Any | Low |
| GitHub Flow | Daily/weekly | Small-Medium | Low |
| GitFlow | Monthly/quarterly | Large | High |

---

## Branch Protection Rules (GitHub)

```yaml
# Settings → Branches → Add rule for: main

✅ Require pull request reviews before merging
   Required approving reviews: 1 (or 2 for critical services)

✅ Require status checks to pass before merging
   Required checks: ci/test, ci/lint, ci/security-scan

✅ Require branches to be up to date before merging
   (prevents "it worked on my branch" issues)

✅ Require signed commits
   (audit trail, prevents impersonation)

✅ Do not allow bypassing the above settings
   (even admins must follow rules)

✅ Restrict who can push to matching branches
   → Only CI/CD service account + senior engineers
```

---

## PR Best Practices

```markdown
## What this PR does
<!-- 1-3 sentences. The "why", not the "what" (code shows the what) -->

## Changes
- [ ] Added login endpoint `POST /api/auth/login`
- [ ] Added JWT token generation
- [ ] Added unit tests

## How to test
1. `docker-compose up`
2. `curl -X POST localhost:8080/api/auth/login -d '{"email":"test@test.com","password":"test"}'`
3. Should return `{"token":"..."}`

## Screenshots
<!-- For UI changes -->

## Related Issues
Closes #123
```

**PR size guide:**
- Under 400 lines changed = good
- 400-800 lines = acceptable
- 800+ lines = split it

---

## Git Aliases for Productivity

```bash
# ~/.gitconfig
[alias]
  # Compact log with graph
  lg = log --oneline --graph --all --decorate

  # What did I do today?
  today = log --oneline --since=midnight --author=$(git config user.email)

  # Undo last commit (keep changes)
  undo = reset HEAD~1 --soft

  # Delete merged branches
  cleanup = !git branch --merged main | grep -v main | xargs git branch -d

  # Interactive rebase last N commits
  rbi = "!f() { git rebase -i HEAD~${1:-5}; }; f"

  # Quick stash with message
  save = "!f() { git stash push -m \"$1\"; }; f"

  # Who has most commits in last 30 days?
  top = shortlog --summary --numbered --since='30 days ago'
```
