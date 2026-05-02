# Lab 02: Team Git Workflow — PRs, Code Review, and Conflict Resolution

**Difficulty**: Intermediate | **Time**: 60 minutes  
**Goal**: Simulate a real team workflow: feature branches, PRs, code review, merge conflicts.

---

## Setup: Simulate a Remote (Bare Repo)

```bash
# Create a "remote" bare repository (simulates GitHub)
mkdir ~/git-remote-lab && cd ~/git-remote-lab
git init --bare team-project.git

# Clone it twice (simulates 2 developers)
cd ~
git clone ~/git-remote-lab/team-project.git dev-alice
git clone ~/git-remote-lab/team-project.git dev-bob

# Setup identities
cd ~/dev-alice
git config user.name "Alice" && git config user.email "alice@company.com"

cd ~/dev-bob
git config user.name "Bob" && git config user.email "bob@company.com"
```

---

## Part 1: Initial Codebase Setup (Alice)

```bash
cd ~/dev-alice

# Create initial project
cat > main.py << 'EOF'
"""E-commerce order processing system."""

TAX_RATE = 0.08

def calculate_total(items):
    subtotal = sum(item['price'] * item['qty'] for item in items)
    tax = subtotal * TAX_RATE
    return {"subtotal": subtotal, "tax": tax, "total": subtotal + tax}

def process_order(order):
    totals = calculate_total(order['items'])
    return {
        "order_id": order['id'],
        "status": "confirmed",
        **totals
    }
EOF

cat > tests/test_main.py << 'EOF'
import pytest
from main import calculate_total, process_order

def test_calculate_total():
    items = [{"price": 10.0, "qty": 2}, {"price": 5.0, "qty": 1}]
    result = calculate_total(items)
    assert result["subtotal"] == 25.0
    assert abs(result["tax"] - 2.0) < 0.01
    assert abs(result["total"] - 27.0) < 0.01

def test_process_order():
    order = {"id": "ORD-001", "items": [{"price": 100.0, "qty": 1}]}
    result = process_order(order)
    assert result["order_id"] == "ORD-001"
    assert result["status"] == "confirmed"
EOF

mkdir -p tests
git add .
git commit -m "feat: initial order processing module"
git push origin main
```

---

## Part 2: Parallel Feature Development

### Alice adds discount feature

```bash
cd ~/dev-alice
git checkout -b feature/discount-codes

cat >> main.py << 'EOF'

DISCOUNT_CODES = {
    "SAVE10": 0.10,
    "SAVE20": 0.20,
    "FREESHIP": 0.0,   # Free shipping only
}

def apply_discount(total, code):
    if code not in DISCOUNT_CODES:
        raise ValueError(f"Invalid discount code: {code}")
    discount_rate = DISCOUNT_CODES[code]
    discount_amount = total * discount_rate
    return total - discount_amount
EOF

git add main.py
git commit -m "feat(discount): add discount code system"

cat >> tests/test_main.py << 'EOF'

def test_apply_discount():
    assert apply_discount(100.0, "SAVE10") == 90.0
    assert apply_discount(100.0, "SAVE20") == 80.0
    with pytest.raises(ValueError):
        apply_discount(100.0, "INVALID")
EOF

git add tests/
git commit -m "test: add discount code tests"
git push origin feature/discount-codes
```

### Bob adds shipping feature (simultaneously)

```bash
cd ~/dev-bob
git checkout -b feature/shipping-calculator

cat >> main.py << 'EOF'

SHIPPING_RATES = {
    "standard": 5.99,
    "express": 12.99,
    "overnight": 24.99,
}

def calculate_shipping(total, method="standard"):
    if method not in SHIPPING_RATES:
        raise ValueError(f"Invalid shipping method: {method}")
    # Free shipping over $100
    if total >= 100.0 and method == "standard":
        return 0.0
    return SHIPPING_RATES[method]
EOF

git add main.py
git commit -m "feat(shipping): add shipping calculator"
git push origin feature/shipping-calculator
```

---

## Part 3: Code Review Process

