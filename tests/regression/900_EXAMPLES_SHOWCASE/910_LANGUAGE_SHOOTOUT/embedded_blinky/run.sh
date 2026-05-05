#!/usr/bin/env bash
# Embedded blinky shootout — cross-compile each implementation for
# thumbv7em-none-eabihf, run size measurements, write results.
#
# Skip-by-default semantics: if the toolchain isn't installed, we
# exit 0 with a clear notice. Regression suite still passes.

# Note: NO `set -e` here. We want one failed build not to kill the rest —
# the whole point of this shootout is producing a comparison table even
# when individual implementations don't build cleanly. Per-step `|| true`
# gates the resilience explicitly per build.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

STAMP="$(date -u +%Y-%m-%dT%H-%M-%S)"
RESULTS_JSON="$HERE/results.json"
RESULTS_MD="$HERE/results.md"

# ---------- toolchain probes ----------
have() { command -v "$1" >/dev/null 2>&1; }

MISSING=()
have arm-none-eabi-gcc  || MISSING+=("arm-none-eabi-gcc")
have arm-none-eabi-size || MISSING+=("arm-none-eabi-size")
have zig                || MISSING+=("zig")
have cargo              || MISSING+=("cargo")
have bloaty             || MISSING+=("bloaty")

if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "embedded_blinky: skipped (missing toolchain: ${MISSING[*]})"
    echo "install with: brew install arm-none-eabi-gcc zig bloaty && rustup target add thumbv7em-none-eabihf"
    cat > "$RESULTS_JSON" <<EOF
{
  "status": "skipped",
  "reason": "missing toolchain",
  "missing": $(printf '%s\n' "${MISSING[@]}" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'),
  "timestamp": "$STAMP"
}
EOF
    exit 0
fi

# Probe rustup target
if ! rustup target list --installed | grep -q '^thumbv7em-none-eabihf$'; then
    echo "embedded_blinky: skipped (rustup target thumbv7em-none-eabihf not installed)"
    echo "install with: rustup target add thumbv7em-none-eabihf"
    cat > "$RESULTS_JSON" <<EOF
{
  "status": "skipped",
  "reason": "missing rustup target thumbv7em-none-eabihf",
  "timestamp": "$STAMP"
}
EOF
    exit 0
fi

mkdir -p bin

# Track per-build status so we can report it later.
declare -A BUILD_STATUS

run_step() {
    local label="$1"; shift
    echo ">>> $label"
    if "$@"; then
        BUILD_STATUS["$label"]="ok"
    else
        BUILD_STATUS["$label"]="failed"
        echo "    (build failed — continuing)"
    fi
}

# ---------- build: C bare-metal ----------
run_step "c_bare" \
    arm-none-eabi-gcc \
        -mcpu=cortex-m4 -mthumb -mfloat-abi=hard -mfpu=fpv4-sp-d16 \
        -nostdlib -ffreestanding \
        -Os -fno-unwind-tables -fno-asynchronous-unwind-tables \
        -ffunction-sections -fdata-sections \
        -Wl,--gc-sections \
        -T reference/linker.ld \
        -o bin/blinky_c.elf reference/blinky.c

# ---------- build: Zig freestanding ----------
run_step "zig_freestanding" \
    zig build-exe reference/blinky.zig \
        -target thumb-freestanding-eabihf -mcpu=cortex_m4 \
        -O ReleaseSmall -fstrip -fno-unwind-tables \
        --script reference/linker.ld -fno-entry \
        -femit-bin=bin/blinky_zig.elf

# ---------- build: Rust naive embedded-hal ----------
echo ">>> rust_naive"
if ( cd reference/rust_naive && cargo build --release ) >/dev/null 2>&1; then
    cp reference/rust_naive/target/thumbv7em-none-eabihf/release/blinky_naive bin/blinky_rust_naive.elf
    BUILD_STATUS["rust_naive"]="ok"
else
    BUILD_STATUS["rust_naive"]="failed"
    echo "    (build failed — continuing)"
fi

# ---------- build: Rust Embassy ----------
echo ">>> rust_embassy"
if ( cd reference/rust_embassy && cargo build --release ) >/dev/null 2>&1; then
    cp reference/rust_embassy/target/thumbv7em-none-eabihf/release/blinky_embassy bin/blinky_rust_embassy.elf
    BUILD_STATUS["rust_embassy"]="ok"
else
    BUILD_STATUS["rust_embassy"]="failed"
    echo "    (build failed — continuing)"
fi

# ---------- build: Koru ----------
echo ">>> koru"
KORUC="$HERE/../../../../../zig-out/bin/koruc"
if [ ! -x "$KORUC" ]; then
    echo "    (koruc not built; run 'zig build' at repo root — skipping)"
    BUILD_STATUS["koru"]="skipped"
elif "$KORUC" --build=cortex_m4 -o "$HERE/bin/blinky_koru.elf" koru/blinky.kz >/dev/null 2>&1; then
    BUILD_STATUS["koru"]="ok"
else
    BUILD_STATUS["koru"]="failed"
    echo "    (build failed — continuing)"
fi

# ---------- measure ----------
measure_elf() {
    local label="$1"
    local elf="$2"
    if [ ! -f "$elf" ]; then
        echo "  $label: missing ($elf)"
        return
    fi
    # Detect format — only ARM ELFs go through arm-none-eabi-size; Mach-O
    # gets reported with a "native, not directly comparable" note because
    # Koru currently lacks CLI-level cross-compile target threading.
    local fmt
    fmt=$(file -b "$elf")
    case "$fmt" in
        ELF*ARM*)
            local size_out text data bss
            size_out=$(arm-none-eabi-size -B "$elf" 2>/dev/null | tail -1)
            read -r text data bss _ _ _ <<< "$size_out"
            echo "  $label: text=$text data=$data bss=$bss"
            ;;
        Mach-O*|ELF*)
            echo "  $label: native ($(stat -f%z "$elf" 2>/dev/null || stat -c%s "$elf") bytes on-disk; NOT cross-compiled, comparison not apples-to-apples)"
            ;;
        *)
            echo "  $label: unknown format: $fmt"
            ;;
    esac
}

