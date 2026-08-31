#!/usr/bin/env bash
# git_wall.sh — refuse repo rot at the git boundary.
#
# The oracle is .gitignore itself, read through `git check-ignore --no-index`:
# if git would ignore a path, it must not enter the index. Tracked grandfather
# rows live in scripts/git_wall_allowlist.txt and shrink as cleanup replays
# purge them — the wall does not widen.
#
# Modes:
#   --staged     pre-commit: refuse staged paths that match .gitignore (default)
#   --committed  suite watcher: refuse tracked paths outside the allowlist
#
# Also checks orphan lockfile pairs (lock staged without its manifest sibling).
#
# Run from anywhere: bash scripts/git_wall.sh [--staged|--committed]
set -o pipefail
cd "$(dirname "$0")/.."
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
MODE="${1:---staged}"
ALLOWLIST="scripts/git_wall_allowlist.txt"
fail=0

if [ ! -f "$ALLOWLIST" ]; then
    echo -e "${RED}git-wall FAILED${NC} — allowlist $ALLOWLIST is missing"
    exit 1
fi

# --- allowlist ---------------------------------------------------------------
ALLOWED_EXACT=()
ALLOWED_PREFIX=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    [ -n "$line" ] || continue
    if [ "${line: -1}" = / ]; then
        ALLOWED_PREFIX+=("$line")
    else
        ALLOWED_EXACT+=("$line")
    fi
done < "$ALLOWLIST"

is_allowlisted() {
    local path="$1" entry
    for entry in "${ALLOWED_EXACT[@]}"; do
        [ "$path" = "$entry" ] && return 0
    done
    for entry in "${ALLOWED_PREFIX[@]}"; do
        case "$path" in
            "$entry"*) return 0 ;;
        esac
    done
    return 1
}

# --- gitignore oracle --------------------------------------------------------
filter_violations() {
    local raw="$1" filtered="$2"
    : > "$filtered"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        if is_allowlisted "$path"; then
            continue
        fi
        git check-ignore -v --no-index "$path" 2>/dev/null >> "$filtered" || true
    done < "$raw"
}

collect_candidates() {
    local out="$1"
    shift
    "$@" > "$out"
}

# --- orphan lockfile pairs ---------------------------------------------------
check_orphan_locks() {
    local path dir base manifest manifest_path
    local -A staged_set=()

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        staged_set["$path"]=1
    done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null)

    [ ${#staged_set[@]} -gt 0 ] || return 0

    for path in "${!staged_set[@]}"; do
        base="$(basename "$path")"
        dir="$(dirname "$path")"
        [ "$dir" = . ] && dir=""

        case "$base" in
            package-lock.json) manifest="package.json" ;;
            Cargo.lock)        manifest="Cargo.toml" ;;
            yarn.lock|pnpm-lock.yaml|bun.lockb) manifest="package.json" ;;
            uv.lock)           manifest="pyproject.toml" ;;
            poetry.lock)       manifest="pyproject.toml" ;;
            *) continue ;;
        esac

        if [ -n "$dir" ]; then
            manifest_path="$dir/$manifest"
        else
            manifest_path="$manifest"
        fi

        if [ -n "${staged_set[$manifest_path]+x}" ]; then
            continue
        fi
        if git ls-files --error-unmatch "$manifest_path" >/dev/null 2>&1; then
            continue
        fi
        echo "  orphan lock: $path (no $manifest_path staged or tracked)"
        fail=1
    done
}

# --- modes -------------------------------------------------------------------
CAND=$(mktemp "${TMPDIR:-/tmp}/koru-gitwall-cand.XXXXXX")
VIOL=$(mktemp "${TMPDIR:-/tmp}/koru-gitwall-viol.XXXXXX")
trap 'rm -f "$CAND" "$VIOL"' EXIT

case "$MODE" in
    --staged)
        echo "git-wall — staged paths vs .gitignore (pre-commit oracle)"
        if ! git rev-parse --git-dir >/dev/null 2>&1; then
            echo -e "${RED}git-wall FAILED${NC} — not inside a git repository"
            exit 1
        fi
        if [ -z "$(git diff --cached --name-only 2>/dev/null)" ]; then
            echo -e "  ${GREEN}✓${NC} nothing staged"
            exit 0
        fi
        git diff --cached --name-only --diff-filter=ACMR > "$CAND"
        check_orphan_locks
        ;;
    --committed)
        echo "git-wall — tracked tree vs .gitignore (committed-tree oracle)"
        git ls-files > "$CAND"
        ;;
    *)
        echo "usage: bash scripts/git_wall.sh [--staged|--committed]" >&2
        exit 2
        ;;
esac

git check-ignore --no-index --stdin < "$CAND" > "${CAND}.ignored" 2>/dev/null || true
filter_violations "${CAND}.ignored" "$VIOL"

if [ -s "$VIOL" ]; then
    echo -e "  ${RED}✗${NC} path(s) .gitignore refuses — unallowlisted:"
    sed 's/^/      /' "$VIOL"
    echo ""
    echo "  The gitignore line is the fix; unstaging or deleting is the symptom."
    echo "  Grandfather only with a row in $ALLOWLIST, then purge and drop it."
    fail=1
elif [ "$fail" -eq 0 ]; then
    echo -e "  ${GREEN}✓${NC} no unallowlisted .gitignore violations"
fi

echo ""
if [ "$fail" -ne 0 ]; then
    echo -e "${RED}git-wall FAILED${NC}"
    exit 1
fi
echo -e "${GREEN}git-wall OK${NC}"
exit 0
