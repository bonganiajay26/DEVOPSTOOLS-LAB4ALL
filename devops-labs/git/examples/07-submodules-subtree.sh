#!/bin/bash
# Example 07: Git Submodules vs Subtree — When and How

# ══════════════════════════════════════════
# SUBMODULES — pin external dependency by commit SHA
# ══════════════════════════════════════════

submodule_demo() {
    echo "=== Git Submodules Demo ==="

    # Add a submodule
    git submodule add https://github.com/myorg/shared-lib libs/shared-lib
    # Creates: .gitmodules file + libs/shared-lib/ directory
    # The submodule is a pointer to a specific commit

    git add .gitmodules libs/shared-lib
    git commit -m "chore: add shared-lib v1.2.0 as submodule"

    # Clone with submodules
    echo "# Clone with submodules (two methods):"
    echo "git clone --recurse-submodules https://github.com/myorg/myapp"
    echo "# OR (existing clone):"
    echo "git submodule update --init --recursive"

    # Update submodule to latest
    cd libs/shared-lib
    git checkout main
    git pull
    cd ../..
    git add libs/shared-lib
    git commit -m "chore: update shared-lib to v1.3.0"

    # Update all submodules to latest
    git submodule update --remote --merge

    # Check submodule status
    git submodule status
    # abc1234 libs/shared-lib (v1.3.0)

    # Run command in all submodules
    git submodule foreach 'git pull origin main'
}

# ══════════════════════════════════════════
# SUBTREE — merge external repo into your repo
# Better than submodules for: no separate clone needed
# ══════════════════════════════════════════

subtree_demo() {
    echo "=== Git Subtree Demo ==="

    # Add external repo as subtree
    git remote add shared-lib https://github.com/myorg/shared-lib
    git fetch shared-lib

    git subtree add \
        --prefix=libs/shared-lib \
        shared-lib main \
        --squash
    # --squash: merge all remote history into one commit

    # Update subtree from upstream
    git subtree pull \
        --prefix=libs/shared-lib \
        shared-lib main \
        --squash

    # Push changes back upstream (contribute back)
    git subtree push \
        --prefix=libs/shared-lib \
        shared-lib feature/my-improvement

    # Split subtree into separate repo (extract history)
    git subtree split \
        --prefix=libs/shared-lib \
        --onto=shared-lib/main \
        --rejoin \
        --branch=shared-lib-branch
}

# ══════════════════════════════════════════
# COMPARISON
# ══════════════════════════════════════════

echo "Submodules vs Subtrees:"
echo ""
echo "Submodules:"
echo "  + Keeps history separate"
echo "  + Easy to update specific version"
echo "  + Smaller main repo"
echo "  - Requires: git submodule update after clone"
echo "  - Easy to forget to commit submodule pointer"
echo "  - Complex workflows for contributors"
echo ""
echo "Subtrees:"
echo "  + Works with any git clone (no extra commands)"
echo "  + All code in one repo, one history"
echo "  + Can push changes back upstream"
echo "  - History interleaved with main repo"
echo "  - Larger repo size"
echo "  - Harder to see which files come from upstream"
echo ""
echo "Recommendation:"
echo "  External vendor dependency you don't modify → submodule"
echo "  Internal shared library you contribute to → subtree"

case "${1:-compare}" in
    submodule) submodule_demo ;;
    subtree)   subtree_demo ;;
    compare)   echo "Run with: submodule | subtree | compare" ;;
esac
