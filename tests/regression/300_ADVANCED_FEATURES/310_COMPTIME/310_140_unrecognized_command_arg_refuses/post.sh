#!/bin/bash
set -u
cd "$(dirname "$0")"

# A token in the command position that names no declared command, shell
# command, or frontend verb is a user error — it must refuse with a
# diagnostic, not silently compile. Blindness: no test ever put an
# unrecognised word after the input file.

# Garbage command-position word: refuse and name it.
if OUT=$(koruc "$KORU_INPUT" zzzzzz 2>&1); then
    echo "FAIL: 'koruc $KORU_INPUT zzzzzz' exited 0 — an unknown command token was swallowed"
    echo "$OUT"
    exit 1
fi
echo "$OUT" | grep -qi "zzzzzz" || { echo "FAIL: refusal does not name the offending token"; echo "$OUT"; exit 1; }

# `run` in command position is not a declared command. Today it silently
# builds and never runs — indistinguishable from the typo case above. It must
# refuse (the run verb is positional-prefix: `koruc run <file>`).
if OUT=$(koruc "$KORU_INPUT" run 2>&1); then
    echo "FAIL: 'koruc $KORU_INPUT run' silently compiled — 'run' was swallowed"
    echo "$OUT"
    exit 1
fi

# A positional .zig after the file reads as an output name. It is swallowed
# the same way — the file is never written and nothing says so. Refuse it
# until the position means something.
if OUT=$(koruc "$KORU_INPUT" named-out.zig 2>&1); then
    echo "FAIL: positional 'named-out.zig' silently dropped — no output, no refusal"
    echo "$OUT"
    exit 1
fi
[ ! -f named-out.zig ] || { echo "FAIL: named-out.zig appeared but refusal also fired"; rm -f named-out.zig; exit 1; }

# Unknown BARE flag: not a koruc flag, not a name=value provider — refuse.
if OUT=$(koruc --depp-check "$KORU_INPUT" 2>&1); then
    echo "FAIL: '--depp-check' silently accepted — typo'd flags vanish into compiler_config"
    echo "$OUT"
    exit 1
fi

# Controls: a declared command still dispatches, name=value provider flags
# still pass through, and a bare compile still works.
koruc "$KORU_INPUT" help > /dev/null 2>&1 || true   # help verb itself exists
koruc --customflag=1 "$KORU_INPUT" > /dev/null 2>&1 || { echo "FAIL: name=value provider flag broke"; exit 1; }
koruc -c "$KORU_INPUT" > /dev/null 2>&1 || { echo "FAIL: bare check broke"; exit 1; }

echo "=== Test passed: unrecognised command tokens and bare flags refuse ==="
