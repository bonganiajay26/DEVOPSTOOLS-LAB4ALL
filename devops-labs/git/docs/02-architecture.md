# Git Internal Architecture

## The .git Directory

```
.git/
├── HEAD              ← current branch pointer ("ref: refs/heads/main")
├── config            ← repo-level git config
├── description       ← used by GitWeb
├── index             ← staging area (binary file)
├── objects/          ← all content (blobs, trees, commits, tags)
│   ├── pack/         ← packed objects (efficiency)
│   └── info/
├── refs/
│   ├── heads/        ← local branches
│   │   ├── main      ← contains commit SHA
│   │   └── feature-x
│   ├── remotes/      ← remote-tracking branches
│   │   └── origin/
│   │       └── main
│   └── tags/         ← tags
├── logs/             ← reflog (history of ref changes)
│   ├── HEAD
│   └── refs/heads/main
└── hooks/            ← local git hooks (not tracked)
```

---

## Object Storage

Git is a content-addressable filesystem. Every object is stored by the SHA-1 of its content.

```bash
# How git stores a file internally:
echo "Hello, World!" | git hash-object --stdin
# Output: 8ab686eafeb1f44702738c8b0f24f2567c36da6d

# Git compresses with zlib and stores at:
# .git/objects/8a/b686eafeb1f44702738c8b0f24f2567c36da6d

# Read any object:
git cat-file -t 8ab686ea    # type: blob
git cat-file -p 8ab686ea    # content: Hello, World!
```

### Object Types in Detail

```
BLOB — raw file content
  git cat-file -p HEAD:README.md

TREE — directory listing
  git cat-file -p HEAD^{tree}
  # 100644 blob abc123  README.md
  # 040000 tree def456  src/
  # 100755 blob ghi789  run.sh

COMMIT — snapshot + metadata
  git cat-file -p HEAD
  # tree abc123def456...
  # parent 9876543210...
  # author  Jane Doe <jane@co.com> 1705350000 +0000
  # committer Jane Doe <jane@co.com> 1705350000 +0000
  #
  # feat: add login endpoint

TAG (annotated) — named commit with message
  git cat-file -p v1.0.0
  # object abc123
  # type commit
  # tag v1.0.0
  # tagger Jane Doe <jane@co.com> 1705350000 +0000
  #
  # Release v1.0.0 — stable production build
```

---

## The Index (Staging Area)

The index is a binary cache of the next commit's tree.

```
Working Tree ──git add──► Index ──git commit──► Repository
              git restore◄──       git reset◄──

# Inspect the index
git ls-files --stage
# 100644 abc123def456 0  README.md
# 100644 def456abc123 0  src/app.py

# Stage number 0 = committed/staged
# Stage number 1,2,3 = merge conflict states
```

---

## Pack Files

Git periodically "packs" loose objects for efficiency:

```bash
# Manual pack (runs automatically on push/gc)
git gc

# Inspect pack contents
git verify-pack -v .git/objects/pack/pack-*.idx | head -20

# Delta compression: git stores diffs between similar files
# pack files can be 10-50x smaller than loose objects
```

---

## Transfer Protocols

```
HTTPS:
  Push/fetch via HTTP POST requests
  Authentication: password / token / credential helper

SSH:
  git@github.com:user/repo.git
  Authenticates via SSH key pair
  Fastest for private repos

Git protocol (read-only, fast):
  git://github.com/user/repo.git
  No auth, unauthenticated, rarely used

Smart HTTP (modern default):
  Negotiates what client needs, sends only required objects
  Efficient: only fetches commits client doesn't have
```

---

## Merge Internals

```
3-Way Merge Algorithm:
  BASE  = common ancestor of both branches
  OURS  = our current branch tip
  THEIRS = branch being merged in

  For each file:
    if OURS == BASE → take THEIRS (they changed it, we didn't)
    if THEIRS == BASE → keep OURS (we changed it, they didn't)
    if both changed → CONFLICT (human must resolve)
    if both same change → auto-merge (no conflict)

# Find merge base:
git merge-base main feature/login
# Output: abc1234 (common ancestor commit)
```

---

## Rebase Internals

```bash
# git rebase main (while on feature branch)
# 
# Step 1: Find common ancestor (merge-base)
BASE=$(git merge-base HEAD main)
# = abc1234
#
# Step 2: Save feature commits as patches
git format-patch $BASE..HEAD
# 0001-feat-add-login.patch
# 0002-fix-null-check.patch
#
# Step 3: Reset branch to tip of main
git reset --hard main
#
# Step 4: Re-apply each patch
git am 0001-feat-add-login.patch
git am 0002-fix-null-check.patch
# Each patch becomes a NEW commit with new SHA
# Old commits are unreachable (but still in reflog for 90 days)
```

---

## Garbage Collection

```bash
# git gc runs automatically, but you can trigger it
git gc --prune=now    # Remove unreachable objects immediately
git gc --aggressive   # More thorough (slower, better compression)

# Unreachable objects are kept for:
# - 14 days (loose objects)
# - 90 days (in reflog)
# After expiry → gc removes them

# Check repo size
git count-objects -v -H
# count: 0 (loose objects)
# size: 0 bytes
# in-pack: 5423 (objects in pack files)
# packs: 1
# size-pack: 2.50 MiB
```

---

## Shallow Clones

```bash
# Clone with only last N commits (faster CI, smaller disk)
git clone --depth=1 https://github.com/org/repo

# Deepen later
git fetch --deepen=50

# Full unshallow
git fetch --unshallow

# Check if repo is shallow
cat .git/shallow
# Contains: commit SHAs that are "grafted" (have no parents in this clone)
```
