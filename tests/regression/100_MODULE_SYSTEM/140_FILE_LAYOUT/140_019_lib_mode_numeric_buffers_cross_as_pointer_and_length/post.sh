#!/bin/bash
# Check the C boundary AT the boundary: build this same file as a library,
# link hand-written C against it, and compare the samples. Reading the emitted
# Zig would only prove the emitter wrote what the emitter meant to write.
set -e
cd "$(dirname "$0")"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp input.kz host.c "$work"/
cd "$work"

koruc lib input.kz > lib.out 2>&1 || { echo "FAIL: koruc lib did not build"; cat lib.out; exit 1; }

# Both buffers must arrive as a pointer AND a length, and the OUTPUT one must
# be mutable — that is the half an audio plugin writes back through.
sig=$(grep -m1 '^export fn apply_gain' output_emitted.zig || true)
if [ -z "$sig" ]; then
    echo "FAIL: apply_gain was not exported at all"
    grep -A4 'C ABI exports' output_emitted.zig || true
    exit 1
fi
case "$sig" in
    *"input_ptr: [*]const f32, input_len: usize"*) ;;
    *) echo "FAIL: the const buffer did not cross as pointer+length"; echo "  $sig"; exit 1 ;;
esac
case "$sig" in
    *"output_ptr: [*]f32, output_len: usize"*) ;;
    *) echo "FAIL: the mutable buffer did not cross as a writable pointer+length"; echo "  $sig"; exit 1 ;;
esac

zig build-lib output_emitted.zig -dynamic -lc -O ReleaseFast --name korugain > build.out 2>&1 || {
    echo "FAIL: the emitted library did not build"; tail -20 build.out; exit 1; }

cc host.c -L. -lkorugain -Wl,-rpath,. -o host 2> link.err || {
    echo "FAIL: hand-written C did not link against the Koru library"; cat link.err; exit 1; }

./host
