#!/bin/bash
# Lint for SwiftUI List crash risk patterns.
# Run: bash scripts/lint_collectionview_risks.sh [source_root]
#
# The primary crash pattern: using a custom Binding(get:set:) derived
# from @Observable / @State state as isPresented / item for
# alert/sheet/confirmationDialog/fullScreenCover on a View that
# contains a List. SwiftUI evaluates these bindings via
# dispatchImmediately during dismissal, re-entering the render cycle
# while a List batch update is in flight -> UICollectionView item count
# mismatch crash.
#
# Safe alternative: use a dedicated @State bool / @State optional and
# bind with $ syntax.

set -euo pipefail
ROOT="${1:-.}"
SRC="$ROOT/Palvia"
EXIT=0

echo "=== SwiftUI List Crash Risk Linter ==="
echo ""

# ── Pattern: custom Binding(get:set:) on isPresented / item ──────
# alert/sheet/confirmationDialog/fullScreenCover with Binding(get:set:)
# triggers dispatchImmediately during dismissal, re-entering the render
# cycle. Use @State bool / @State optional with $ binding instead.
echo "-- Custom Binding on presentation modifiers (dispatchImmediately crash) --"
FOUND=$(grep -rn -E '(isPresented|item):\s*Binding\(' "$SRC" --include='*.swift' \
    | grep -v '\.build/' | grep -v 'Tests/' || true)
if [ -n "$FOUND" ]; then
    echo "$FOUND"
    echo ""
    echo "  Custom Binding(get:set:) on isPresented/item triggers"
    echo "  dispatchImmediately during dismissal, re-entering the render"
    echo "  cycle and crashing UICollectionView batch updates."
    echo ""
    echo "  Fix: use a dedicated @State property with \$ binding:"
    echo "    @State private var showSheet = false"
    echo "    .sheet(isPresented: \$showSheet)"
    echo ""
    echo "    @State private var selectedItem: MyType?"
    echo "    .fullScreenCover(item: \$selectedItem)"
    EXIT=1
else
    echo "  No custom Binding on presentation modifiers found."
fi
echo ""

if [ $EXIT -eq 0 ]; then
    echo "All clear."
else
    echo "Found potential crash risks. See above for details."
fi
exit $EXIT
