#!/bin/bash
# Lint for SwiftData model migration risks.
#
# Catches non-optional stored properties in @Model classes that lack
# default values at the property-declaration level. Without these defaults
# SwiftData lightweight migration fails on schema changes, and the app's
# fallback handler deletes the entire database.
#
# Usage:
#   bash scripts/lint_swiftdata_migration.sh                  # diff vs develop
#   bash scripts/lint_swiftdata_migration.sh HEAD~1..HEAD     # check last commit
#   bash scripts/lint_swiftdata_migration.sh --full           # audit ALL models
#
# Exit codes: 0 = clean, 1 = violations found

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODEL_DIR="$ROOT/Palvia/Models"
EXIT=0

echo "=== SwiftData Migration Safety Linter ==="
echo ""

# ── Helper: check a single Swift file for unsafe @Model properties ──
# Parses the @Model class body and flags non-optional stored properties
# that have no default value. Skips @Transient, @Relationship (arrays),
# computed properties, and optional types.
#
# Args: $1 = file path, $2 = optional line filter (grep pattern)
check_model_file() {
    local file="$1"
    local line_filter="${2:-}"
    local in_model=0
    local brace_depth=0
    local skip_next=0
    local lineno=0
    local found=0

    while IFS= read -r line; do
        lineno=$((lineno + 1))

        # Detect @Model attribute
        if [[ "$line" =~ ^[[:space:]]*@Model ]]; then
            in_model=1
            brace_depth=0
            continue
        fi

        # Track brace depth inside @Model class
        if [[ $in_model -eq 1 ]]; then
            # Count opening braces
            opens="${line//[^\{]/}"
            closes="${line//[^\}]/}"
            brace_depth=$((brace_depth + ${#opens} - ${#closes}))

            # Class body ended
            if [[ $brace_depth -le 0 && ${#opens} -eq 0 && ${#closes} -gt 0 ]]; then
                in_model=0
                continue
            fi

            # Skip @Transient / @Relationship properties
            if [[ "$line" =~ ^[[:space:]]*@(Transient|Relationship) ]]; then
                skip_next=1
                continue
            fi
            if [[ $skip_next -eq 1 ]]; then
                skip_next=0
                # If the @attr was on the same line as var, it was already handled
                if [[ "$line" =~ ^[[:space:]]*var[[:space:]] ]]; then
                    continue
                fi
                continue
            fi

            # Only examine top-level stored var declarations (brace_depth == 1)
            if [[ $brace_depth -ne 1 ]]; then
                continue
            fi

            # Match stored property: "var name: Type" at class body level
            if [[ "$line" =~ ^[[:space:]]*var[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.+) ]]; then
                local prop_name="${BASH_REMATCH[1]}"
                local rest="${BASH_REMATCH[2]}"

                # Skip computed properties (line contains { without =)
                if [[ "$rest" =~ \{ ]] && [[ ! "$rest" =~ = ]]; then
                    continue
                fi

                # Skip optional types (ends with ? before any =)
                local type_part="${rest%%=*}"
                type_part="${type_part%%\{*}"
                type_part="$(echo "$type_part" | sed 's/[[:space:]]*$//')"
                if [[ "$type_part" =~ \?$ ]]; then
                    continue
                fi

                # Skip array types (SwiftData auto-initializes relationship arrays)
                if [[ "$type_part" =~ ^\[.*\]$ ]]; then
                    continue
                fi

                # Check for default value
                if [[ "$rest" =~ = ]]; then
                    continue
                fi

                # If line filter is set, only report matching lines
                if [[ -n "$line_filter" ]] && ! echo "$lineno" | grep -qw "$line_filter"; then
                    continue
                fi

                echo "  $(basename "$file"):$lineno  var $prop_name: $type_part  -- missing default value"
                found=1
            fi
        fi
    done < "$file"

    return $found
}

# ── Mode: full audit ──
if [[ "${1:-}" == "--full" ]]; then
    echo "Mode: Full audit of all @Model classes"
    echo ""
    violations=0

    for file in "$MODEL_DIR"/*.swift; do
        if grep -q '@Model' "$file" 2>/dev/null; then
            if ! check_model_file "$file"; then
                violations=1
            fi
        fi
    done

    if [[ $violations -eq 0 ]]; then
        echo "  (no violations -- all non-optional properties have defaults or are optional)"
    fi
    echo ""

    if [[ $violations -eq 1 ]]; then
        echo "NOTE: Properties listed above lack declaration-level defaults."
        echo "If these are original (v1) properties, they are safe. But if any were"
        echo "added after the initial release, they MUST have defaults for SwiftData"
        echo "lightweight migration to work. Without defaults, the ModelContainer"
        echo "will fail to open and the app will delete the database."
        echo ""
        echo "Fix: add a default value to the property declaration:"
        echo "  var myProp: String = \"\"      // not just in init()"
        echo "  var myCount: Int = 0"
        echo ""
    fi
    exit 0
fi

# ── Mode: diff check (default) ──
DIFF_RANGE="${1:-origin/develop..HEAD}"

echo "Mode: Diff check ($DIFF_RANGE)"
echo ""

# Get list of model files changed in the diff range
CHANGED_MODEL_FILES=$(git diff --name-only "$DIFF_RANGE" -- 'Palvia/Models/*.swift' 2>/dev/null || true)

if [[ -z "$CHANGED_MODEL_FILES" ]]; then
    echo "No model files changed in $DIFF_RANGE."
    echo ""
    echo "  All clear."
    exit 0
fi

# For each changed model file, get the added lines and check them
for relpath in $CHANGED_MODEL_FILES; do
    file="$ROOT/$relpath"
    [[ -f "$file" ]] || continue
    grep -q '@Model' "$file" 2>/dev/null || continue

    # Get line numbers of added lines (lines starting with + in diff, excluding +++ header)
    ADDED_LINES=$(git diff "$DIFF_RANGE" -- "$relpath" \
        | grep -n '^+' | grep -v '^[0-9]*:+++' \
        | grep -oP '(?<=@@\s\+)\d+' || true)

    # Alternative: get added/removed var lines directly from the diff.
    # Ignore pure rename noise by skipping added var lines that have an
    # identical removed counterpart in the same file diff.
    ADDED_VARS=$(git diff "$DIFF_RANGE" -- "$relpath" \
        | grep '^+' | grep -v '^+++' \
        | grep -E '^\+[[:space:]]*var[[:space:]]' || true)
    REMOVED_VARS=$(git diff "$DIFF_RANGE" -- "$relpath" \
        | grep '^-' | grep -v '^---' \
        | grep -E '^-[[:space:]]*var[[:space:]]' || true)

    if [[ -z "$ADDED_VARS" ]]; then
        continue
    fi

    # Check each added var line
    while IFS= read -r diffline; do
        # Strip leading +
        line="${diffline#+}"

        # If this exact var line also existed before (rename/reflow), ignore it.
        if [[ -n "${REMOVED_VARS:-}" ]]; then
            if echo "$REMOVED_VARS" | sed 's/^-//' | grep -Fxq "$line"; then
                continue
            fi
        fi

        # Skip @Transient / @Relationship (handled by context, but catch simple cases)
        if [[ "$line" =~ @(Transient|Relationship) ]]; then
            continue
        fi

        # Match stored property
        if [[ "$line" =~ ^[[:space:]]*var[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*:[[:space:]]*(.+) ]]; then
            local_prop="${BASH_REMATCH[1]}"
            local_rest="${BASH_REMATCH[2]}"

            # Skip computed properties
            if [[ "$local_rest" =~ \{ ]] && [[ ! "$local_rest" =~ = ]]; then
                continue
            fi

            # Skip optional types
            local_type="${local_rest%%=*}"
            local_type="${local_type%%\{*}"
            local_type="$(echo "$local_type" | sed 's/[[:space:]]*$//')"
            if [[ "$local_type" =~ \?$ ]]; then
                continue
            fi

            # Skip array types
            if [[ "$local_type" =~ ^\[.*\]$ ]]; then
                continue
            fi

            # Check for default value
            if [[ "$local_rest" =~ = ]]; then
                continue
            fi

            echo "  $relpath: var $local_prop: $local_type  -- MISSING DEFAULT VALUE"
            EXIT=1
        fi
    done <<< "$ADDED_VARS"
done

echo ""
if [[ $EXIT -eq 0 ]]; then
    echo "  All new @Model properties have defaults or are optional."
else
    echo "ERROR: New @Model properties found without default values!"
    echo ""
    echo "SwiftData lightweight migration requires declaration-level defaults"
    echo "for all new non-optional properties. Without them, ModelContainer"
    echo "creation fails and the app DELETES THE ENTIRE DATABASE."
    echo ""
    echo "Fix: add a default value at the property declaration:"
    echo "  var myProp: String = \"\"      // not just in init()"
    echo "  var myCount: Int = 0"
    echo ""
fi
exit $EXIT
