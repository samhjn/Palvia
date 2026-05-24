#!/bin/bash
# Lint for side effects in `App.init()` / `View.init()`.
#
# SwiftUI calls `App.init()` and `View.init()` on every body re-evaluation.
# Heavy I/O or SwiftData mutations in `init()` cascade through observation
# back into view invalidation, and on iOS 17.0 GA this re-entrancy reliably
# trips a Swift runtime trap (EXC_BREAKPOINT brk 1) inside libswiftCore at
# launch — see Palvia/App/PalviaApp.swift for the documented fix.
#
# Forbidden in init() bodies of types conforming to `App` or `View`:
#   - .save()                          SwiftData / Core Data writes
#   - try? <ctx>.fetch(                SwiftData reads (cheap, but writes
#                                      typically follow — flag for review)
#   - FileManager.default.{removeItem,createDirectory,copyItem,moveItem,
#                          createFile,write}
#   - UserDefaults...set( / .removeObject( / .synchronize(
#   - .destinationOfSymbolicLink( / .createSymbolicLink(
#
# Escape hatch: append `// lint:ignore launch-side-effect` on the offending
# line. Use sparingly — prefer moving the work to .task / .onAppear and
# guarding with a process-wide flag.
#
# Usage:
#   bash scripts/lint_app_init_side_effects.sh                # full scan
#   bash scripts/lint_app_init_side_effects.sh path/to/dir    # custom root
#
# Exit codes: 0 = clean, 1 = violations found

set -euo pipefail
ROOT="${1:-.}"
SRC="$ROOT/Palvia"
EXIT=0

echo "=== App/View init() Side-Effect Linter ==="
echo ""

# Find Swift files declaring a type that conforms to App or View.
# Match `: App ` / `: App,` / `: App {` and same for View. The trailing
# context character avoids matching `: AppDelegate` etc.
CANDIDATES=$(grep -rl -E ':[[:space:]]*(App|View)[[:space:],{]' "$SRC" --include='*.swift' \
    | grep -v '/\.build/' || true)

if [ -z "$CANDIDATES" ]; then
    echo "  No App/View conformers found (unexpected)."
    exit 0
fi

# Forbidden patterns (extended regex). Each is checked inside init() bodies.
PATTERNS=(
    '\.save\(\)'
    'try\?[[:space:]]+[A-Za-z_][A-Za-z0-9_]*\.fetch\('
    'FileManager\.default\.(removeItem|createDirectory|copyItem|moveItem|createFile|write)'
    'FileManager\.default\.contentsOfDirectory\('
    'UserDefaults\.[A-Za-z_]+\.(set|removeObject|synchronize)\('
    '\.destinationOfSymbolicLink\('
    '\.createSymbolicLink\('
)

# awk script: emit lines that lie inside the body of an `init(...) {`
# declaration, with the original 1-based line number. Naive brace tracking,
# good enough for normal Swift formatting.
AWK_EXTRACT='
BEGIN { depth = 0; in_init = 0; init_depth = 0 }
{
    line = $0
    # Strip line comments to avoid counting braces inside them.
    sub(/\/\/.*/, "", line)

    # Detect start of an init() declaration. Allow access modifiers,
    # `required`, `convenience`, `@MainActor`, etc., and `init?` / `init!`.
    if (!in_init && line ~ /(^|[[:space:]])init[?!]?[[:space:]]*\(/) {
        in_init = 1
        init_depth = depth
        # If the opening { is on the same line, depth math below handles it.
    }

    # Count braces.
    o = gsub(/\{/, "{", line)
    c = gsub(/\}/, "}", line)
    new_depth = depth + o - c

    if (in_init) {
        # We consider lines strictly between the opening { (depth > init_depth)
        # and the matching } that returns to init_depth.
        if (depth > init_depth || (depth == init_depth && o > 0)) {
            print NR ":" $0
        }
        if (new_depth <= init_depth && c > 0 && in_init) {
            in_init = 0
        }
    }
    depth = new_depth
}'

for file in $CANDIDATES; do
    # Quick reject: file does not contain `init(` at all
    grep -q -E '(^|[[:space:]])init[?!]?[[:space:]]*\(' "$file" || continue

    INIT_BODY=$(awk "$AWK_EXTRACT" "$file" || true)
    [ -z "$INIT_BODY" ] && continue

    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        # Skip lines explicitly opted out.
        if echo "$entry" | grep -q 'lint:ignore launch-side-effect'; then
            continue
        fi
        for pat in "${PATTERNS[@]}"; do
            if echo "$entry" | grep -qE "$pat"; then
                lineno="${entry%%:*}"
                content="${entry#*:}"
                relpath="${file#"$ROOT"/}"
                echo "  $relpath:$lineno  matches /$pat/"
                echo "    $(echo "$content" | sed 's/^[[:space:]]*//')"
                EXIT=1
                break
            fi
        done
    done <<< "$INIT_BODY"
done

echo ""
if [ $EXIT -eq 0 ]; then
    echo "  All clear — no side effects in App/View init() bodies."
else
    echo "ERROR: side effects detected in App/View init()."
    echo ""
    echo "SwiftUI calls init() on every body re-evaluation. SwiftData writes,"
    echo "filesystem mutations, and UserDefaults writes inside init() cascade"
    echo "through observation back into view invalidation, which on iOS 17.0"
    echo "trips a Swift runtime trap at launch (EXC_BREAKPOINT brk 1)."
    echo ""
    echo "Fix: move the work to .task / .onAppear, or gate it with a"
    echo "process-wide static flag (see PalviaApp.didRunOneTimeLaunchTasks)."
    echo "If the call site is genuinely safe, append:"
    echo "    // lint:ignore launch-side-effect"
fi
exit $EXIT
