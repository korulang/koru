#!/usr/bin/env bash
set -euo pipefail

# --- Koru Release Build Script ---
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 0.1.3
#
# This script:
#   1. Validates prerequisites (zig, semver format)
#   2. Updates version in src/main.zig and dist/package.json
#   3. Cross-compiles koruc for 5 platform targets
#   4. Removes duplicate koru-* binaries from dist/binaries/
#   5. Syncs src/ and koru_std/ into dist/
#   6. Generates CHANGELOG.md via claude (falls back to raw log)
#   7. Removes old .tgz tarballs
#   8. Runs npm pack
#   9. Prints next steps (does NOT auto-commit or publish)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}==>${NC} $*"; }
ok()    { echo -e "    ${GREEN}OK${NC} $*"; }
warn()  { echo -e "    ${YELLOW}WARN${NC} $*"; }
fail()  { echo -e "    ${RED}FAIL${NC} $*"; }
die()   { echo -e "${RED}Error:${NC} $*" >&2; exit 1; }

# ─── Argument Parsing ────────────────────────────────────────────────

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 0.1.3"
    exit 1
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
    die "Invalid version format: '$VERSION' (expected semver, e.g. 0.1.3 or 0.1.3-rc.1)"
fi

# ─── Prerequisites ───────────────────────────────────────────────────

info "Checking prerequisites..."

if ! command -v zig &>/dev/null; then
    die "zig not found in PATH. Install from https://ziglang.org/download/"
fi
ok "zig $(zig version)"

# Warn on dirty working tree (don't block — user may want to build first, commit after)
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]]; then
    warn "Working tree has uncommitted changes."
    echo ""
fi

[[ -f "$ROOT_DIR/src/main.zig" ]]     || die "src/main.zig not found"
[[ -f "$DIST_DIR/package.json" ]]      || die "dist/package.json not found"
[[ -f "$ROOT_DIR/build.zig" ]]         || die "build.zig not found"

echo ""
info "Releasing @korulang/koru v${VERSION}"
echo ""

# ─── Step 1: Update Versions ────────────────────────────────────────

info "Updating version strings..."

# src/main.zig — replace the version constant
if grep -q 'const version = "' "$ROOT_DIR/src/main.zig"; then
    sed -i '' "s/const version = \"[^\"]*\"/const version = \"${VERSION}\"/" "$ROOT_DIR/src/main.zig"
    ok "src/main.zig -> ${VERSION}"
else
    die "Could not find version string in src/main.zig"
fi

# dist/package.json — update "version" field via node for safe JSON
node -e "
  const fs = require('fs');
  const p = '$DIST_DIR/package.json';
  const pkg = JSON.parse(fs.readFileSync(p, 'utf8'));
  pkg.version = '$VERSION';
  fs.writeFileSync(p, JSON.stringify(pkg, null, 2) + '\n');
"
ok "dist/package.json -> ${VERSION}"

echo ""

# ─── Step 2: Cross-Compile ──────────────────────────────────────────

TARGETS=(
    "aarch64-macos:koruc-macos-arm64"
    "x86_64-macos:koruc-macos-x64"
    "aarch64-linux-gnu:koruc-linux-arm64"
    "x86_64-linux-gnu:koruc-linux-x64"
    "x86_64-windows-gnu:koruc-windows-x64.exe"
)

mkdir -p "$DIST_DIR/binaries"

info "Cross-compiling koruc for ${#TARGETS[@]} targets..."
echo ""

COMPILE_FAILED=0
for entry in "${TARGETS[@]}"; do
    TRIPLE="${entry%%:*}"
    OUTNAME="${entry##*:}"

    printf "    %-28s -> %-26s " "$TRIPLE" "$OUTNAME"

    if [[ "$TRIPLE" == *"windows"* ]]; then
        SRC_BIN="koruc.exe"
    else
        SRC_BIN="koruc"
    fi

    if (cd "$ROOT_DIR" && zig build -Dtarget="$TRIPLE" -Doptimize=ReleaseFast 2>/dev/null); then
        if [[ -f "$ROOT_DIR/zig-out/bin/$SRC_BIN" ]]; then
            cp "$ROOT_DIR/zig-out/bin/$SRC_BIN" "$DIST_DIR/binaries/$OUTNAME"
            chmod +x "$DIST_DIR/binaries/$OUTNAME"
            SIZE=$(ls -lh "$DIST_DIR/binaries/$OUTNAME" | awk '{print $5}')
            echo -e "${GREEN}OK${NC} (${SIZE})"
        else
            echo -e "${RED}FAIL${NC} (binary not found)"
            COMPILE_FAILED=$((COMPILE_FAILED + 1))
        fi
    else
        echo -e "${RED}FAIL${NC} (compilation error)"
        COMPILE_FAILED=$((COMPILE_FAILED + 1))
    fi
done

echo ""
if [[ $COMPILE_FAILED -gt 0 ]]; then
    die "$COMPILE_FAILED target(s) failed to compile. Fix errors before releasing."
fi
ok "All ${#TARGETS[@]} targets compiled."
echo ""

# ─── Step 3: Remove Duplicate koru-* Binaries ───────────────────────

info "Removing duplicate koru-* binaries..."
REMOVED=0
for f in "$DIST_DIR/binaries"/koru-*; do
    [[ -e "$f" ]] || continue
    basename="$(basename "$f")"
    # Only remove koru-* (not koruc-*)
    if [[ "$basename" == koru-* && "$basename" != koruc-* ]]; then
        rm "$f"
        REMOVED=$((REMOVED + 1))
    fi
