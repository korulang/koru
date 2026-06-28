#!/usr/bin/env bash
# escape_local_probe.sh — MEASUREMENT PROBE for the "escape-driven local/stack
# allocation" angle on the faithful prime-sieve drag-race entry.
#
# WHAT THIS IS / IS NOT
#   This is a *probe*, not a toolchain artifact. It hand-edits the Stage-D Zig
#   (output_emitted.zig) that koruc emits, to allocate the sieve Field on the
#   STACK (fresh, @memset-zeroed each pass) instead of through the safety-GPA.
#   It exists to QUANTIFY the ceiling of the escape-local optimization before
#   the deep compiler work is built. The number it prints is MEASURED-narrow:
#   it does NOT come from `koruc faithful.k` alone, so it must NEVER be reported
#   as a SHOWN toolchain result.
#
# FAITHFULNESS
#   The probe stays faithful=yes in spirit: the buffer is re-created (a fresh
#   stack slot, @memset to zero) every pass. It is NOT the reuse variant — it
#   does not carry one populated buffer across passes. The only thing changed
#   vs. the real entry is the ALLOCATOR (stack instead of GPA), which the
#   mission brief explicitly blesses ("a faster allocator underneath is FINE").
#
# RESULT (SHOWN on arm64 macOS, this worktree, concurrent-agent noise present):
#   baseline faithful (GPA new/free per pass): ~60-65k passes/sec
#   probe    faithful (stack alloc per pass) : ~71-77k passes/sec  (reuse ceiling)
#   Both validate 78498 primes.
#
# WHAT THE REAL TOOLCHAIN CHANGE REQUIRES (not landed here — too large to land
# clean + regression-safe in one session):
#   1. phantom_semantic_checker: export a "this <field!> obligation is
#      new->free within one flow scope and never escapes" signal. The escape
#      substrate already exists (documented_escape / escape-through-signature).
#   2. emitter: an event-type-specific lowering that, on that signal AND a
#      comptime-bounded `bits`, emits `var buf:[N]u64; @memset(...0); Field{...}`
#      in place of `new_event.handler(...)` and turns the paired `free` into a
#      no-op. Per no-silent-perf-degradation: stack only when non-escape AND
#      size comptime-bounded; else heap; ambiguity = error. Architecturally this
#      belongs in the std/field "claims_descendants island" (castles vision),
#      not a bespoke emitter special-case.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
KORUC="$ROOT/zig-out/bin/koruc"
SCRATCH="${1:-/tmp/koru_escape_local_probe}"
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
cp "$HERE/faithful.k" "$SCRATCH/faithful.k"
cd "$SCRATCH"
"$KORUC" faithful.k >/dev/null
echo "===== BASELINE (faithful, GPA new/free per pass) ====="
./a.out

cp output_emitted.zig output_probe.zig
# Stack-allocate the field in run_event: fresh [7813]u64 = (500000+63)/64,
# @memset to zero each pass; replace new_event.handler with a stack Field; make
# the paired free a no-op (stack scope exit).
python3 - "$SCRATCH/output_probe.zig" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
s=s.replace(
"""                const result_1 = koru_std.koru_field.new_event.handler(.{ .bits = 500000 });
                _ = &result_1;
                switch (result_1) {
                    // >>> BRANCH: faithful.k:25  | err _auto_6 |>
                    .err => |_| {
                    },
                    // >>> BRANCH: faithful.k:21  | field f |>
                    .field => |f| {""",
"""                var __probe_field_buf: [7813]u64 = undefined;
                @memset(&__probe_field_buf, 0);
                var __probe_field: koru_std.koru_field.Field = .{ .data = __probe_field_buf[0..], .bits = 500000, .allocator = undefined };
                const result_1 = koru_std.koru_field.new_event.Output{ .field = &__probe_field };
                _ = &result_1;
                switch (result_1) {
                    .err => |_| {
                    },
                    .field => |f| {""",1)
s=s.replace(
"""    {                         const result_c1_0 = koru_std.koru_field.free_event.handler(.{ .f = f });
                        _ = &result_c1_0;
                        L_deadline = l.deadline;""",
"""    {                         _ = &f;
                        L_deadline = l.deadline;""",1)
open(p,'w').write(s)
PY
zig build-exe output_probe.zig -OReleaseFast -femit-bin=probe.out >/dev/null 2>&1
echo "===== PROBE (stack alloc fresh+memset per pass — MEASURED-narrow, NOT a toolchain number) ====="
./probe.out
