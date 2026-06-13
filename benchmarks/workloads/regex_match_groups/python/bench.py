import re
import sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 3_000_000

# Named capture groups (Python spells them (?P<name>...)).
pat = re.compile(r"(?P<l>[0-9]+)x(?P<w>[0-9]+)x(?P<h>[0-9]+)")
inputs = ["2x3x4", "20x3x11", "hello world!"]

matched = none = total = 0
for i in range(n):
    s = inputs[i % 3]
    m = pat.fullmatch(s)
    if m:
        l = int(m.group("l"))
        w = int(m.group("w"))
        h = int(m.group("h"))
        total += l * w * h
        matched += 1
    else:
        none += 1

print(f"matched = {matched} none = {none} total = {total}")