done
if [[ $REMOVED -gt 0 ]]; then
    ok "Removed $REMOVED duplicate koru-* binaries."
else
    ok "No duplicate koru-* binaries found."
fi
echo ""

# ─── Step 4: Sync src/ -> dist/src/ ─────────────────────────────────

info "Syncing src/ -> dist/src/..."
rsync -a --delete "$ROOT_DIR/src/" "$DIST_DIR/src/"
# Strip non-shipping files
find "$DIST_DIR/src" -type f \( -name '*.bak*' -o -name '*.backup' -o -name '*.md' -o -name '*_test.zig' \) -delete
find "$DIST_DIR/src" -type d -empty -delete 2>/dev/null || true
src_count=$(find "$DIST_DIR/src" -type f | wc -l | tr -d ' ')
ok "$src_count files synced."

# ─── Step 5: Sync koru_std/ -> dist/koru_std/ ───────────────────────

info "Syncing koru_std/ -> dist/koru_std/..."
rsync -a --delete "$ROOT_DIR/koru_std/" "$DIST_DIR/koru_std/"
# Strip build artifacts and non-shipping files
rm -rf "$DIST_DIR/koru_std/.zig-cache" \
       "$DIST_DIR/koru_std/zig-out" \
       "$DIST_DIR/koru_std/backend_tmp" \
       "$DIST_DIR/koru_std/test_flowast_final" \
       "$DIST_DIR/koru_std/backend_output_emitted.zig"
find "$DIST_DIR/koru_std" -type f -name '*.md' -delete
find "$DIST_DIR/koru_std" -type d -empty -delete 2>/dev/null || true
std_count=$(find "$DIST_DIR/koru_std" -type f | wc -l | tr -d ' ')
ok "$std_count files synced."
echo ""

# ─── Step 6: Generate CHANGELOG.md ──────────────────────────────────

info "Generating CHANGELOG.md..."

# Find the previous tag to scope the log
PREV_TAG=$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null || echo "")
if [[ -n "$PREV_TAG" ]]; then
    LOG_RANGE="${PREV_TAG}..HEAD"
    ok "Previous tag: $PREV_TAG"
else
    LOG_RANGE="HEAD"
    warn "No previous tag found — using full history."
fi

# Dump raw commit log
COMMIT_LOG=$(git -C "$ROOT_DIR" log "$LOG_RANGE" --oneline --no-merges)
COMMIT_COUNT=$(echo "$COMMIT_LOG" | wc -l | tr -d ' ')
ok "$COMMIT_COUNT commits since ${PREV_TAG:-initial commit}."

# Generate changelog via claude
CHANGELOG="$DIST_DIR/CHANGELOG.md"
if command -v claude &>/dev/null; then
    info "Summarizing with claude..."
    CLAUDECODE= claude -p --model sonnet "OUTPUT ONLY THE CHANGELOG FILE CONTENTS. No commentary, no questions, no preamble.

Generate a CHANGELOG.md for @korulang/koru v${VERSION} (a compiler for the Koru language).

Commits since last release (${PREV_TAG:-initial commit}):

${COMMIT_LOG}

Format rules:
- Start with: # Changelog
- Then: ## v${VERSION}
- Group into sections: ### Features, ### Fixes, ### Internal (only if significant refactors)
- Each item is a single line: '- Description (commit-hash)'
- Merge obviously related commits into one entry
- Drop test-only, snapshot-only, and chore commits unless they signal something important
- No paragraphs, no prose — just the list
- End with: **${COMMIT_COUNT} commits since ${PREV_TAG:-initial commit}**" > "$CHANGELOG"
    ok "Written to dist/CHANGELOG.md ($(wc -l < "$CHANGELOG" | tr -d ' ') lines)"
else
    warn "claude CLI not found — writing raw commit log as fallback."
    {
        echo "# Changelog"
        echo ""
        echo "## v${VERSION}"
        echo ""
        echo "$COMMIT_LOG" | sed 's/^/- /'
    } > "$CHANGELOG"
    ok "Written raw log to dist/CHANGELOG.md"
fi
echo ""

# ─── Step 7: Remove Old Tarballs ───────────────────────────────────

info "Removing old .tgz tarballs..."
TGZ_REMOVED=0
for f in "$DIST_DIR"/*.tgz; do
    [[ -e "$f" ]] || continue
    echo "    Removing $(basename "$f")"
    rm "$f"
    TGZ_REMOVED=$((TGZ_REMOVED + 1))
done
if [[ $TGZ_REMOVED -gt 0 ]]; then
    ok "Removed $TGZ_REMOVED old tarball(s)."
else
    ok "No old tarballs found."
fi
echo ""

# ─── Step 8: Summary ────────────────────────────────────────────────

DIST_SIZE=$(du -sh "$DIST_DIR" | cut -f1 | xargs)
info "dist/ total size: ${DIST_SIZE}"
echo ""

# ─── Step 9: npm pack ──────────────────────────────────────────────

info "Running npm pack..."
(cd "$DIST_DIR" && npm pack)
TARBALL="$DIST_DIR/korulang-koru-${VERSION}.tgz"
if [[ -f "$TARBALL" ]]; then
    TARBALL_SIZE=$(ls -lh "$TARBALL" | awk '{print $5}')
    ok "korulang-koru-${VERSION}.tgz (${TARBALL_SIZE})"
else
    die "npm pack did not produce a .tgz"
fi

# ─── Done ────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  ${GREEN}Release v${VERSION} built successfully.${NC}"
echo ""
echo "  To publish:"
echo "    cd dist && npm publish --access public"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
