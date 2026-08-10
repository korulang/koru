#!/bin/bash
# The program must DIE at the unfilled event, naming it. It must never print a
# value it invented. Passing here means an empty box is loud, not silent.
cd "$(dirname "$0")"

bin=""
for candidate in ./output ./a.out; do
    [ -x "$candidate" ] && bin="$candidate" && break
done
if [ -z "$bin" ]; then
    echo "FAIL: no executable was produced"
    exit 1
fi

out=$("$bin" 2>&1)
rc=$?

if printf '%s' "$out" | grep -q 'value = '; then
    echo "FAIL: the unfilled event 'fetch' fabricated an answer instead of dying"
    echo "  program printed: $out"
    exit 1
fi

if [ $rc -eq 0 ]; then
    echo "FAIL: reaching an unfilled event exited 0"
    echo "  program printed: $out"
    exit 1
fi

if ! printf '%s' "$out" | grep -q 'fetch'; then
    echo "FAIL: the program died but did not name the event it died on"
    echo "  program printed: $out"
    exit 1
fi

echo "PASS: reaching unfilled event 'fetch' died loudly and named itself"
exit 0
