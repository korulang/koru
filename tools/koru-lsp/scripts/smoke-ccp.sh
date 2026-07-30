#!/usr/bin/env bash
# Smoke-test koruc --ccp with disk + in-memory buffer commands.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
KORUC="${KORUC:-$ROOT/zig-out/bin/koruc}"
TEST_FILE="tests/regression/300_ADVANCED_FEATURES/310_COMPTIME/310_110_glance_command/input.k"

cd "$ROOT"
if [[ ! -x "$KORUC" ]]; then
  echo "koruc not found at $KORUC — run zig build first" >&2
  exit 1
fi

echo "=== CCP smoke (disk parse + glance) ==="
printf '{"cmd":"parse","id":1,"file":"%s"}\n{"cmd":"glance","id":2,"file":"%s"}\n{"cmd":"exit","id":3}\n' \
  "$TEST_FILE" "$TEST_FILE" \
  | "$KORUC" --ccp

echo ""
echo "=== CCP smoke (open buffer + parse) ==="
SOURCE="$(cat "$TEST_FILE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
printf '{"cmd":"open","id":10,"file":"%s","text":%s,"version":1}\n{"cmd":"parse","id":11,"file":"%s"}\n{"cmd":"close","id":12,"file":"%s"}\n{"cmd":"exit","id":13}\n' \
  "$TEST_FILE" "$SOURCE" "$TEST_FILE" "$TEST_FILE" \
  | "$KORUC" --ccp

echo ""
echo "=== CCP smoke (diagnostics on parse error) ==="
BAD="tests/regression/200_COMPILER_FEATURES/210_PARSER/210_120_reject_square_bracket_phantom/input.kz"
printf '{"cmd":"diagnostics","id":20,"file":"%s"}\n{"cmd":"exit","id":21}\n' "$BAD" \
  | "$KORUC" --ccp \
  | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if msg.get("type") == "diagnostics":
        items = msg.get("items") or []
        if not items:
            sys.exit("expected at least one diagnostic")
        code = items[0].get("code")
        if code != "KORU033":
            sys.exit("expected KORU033, got " + repr(code))
        print("  " + code + ": " + items[0]["message"])
    else:
        print(line)
'

echo ""
echo "=== CCP smoke (completion: module + event) ==="
TEST="tests/regression/300_ADVANCED_FEATURES/310_COMPTIME/310_110_glance_command/input.k"
SOURCE="$(cat "$TEST" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
printf '{"cmd":"open","id":30,"file":"%s","text":%s,"version":1}\n{"cmd":"completion","id":31,"file":"%s","line":11,"column":27}\n{"cmd":"exit","id":32}\n' \
  "$TEST" "$SOURCE" "$TEST" \
  | "$KORUC" --ccp \
  | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    if msg.get("type") == "completion":
        labels = [i["label"] for i in msg.get("items") or []]
        if not any("std/store:stored" == l for l in labels):
            sys.exit("expected std/store:stored in completion items, got: " + repr(labels[:5]))
        print("  completion:", ", ".join(labels[:3]))
    elif msg.get("type") != "ready":
        print(line)
'

echo ""
echo "OK"
