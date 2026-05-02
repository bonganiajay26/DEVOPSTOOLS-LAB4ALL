# Lab 01: Git Fundamentals — Objects, Branches, and History

**Difficulty**: Beginner | **Time**: 45 minutes  
**Goal**: Understand git internals by building a repository from scratch and exploring every object.

---

## Part 1: Initialize and Explore the Object Store

```bash
# Create a fresh repository
mkdir git-lab && cd git-lab
git init

# Look at what git created
ls -la .git/
# config  description  HEAD  hooks/  info/  objects/  refs/

# The objects directory is empty (no commits yet)
find .git/objects -type f
```

### Step 2: Create your first blob

```bash
# Create a file
echo "Hello, Git!" > README.md
git add README.md

# Git created a blob object! Find it:
find .git/objects -type f
# .git/objects/8a/b686eafeb1f44702738c8b0f24f2567c36da6d

# Read the object
git cat-file -t 8ab686ea    # type: blob
git cat-file -p 8ab686ea    # content: Hello, Git!

# The SHA is computed from: type + size + content
echo -n "blob 13\0Hello, Git!" | sha1sum
```

### Step 3: Create your first commit

```bash
git config user.email "you@example.com"
git config user.name "Your Name"

git commit -m "feat: initial commit"

# Now find ALL objects created:
find .git/objects -type f | sort
# Three objects: blob, tree, commit

# Find the commit object
git cat-file -p HEAD          # The commit
git cat-file -p HEAD^{tree}   # The tree (directory listing)
git cat-file -p HEAD:README.md  # The blob (file content)

# HEAD is just a pointer:
cat .git/HEAD                  # ref: refs/heads/main
cat .git/refs/heads/main       # abc1234... (your commit SHA)
```

---

## Part 2: Branching and Merging

```bash
# Add more content
echo "# My Project" > README.md
echo "print('hello')" > app.py
git add . && git commit -m "feat: add app.py and update README"

# Create a feature branch
git checkout -b feature/login

# Make changes on feature branch
cat > login.py << 'EOF'
def login(username, password):
    if not username or not password:
        raise ValueError("Username and password required")
    return {"token": "jwt-" + username}
EOF

git add login.py
git commit -m "feat(auth): add login function"

# Meanwhile, make a change on main
git checkout main
echo "VERSION = '1.0.0'" >> app.py
git add app.py
git commit -m "chore: add version constant"

# Now merge (3-way merge)
git merge feature/login --no-ff -m "feat: merge login feature"

# Visualize the history
git log --oneline --graph --all
# *   abc1234 (HEAD -> main) feat: merge login feature
# |\
# | * def5678 (feature/login) feat(auth): add login function
# * | ghi9012 chore: add version constant
# |/
# * jkl3456 feat: add app.py and update README
# * mno7890 feat: initial commit
```

### Step 2: Rebase instead of merge

```bash
# Create another branch
git checkout -b feature/logout main

cat > logout.py << 'EOF'
def logout(token):
    # Invalidate the token
    return {"success": True}
EOF

git add logout.py
git commit -m "feat(auth): add logout function"

# Rebase onto main (linear history)
git checkout feature/logout
git rebase main

# Check the history — linear!
git log --oneline --graph feature/logout
# * xyz7890 (feature/logout) feat(auth): add logout function  ← NEW SHA!
# * abc1234 (main) feat: merge login feature
# ...

# Merge with fast-forward
git checkout main
git merge feature/logout   # Fast-forward: no merge commit needed

git log --oneline --graph
# All linear, clean history
```

---

## Part 3: Undoing Things

```bash
# Create a bad commit
echo "TODO: fix this later" >> app.py
echo "password = 'admin123'" >> app.py   # Oops!
git add app.py
git commit -m "WIP: debugging"

git log --oneline | head -5

# Method 1: Undo commit, keep changes staged
git reset HEAD~1 --soft
git status
# Changes to be committed: app.py
# Remove the sensitive line
sed -i "/password/d" app.py
git add app.py
git commit -m "fix: remove debug code"

# Method 2: Undo commit, keep changes unstaged
git reset HEAD~1 --mixed    # (default)
git status
# Changes not staged: app.py

# Method 3: Completely discard (use with caution!)
git reset HEAD~1 --hard
# The commit AND changes are gone
# But recoverable for 90 days via reflog:
git reflog | head -5
git checkout -b recovery $(git reflog | grep "WIP" | head -1 | awk '{print $1}')
```

---

## Part 4: Stash and Worktrees

```bash
# Stash scenario: you're mid-feature but need to check something
cat > feature-in-progress.py << 'EOF'
# Half-finished feature
def new_feature():
    pass  # TODO: implement
EOF
git add feature-in-progress.py

# Save work without committing
git stash push -m "WIP: new feature scaffold"
git stash list
# stash@{0}: On main: WIP: new feature scaffold

# Check something on a clean branch
git checkout main
cat login.py    # Everything is clean

# Resume work
git stash pop
# feature-in-progress.py is back

# Worktree: work on two branches simultaneously
git worktree add ../hotfix-lab main
ls ../hotfix-lab     # Full working tree, different branch

# Make a change in the worktree
cd ../hotfix-lab
echo "HOTFIX = True" >> app.py
git add app.py && git commit -m "hotfix: mark hotfix"

# Back in main worktree
cd ../git-lab
git log --oneline --all | head -10

# Remove worktree
git worktree remove ../hotfix-lab
```

---

## Part 5: Bisect — Find the Commit that Broke Tests

```bash
# Setup: simulate a regression
for i in 1 2 3 4 5; do
    echo "print($i)" >> app.py
    git add app.py
    git commit -m "chore: add step $i"
done

# Now introduce a "bug" at step 3
git log --oneline | head -8

# Use bisect to find it
git bisect start
git bisect bad HEAD           # Current is broken
git bisect good HEAD~5        # 5 commits ago was good

# Git checks out middle commit — you test:
cat app.py | grep "print(3)"  # Found it? 
git bisect good   # or: git bisect bad

# Continue until git says:
# "abc1234 is the first bad commit"

git bisect reset              # Back to HEAD
```

---

## Cleanup

```bash
cd ..
rm -rf git-lab ../hotfix-lab 2>/dev/null
echo "Lab 01 complete!"
```

## What You Learned

- [x] Git object model: blob, tree, commit
- [x] Branching: create, merge (3-way), rebase (linear)
- [x] Undoing: reset --soft, --mixed, --hard
- [x] Reflog: recovering "lost" work
- [x] Stash: saving work-in-progress
- [x] Worktrees: parallel branch development
- [x] Bisect: binary search for regression commits
