#!/usr/bin/env bash
# std_compiles.sh — the koru_std rot lint.
#
# Compiles a minimal probe program importing each koru_std module through the
# FULL koruc pipeline (`koruc build`, stages A-D, no execution). The class of
# failure this surfaces: a stdlib module that no green test compiles
# end-to-end rots silently through language migrations. The instance that
# earned it: std/profiler survived the kebab-case migration half-migrated
# (KORU034 on write_event/write_footer) because its only end-to-end tests are
# BENCHMARK-parked and the 310 conditional-import tests are parser-only.
#
# The full pipeline is the oracle. `koruc --check` was considered and ruled
# out — it stops after stage-A parse + syntactic flow checks (main.zig:7375)
# and certifies nothing about the backend passes where most semantic checking
# lives.
#
# Exit status: 0 always (a report, not a gate). The failing count should
# trend to zero; flip to a gate once it does.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
KORUC="$SCRIPT_DIR/zig-out/bin/koruc"
JOBS="${STD_COMPILES_JOBS:-8}"

if [ ! -x "$KORUC" ]; then
    echo "ERROR: $KORUC not found — build the compiler first (zig build)"
    exit 1
fi

# --- enumerate importable module stems ------------------------------------
# A module = a .kz or .k file directly in koru_std/. The import path is the
# filename stem verbatim (std/string-map -> string-map.kz,
# std/liquid_template -> liquid_template.kz). .kjs is the JS-target facet and
# is not probed here (different backend). Host-side .zig files are not
# importable modules.
modules() {
    for f in koru_std/*.kz koru_std/*.k; do
        [ -e "$f" ] || continue
        basename "$f" | sed 's/\.kz$//; s/\.k$//'
    done | sort -u
}

# --- classified skips ------------------------------------------------------
# Modules where "compiles under a standalone import probe" is the wrong
# question. Each carries a one-line rationale, printed in the report so the
# classification stays visible and contestable.
skip_rationale() {
    case "$1" in
        ccp_aspirational)  echo "aspirational by name — a design sketch, not a shipping module" ;;
        build_defaults)    echo "imported by build.kz (its own header) — every compile loads it; a direct import double-registers the default steps (MultipleDefaults)" ;;
        compiler_context)  echo "metacircular pipeline internal — compiled by every koruc invocation (stage B); standalone import is not a supported surface" ;;
        compiler_types)    echo "metacircular pipeline internal — compiled by every koruc invocation (stage B); standalone import is not a supported surface" ;;
        compiler_visitor)  echo "metacircular pipeline internal — compiled by every koruc invocation (stage B); standalone import is not a supported surface" ;;
        *) return 1 ;;
    esac
}

# --- probe one module ------------------------------------------------------
# Probe shape grounded in green tests: 310_059 (const std + ~import +
# event/proc|zig + std.debug.print) and 507_meta_event_taps (top-level
# invocation). .kz facet so host-heavy modules are fair game.
RESULTS_DIR="$(mktemp -d /tmp/std_compiles.XXXXXX)"

probe_one() {
    local mod="$1"
    local work
    work="$(mktemp -d "$RESULTS_DIR/$mod.XXXXXX")"
    cat > "$work/probe.kz" <<EOF
const std = @import("std");
~import std/$mod

~event probe {}

~proc probe|zig {
    std.debug.print("ok\n", .{});
}

~probe()
EOF
    if (cd "$work" && "$KORUC" build probe.kz > compile.log 2>&1); then
        echo "PASS" > "$work/verdict"
    else
        echo "FAIL" > "$work/verdict"
    fi
    echo "$work" >> "$RESULTS_DIR/dirs.$mod"
}
export -f probe_one
export KORUC RESULTS_DIR

echo "std-compiles — koru_std full-pipeline rot lint"
echo "  compiler: $KORUC"
ALL_MODS="$(modules)"
MODS=""
SKIPPED=0
for mod in $ALL_MODS; do
    if r="$(skip_rationale "$mod")"; then
        echo "  ⏭  std/$mod — $r"
        SKIPPED=$((SKIPPED + 1))
    else
        MODS="$MODS$mod"$'\n'
    fi
done
MODS="$(printf '%s' "$MODS")"
COUNT="$(echo "$MODS" | wc -l | tr -d ' ')"
echo "  probing $COUNT modules ($SKIPPED classified skips), $JOBS at a time..."
echo

echo "$MODS" | xargs -P "$JOBS" -I {} bash -c 'probe_one "$@"' _ {}

# --- report ----------------------------------------------------------------
PASS=0
FAIL=0
FAILED_MODS=()
for mod in $MODS; do
    work="$(head -1 "$RESULTS_DIR/dirs.$mod" 2>/dev/null)"
    if [ -z "$work" ] || [ ! -f "$work/verdict" ]; then
        FAIL=$((FAIL + 1)); FAILED_MODS+=("$mod"); continue
    fi
    if [ "$(cat "$work/verdict")" = "PASS" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); FAILED_MODS+=("$mod")
    fi
done

for mod in "${FAILED_MODS[@]+"${FAILED_MODS[@]}"}"; do
    work="$(head -1 "$RESULTS_DIR/dirs.$mod")"
    echo "❌ std/$mod"
    # First koru-level diagnostic, or the tail if none matched.
    if grep -m 3 -E "^error\[" "$work/compile.log" 2>/dev/null | sed 's/^/     /'; then
        :
    else
        tail -3 "$work/compile.log" 2>/dev/null | sed 's/^/     /'
    fi
done
[ "$FAIL" -gt 0 ] && echo

echo "════════════════════════════════════════"
echo "std-compiles: $PASS/$COUNT modules compile, $FAIL failing ($SKIPPED classified skips)"
echo "════════════════════════════════════════"

rm -rf "$RESULTS_DIR"
exit 0