```bash
# Alice reviews Bob's shipping feature
cd ~/dev-alice
git fetch origin
git checkout -b review/shipping origin/feature/shipping-calculator

# Review the code
cat main.py

# Add a comment/suggestion (in real GitHub, this is a PR comment)
# Alice notices: method parameter could default to None and validate differently
# She creates a suggestion commit on her review branch:
cat >> main.py << 'EOF'

# Alice's suggestion: add method validation helper
def valid_shipping_method(method):
    return method in SHIPPING_RATES
EOF

git add main.py
git commit -m "review: suggest shipping method validator helper"

# In real workflow: push to PR branch or comment in GitHub
# For this lab: Bob applies the suggestion
```

---

## Part 4: Resolving Merge Conflicts

```bash
# Both Alice and Bob modified main.py
# Merging their features will cause a conflict

cd ~/dev-alice
git checkout main
git pull origin main

# Merge Alice's feature first
git merge feature/discount-codes --no-ff -m "feat: merge discount codes"
git push origin main

# Now Bob tries to merge — conflict!
cd ~/dev-bob
git checkout main
git pull origin main
git merge feature/shipping-calculator
# CONFLICT: both modified main.py

git status
# both modified: main.py

# See the conflict
cat main.py
# <<<<<<< HEAD (main with Alice's discount code)
# DISCOUNT_CODES = {...}
# ...
# =======
# SHIPPING_RATES = {...}
# ...
# >>>>>>> feature/shipping-calculator

# Resolve: KEEP BOTH features
# Edit main.py to include both discount AND shipping sections
# Remove conflict markers

# Mark as resolved
git add main.py

# Verify everything still works
python3 -c "from main import calculate_total, apply_discount, calculate_shipping; print('All imports OK')"

git commit -m "feat: merge shipping calculator (resolve conflict with discount codes)"
git push origin main
```

---

## Part 5: Interactive Rebase — Clean History Before PR

```bash
cd ~/dev-alice
git checkout -b feature/order-summary main

# Simulate messy development history
echo "# work in progress" >> main.py && git add . && git commit -m "WIP"
echo "# more work" >> main.py && git add . && git commit -m "WIP 2"
echo "# typo fix" >> main.py && git add . && git commit -m "fix typo"

cat >> main.py << 'EOF'

def order_summary(order_id, items, discount_code=None, shipping_method="standard"):
    totals = calculate_total(items)
    shipping = calculate_shipping(totals["total"], shipping_method)
    final = totals["total"] + shipping
    if discount_code:
        final = apply_discount(final, discount_code)
    return {
        "order_id": order_id,
        "subtotal": totals["subtotal"],
        "tax": totals["tax"],
        "shipping": shipping,
        "discount_code": discount_code,
        "total": final
    }
EOF

git add main.py
git commit -m "feat: add order summary with all calculations"

git log --oneline HEAD~4..HEAD
# abc1234 feat: add order summary with all calculations
# def5678 fix typo
# ghi9012 WIP 2
# jkl3456 WIP

# Clean up before merging: squash WIP commits
git rebase -i HEAD~4
# In editor:
# pick jkl3456 WIP           → drop
# pick ghi9012 WIP 2         → drop
# pick def5678 fix typo      → fixup (squash into next)
# pick abc1234 feat: add...  → pick (keep this one)

git log --oneline HEAD~1..HEAD
# ONE clean commit!
git push origin feature/order-summary --force-with-lease
```

---

## Part 6: Tags and Releases

```bash
cd ~/dev-alice
git checkout main
git pull origin main

# Create an annotated release tag
git tag -a v1.0.0 -m "Release v1.0.0

Features:
- Order processing with tax calculation
- Discount code system (SAVE10, SAVE20)
- Shipping calculator with free shipping over $100
- Order summary combining all calculations

Breaking changes: None
"

git push origin v1.0.0

# Verify
git tag -l
git show v1.0.0
```

---

## Cleanup

```bash
rm -rf ~/git-remote-lab ~/dev-alice ~/dev-bob
echo "Lab 02 complete!"
```

## What You Learned

- [x] Parallel development on feature branches
- [x] Merge conflict resolution (3-way merge)
- [x] Interactive rebase to clean history before PR
- [x] Annotated tags for releases
- [x] Force-with-lease for safe force-push after rebase
