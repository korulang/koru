#!/usr/bin/env python3
"""check_flowkernel_mirror — the flow kernel's mirror must not drift.

verify/semantics/FlowKernel.lean is the single source; isar-proofs
src/ISAR/FlowDialect.lean is its faithful re-typed port. Vendored by
hash: this check fails the moment the source's LF-normalized sha256
leaves the pin, so an edit cannot land without the mirror port and a
re-pin in the same commit.

Usage:
  check_flowkernel_mirror.py <pin_file> <source_file>
(cwd is invariants/, so repo paths start with `..`)
"""

import hashlib
import re
import sys


def main():
    pin_path, src_path = sys.argv[1], sys.argv[2]

    pinned = None
    with open(pin_path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^sha256=([0-9a-f]{64})\s*$", line)
            if m:
                pinned = m.group(1)
    if pinned is None:
        print(f"BROKEN flowkernel-mirror: {pin_path} needs a sha256=<hex> line")
        return 2

    try:
        with open(src_path, "rb") as f:
            raw = f.read()
    except OSError:
        print(f"BROKEN flowkernel-mirror: cannot read {src_path}")
        return 2

    actual = hashlib.sha256(raw.replace(b"\r\n", b"\n")).hexdigest()
    if actual == pinned:
        print(f"flowkernel-mirror: source at pin — sha256={actual[:16]}…")
        return 0

    print(f"flowkernel-mirror DRIFTED: source sha256 {actual[:16]}… "
          f"!= pin {pinned[:16]}…")
    print("  The mirror is isar-proofs/src/ISAR/FlowDialect.lean —")
    print("  port the delta there, then re-pin:")
    print(f"  sha256sum <(tr -d '\\r' < {src_path[3:]})")
    print("  and update checks/flowkernel_mirror.pin in this commit.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
