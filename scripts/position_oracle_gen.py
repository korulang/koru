#!/usr/bin/env python3
"""Position-agnosticism oracle: eligibility filter + mechanical twin generator.

Used by scripts/position-oracle.sh. Two modes:

  check <test_dir>        -> prints "OK" or "SKIP:<reason>" (always exit 0)
  rewrite <input.kz>      -> prints the transplanted twin source to stdout

The transplant is the canonical scaffold from the passing test
tests/regression/200_COMPILER_FEATURES/210_PARSER/210_045_source_block_in_pipeline:
a void event + |zig proc + `~setup() |> <invocation>`, with the original
flow's continuation lines indented one level (4 spaces, the shape shown in
passing tests 210_023 / the 620_002 hand-built twin). The ONLY synthesized
characters are the scaffold (renamed to a collision-proof kebab name) and
the indentation — everything else is the original's verbatim text.

CONSERVATIVE BY DESIGN: when in doubt, SKIP with a reason. An honest narrow
oracle beats a broad lying one.
"""

import os
import re
import sys

SCAFFOLD_NAME = "position-oracle-setup"

# Markers that make a test ineligible (negative tests, non-running tests,
# tests with their own validation machinery, dual-target tests whose JS leg
# would lack a |zig-only scaffold proc).
EXCLUDING_MARKERS = (
    "MUST_ERROR", "TODO", "SKIP", "BROKEN", "BENCHMARK",
    "PARSER_TEST", "EXPECT", "post.sh", "LANGUAGES",
)
EXCLUDING_CATEGORY_MARKERS = ("SKIP", "TODO", "BENCHMARK")

CALL_RE = re.compile(r"~[A-Za-z][\w./:-]*\(.*\)")
DECL_PREFIXES = ("~event", "~proc", "~import", "~test")
CONTINUATION_RE = re.compile(r"\s*(//|\||!)")


def find_final_invocation(lines):
    """Return (index, reason). index is the last column-0 `~` line if it is a
    transplantable invocation, else None with a skip reason."""
    last = None
    for i, line in enumerate(lines):
        if line.startswith("~"):
            last = i
    if last is None:
        return None, "no-top-level-tilde-line"
    line = lines[last].rstrip()
    for kw in DECL_PREFIXES:
        if re.match(re.escape(kw) + r"\b", line):
            return None, "final-tilde-line-is-declaration (%s)" % kw
    if "=" in line:
        return None, "final-line-contains-equals (subflow/assignment)"
    if "{" in line or "}" in line:
        return None, "final-line-contains-brace (source-block invocation)"
    if "|" in line:
        return None, "final-line-contains-pipe (already-chained invocation)"
    if not CALL_RE.fullmatch(line):
        return None, "final-line-not-a-call"
    return last, None


def check(test_dir):
    for m in EXCLUDING_MARKERS:
        if os.path.exists(os.path.join(test_dir, m)):
            return "marker-%s" % m
    category = os.path.dirname(test_dir)
    for m in EXCLUDING_CATEGORY_MARKERS:
        if os.path.exists(os.path.join(category, m)):
            return "category-marker-%s" % m
    path = os.path.join(test_dir, "input.kz")
    if not os.path.exists(path):
        return "no-input.kz (pure-.k entry or missing)"
    with open(path) as f:
        src = f.read()
    if SCAFFOLD_NAME in src:
        return "scaffold-name-collision"
    lines = src.split("\n")
    for line in lines:
        if re.match(r"~import\s+\.\.", line):
            return "parent-relative-import"
    idx, reason = find_final_invocation(lines)
    if idx is None:
        return reason
    for line in lines[idx + 1:]:
        if line.strip() == "":
            continue
        if not CONTINUATION_RE.match(line):
            return "trailing-non-continuation-line"
        if line.count("{") != line.count("}"):
            return "unbalanced-brace-in-continuation (multi-line block)"
    return None


def rewrite(path):
    with open(path) as f:
        src = f.read()
    lines = src.split("\n")
    idx, reason = find_final_invocation(lines)
    assert idx is not None, (
        "rewrite called on ineligible input (%s) — filter and generator "
        "disagree, investigate the oracle" % reason
    )
    out = list(lines[:idx])
    # Exactly one blank line between the preceding text and the scaffold.
    while out and out[-1].strip() == "":
        out.pop()
    if out:
        out.append("")
    out.extend([
        "~event %s {}" % SCAFFOLD_NAME,
        "",
        "~proc %s|zig {" % SCAFFOLD_NAME,
        "}",
        "",
        # The original `~X(args...)` becomes a nested continuation invocation:
        # the top-level form minus the `~`, placed after `|>` (210_045 shape).
        "~%s() |> %s" % (SCAFFOLD_NAME, lines[idx].rstrip()[1:]),
    ])
    for line in lines[idx + 1:]:
        if line.strip() == "":
            out.append(line)
        else:
            out.append("    " + line)
    # Preserve a single trailing newline.
    while out and out[-1].strip() == "":
        out.pop()
    return "\n".join(out) + "\n"


def main():
    assert len(sys.argv) == 3, "usage: position_oracle_gen.py check|rewrite <path>"
    mode, path = sys.argv[1], sys.argv[2]
    if mode == "check":
        reason = check(path)
        print("OK" if reason is None else "SKIP:%s" % reason)
    elif mode == "rewrite":
        sys.stdout.write(rewrite(path))
    else:
        raise AssertionError("unknown mode: %s" % mode)


if __name__ == "__main__":
    main()
