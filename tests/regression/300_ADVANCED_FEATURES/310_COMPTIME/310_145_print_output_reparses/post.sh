#!/bin/bash
set -u
cd "$(dirname "$0")"

rm -rf work && mkdir work && cd work
cp "../$KORU_INPUT" prog.k

# .k → print → must re-parse as .k
if ! koruc --print prog.k > canon.k 2> print_k.err; then
    echo "FAIL: --print refused a .k input"; cat print_k.err; exit 1
fi
if ! koruc -c canon.k > check_k.out 2>&1; then
    echo "FAIL: --print output of a .k does not re-parse as .k"
    cat canon.k
    cat check_k.out
    exit 1
fi

# .kz → print → must re-parse as .kz
cat > prog.kz <<'KORU'
~import std/io

~std/io:print.ln("round-trip me")
KORU
if ! koruc --print prog.kz > canon.kz 2> print_kz.err; then
    echo "FAIL: --print refused a .kz input"; cat print_kz.err; exit 1
fi
if ! koruc -c canon.kz > check_kz.out 2>&1; then
    echo "FAIL: --print output of a .kz does not re-parse as .kz"
    cat canon.kz
    cat check_kz.out
    exit 1
fi

cd ..
rm -rf work
echo "=== Test passed: --print output re-parses in the source's own facet ==="
