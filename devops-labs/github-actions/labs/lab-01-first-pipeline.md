# Lab 01: Your First CI/CD Pipeline

**Difficulty**: Beginner | **Time**: 45 minutes  
**Goal**: Build a working CI pipeline that tests, builds, and reports results on every PR.

---

## Prerequisites

- A GitHub account
- A GitHub repository (create a new one for this lab)
- Basic Python knowledge

---

## Part 1: Project Setup

### Step 1: Create the project files

```bash
mkdir gha-lab && cd gha-lab
git init

# Create a simple Python calculator app
cat > calculator.py << 'EOF'
def add(a, b):
    return a + b

def subtract(a, b):
    return a - b

def multiply(a, b):
    return a * b

def divide(a, b):
    if b == 0:
        raise ZeroDivisionError("Cannot divide by zero")
    return a / b
EOF

# Create tests
cat > tests/test_calculator.py << 'EOF'
import pytest
from calculator import add, subtract, multiply, divide

class TestAdd:
    def test_positive(self):
        assert add(2, 3) == 5
    def test_negative(self):
        assert add(-1, -1) == -2
    def test_zero(self):
        assert add(0, 0) == 0

class TestDivide:
    def test_normal(self):
        assert divide(10, 2) == 5.0
    def test_zero_division(self):
        with pytest.raises(ZeroDivisionError):
            divide(5, 0)
EOF

mkdir -p tests
touch tests/__init__.py

# Requirements
echo "pytest==7.4.3
pytest-cov==4.1.0" > requirements-dev.txt

# Python version file
echo "3.12" > .python-version

# .gitignore
cat > .gitignore << 'EOF'
__pycache__/
*.pyc
.pytest_cache/
.coverage
htmlcov/
dist/
.venv/
EOF
```

### Step 2: Push to GitHub

```bash
git add .
git commit -m "feat: add calculator with tests"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/gha-lab.git
git push -u origin main
```

---

## Part 2: Create Your First Workflow

### Step 1: Create the workflow file

```bash
mkdir -p .github/workflows

cat > .github/workflows/ci.yml << 'EOF'
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    name: Run Tests
    runs-on: ubuntu-latest

    steps:
    # Step 1: Check out the code
    - name: Checkout code
      uses: actions/checkout@v4

    # Step 2: Set up Python
    - name: Set up Python 3.12
      uses: actions/setup-python@v5
      with:
        python-version: '3.12'
        cache: 'pip'    # Cache pip downloads

    # Step 3: Install dependencies
    - name: Install dependencies
      run: pip install -r requirements-dev.txt

    # Step 4: Run tests with coverage
    - name: Run tests
      run: |
        pytest tests/ \
          -v \
          --cov=. \
          --cov-report=term-missing \
          --cov-report=xml

    # Step 5: Upload coverage report
    - name: Upload coverage report
      uses: actions/upload-artifact@v4
      with:
        name: coverage-report
        path: coverage.xml
        retention-days: 7
EOF

git add .github/
git commit -m "ci: add basic CI workflow"
git push
```

### Step 2: Watch it run

1. Go to your GitHub repository
2. Click **Actions** tab
3. You should see your workflow running!
4. Click on it to see the logs

---

## Part 3: Add Code Quality Checks

```bash
# Add linting to the workflow
cat > .github/workflows/ci.yml << 'EOF'
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    name: Lint
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-python@v5
      with:
        python-version: '3.12'
        cache: pip
    - run: pip install ruff
    - run: ruff check .

  test:
    name: Test (Python ${{ matrix.python-version }})
    needs: lint                    # Only test if lint passes
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ['3.11', '3.12']

    steps:
    - uses: actions/checkout@v4

    - uses: actions/setup-python@v5
      with:
        python-version: ${{ matrix.python-version }}
        cache: pip

    - run: pip install -r requirements-dev.txt

    - name: Run tests
      run: pytest tests/ -v --cov=. --cov-report=xml

    - name: Upload coverage
      uses: actions/upload-artifact@v4
      with:
        name: coverage-${{ matrix.python-version }}
        path: coverage.xml
EOF

git add .github/
git commit -m "ci: add linting and matrix testing"
git push
```

---

## Part 4: Test the PR Workflow

### Step 1: Create a branch with a bug

```bash
git checkout -b feature/broken-feature

# Introduce a bug
cat > calculator.py << 'EOF'
def add(a, b):
    return a + b + 1  # BUG: off by one!

def subtract(a, b):
    return a - b

def multiply(a, b):
    return a * b

def divide(a, b):
    if b == 0:
        raise ZeroDivisionError("Cannot divide by zero")
    return a / b
EOF

git add calculator.py
git commit -m "feat: add broken feature"
git push origin feature/broken-feature
```

### Step 2: Create a Pull Request

1. Go to GitHub repository
2. Click **Compare & pull request** for `feature/broken-feature`
3. Create the PR

### Step 3: Watch the CI fail

- GitHub Actions runs your tests automatically
- The test for `add(2,3) == 5` will fail!
- GitHub shows ❌ on the PR

### Step 4: Fix the bug and see CI pass

```bash
cat > calculator.py << 'EOF'
def add(a, b):
    return a + b   # Fixed!

def subtract(a, b):
    return a - b

def multiply(a, b):
    return a * b

def divide(a, b):
    if b == 0:
        raise ZeroDivisionError("Cannot divide by zero")
    return a / b
EOF

git add calculator.py
git commit -m "fix: correct add function"
git push origin feature/broken-feature
```

- GitHub Actions re-runs on the new push
- Tests pass → ✅ on PR
- Merge the PR!

---

## Part 5: Add a Badge to README

```bash
cat > README.md << 'EOF'
# Calculator

[![CI](https://github.com/YOUR_USERNAME/gha-lab/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_USERNAME/gha-lab/actions/workflows/ci.yml)

A simple Python calculator with full CI/CD pipeline.

## Usage

```python
from calculator import add, subtract, multiply, divide

result = add(2, 3)      # 5
result = divide(10, 2)  # 5.0
```
EOF

git add README.md
git commit -m "docs: add CI badge to README"
git push
```

---

## What You Learned

- [x] GitHub Actions workflow syntax (name, on, jobs, steps)
- [x] Event triggers: push and pull_request
- [x] Using marketplace actions (checkout, setup-python)
- [x] Running commands with `run:`
- [x] Matrix testing across Python versions
- [x] Job dependencies with `needs:`
- [x] CI blocking bad PRs from merging
- [x] Artifacts for preserving test reports

## Next Lab

→ [Lab 02: Docker Build and Deploy Pipeline](lab-02-docker-deploy.md)