echo ""
echo "=== sizes ==="
measure_elf "C bare        " bin/blinky_c.elf
measure_elf "Zig freestanding" bin/blinky_zig.elf
measure_elf "Rust naive    " bin/blinky_rust_naive.elf
measure_elf "Rust Embassy  " bin/blinky_rust_embassy.elf
measure_elf "Koru          " bin/blinky_koru.elf

# ---------- emit results.json ----------
emit_record() {
    local label="$1"
    local elf="$2"
    if [ ! -f "$elf" ]; then
        printf '    "%s": null' "$label"
        return
    fi
    local fmt
    fmt=$(file -b "$elf")
    case "$fmt" in
        ELF*ARM*)
            local size_out text data bss
            size_out=$(arm-none-eabi-size -B "$elf" 2>/dev/null | tail -1)
            read -r text data bss _ _ _ <<< "$size_out"
            printf '    "%s": { "format": "thumbv7em", "text": %s, "data": %s, "bss": %s }' "$label" "$text" "$data" "$bss"
            ;;
        Mach-O*|ELF*)
            local on_disk
            on_disk=$(stat -f%z "$elf" 2>/dev/null || stat -c%s "$elf")
            printf '    "%s": { "format": "native", "on_disk": %s, "note": "not cross-compiled — comparison not apples-to-apples" }' "$label" "$on_disk"
            ;;
        *)
            printf '    "%s": { "format": "unknown" }' "$label"
            ;;
    esac
}

{
    echo "{"
    echo '  "status": "ran",'
    echo '  "target": "thumbv7em-none-eabihf",'
    echo '  "mcu": "STM32F401RE",'
    echo "  \"timestamp\": \"$STAMP\","
    echo '  "sections": {'
    emit_record "c_bare"           bin/blinky_c.elf;            echo ","
    emit_record "zig_freestanding" bin/blinky_zig.elf;          echo ","
    emit_record "rust_naive"       bin/blinky_rust_naive.elf;   echo ","
    emit_record "rust_embassy"     bin/blinky_rust_embassy.elf; echo ","
    emit_record "koru"             bin/blinky_koru.elf;         echo ""
    echo "  }"
    echo "}"
} > "$RESULTS_JSON"

# ---------- render results.md ----------
{
    echo "# embedded_blinky results — $STAMP"
    echo ""
    echo "Target: \`thumbv7em-none-eabihf\` (STM32F401RE / Cortex-M4F)"
    echo ""
    echo "| Implementation        | format     | .text | .data | .bss | on-disk |"
    echo "|-----------------------|------------|------:|------:|-----:|--------:|"
    for pair in \
        "c_bare:bin/blinky_c.elf" \
        "zig_freestanding:bin/blinky_zig.elf" \
        "rust_naive:bin/blinky_rust_naive.elf" \
        "rust_embassy:bin/blinky_rust_embassy.elf" \
        "koru:bin/blinky_koru.elf"; do
        label="${pair%%:*}"
        elf="${pair##*:}"
        if [ ! -f "$elf" ]; then
            printf "| %-21s | %-10s | %5s | %5s | %4s | %7s |\n" "$label" "—" "—" "—" "—" "—"
            continue
        fi
        fmt=$(file -b "$elf")
        on_disk=$(stat -f%z "$elf" 2>/dev/null || stat -c%s "$elf")
        case "$fmt" in
            ELF*ARM*)
                size_out=$(arm-none-eabi-size -B "$elf" 2>/dev/null | tail -1)
                read -r text data bss _ _ _ <<< "$size_out"
                printf "| %-21s | %-10s | %5s | %5s | %4s | %7s |\n" "$label" "thumbv7em" "$text" "$data" "$bss" "$on_disk"
                ;;
            Mach-O*|ELF*)
                printf "| %-21s | %-10s | %5s | %5s | %4s | %7s |\n" "$label" "native"    "—"     "—"     "—"   "$on_disk"
                ;;
        esac
    done
    echo ""
    echo "**Notes:**"
    echo "- \`thumbv7em\` rows are the apples-to-apples cross-compiled comparison."
    echo "- \`native\` rows compiled to host architecture (no cross-compile threading"
    echo "  for that toolchain yet) — included for context, not for the headline."
} > "$RESULTS_MD"

echo ""
echo "wrote $RESULTS_JSON and $RESULTS_MD"
