#!/usr/bin/env python3
"""call-valued-index, decided mechanically.

The defect (concepts/frag-a-call-valued-index-copies-the-whole-array.md):
emitted Zig of the shape

    store.px[store.__koru_resolve(h)]

where the base is an aggregate held BY VALUE in a mutable global and the
index is a call that could mutate that global. Zig's forced evaluation
order materialises the whole aggregate before indexing — 80 KB copied
per access at store capacity 10,000, ~1750x on the measured sweep. Every
such site is CORRECT, so no test can see it; only a mechanical check can.

What this check actually catches — the honest heuristic subset: inside
EMITTED-Zig string content (see emitted_zig.py), an index or slice
bracket whose content contains a NON-BUILTIN call expression, where the
bracket's base is a named chain (identifiers, fields, format
placeholders). It cannot see types, so it cannot confine itself to
by-value aggregates — but hoisting the call into a const before indexing
is correct and at worst neutral for every base, so the over-approximation
is deliberate and the fix is uniform.

What it provably cannot see: a call spelled across separate string
fragments later concatenated around the bracket; calls hidden behind a
placeholder (`{s}` whose runtime value is itself a call expression —
the composed emit is invisible at template level); bare proc-body Zig;
and `@`-builtin calls, excluded on purpose (they cannot mutate a global,
so they force no copy).

Exemptions (call-valued-index.allow): `file | fingerprint | reason`,
fingerprint = normalized `base[index]`. A stale exemption fails the check.

Usage: check_call_valued_index.py <corpus_dir> [allow_file]
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from emitted_zig import extract_spans, matching_close, normalize, run_check

# A named chain right before `[`: identifiers / fields / format placeholders.
# `){` endings (indexing a call result) are a temporary, not this defect.
BASE_RE = re.compile(
    r"(?:\{[a-zA-Z_]*(?::[^{}]*)?\}|[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\.(?:\{[a-zA-Z_]*(?::[^{}]*)?\}|[A-Za-z_][A-Za-z0-9_]*))*$"
)

# A call inside the bracket: identifier followed by `(`, not preceded by `@`
# (builtins cannot mutate a global) and not a keyword that takes parens.
CALL_RE = re.compile(r"(?<![A-Za-z0-9_@])([A-Za-z_][A-Za-z0-9_]*)\s*\(")
KEYWORDS = {"if", "while", "for", "switch", "orelse", "catch", "and", "or", "return"}


class Site:
    __slots__ = ("file", "line", "fingerprint")

    def __init__(self, file, line, fingerprint):
        self.file = file
        self.line = line
        self.fingerprint = fingerprint


def scan_spans(spans):
    sites = []
    for span in spans:
        text = span.text
        for i, ch in enumerate(text):
            if ch != "[":
                continue
            base_m = BASE_RE.search(text, 0, i)
            if not base_m:
                continue
            close = matching_close(text, i, "[", "]")
            if close is None:
                continue
            inner = text[i + 1 : close]
            if not inner or inner == "_":
                continue
            calls = [m.group(1) for m in CALL_RE.finditer(inner) if m.group(1) not in KEYWORDS]
            if not calls:
                continue
            fp = normalize(f"{base_m.group(0)}[{inner}]")
            sites.append(Site(span.file, span.line_of(i), fp))
    return sites


def controls():
    """Must-match: the measured defect shape, template-spelled. Must-not:
    the hoisted fix, a builtin-call index, and the transform's own code."""
    fixture = "\n".join(
        [
            "~proc read|zig {",
            "    const own = table[resolveOwn(i)]; // transform's own code: never flagged",
            '    const bad = std.fmt.allocPrint(a, "__koru_store_{s}.parent[__koru_store_{s}.__koru_resolve(__koru_cyc)]", .{ n, n }) catch unreachable;',
            '    const good = std.fmt.allocPrint(a, "const __koru_r = __koru_store_{s}.__koru_resolve(h);\\n__koru_store_{s}.px[__koru_r]", .{ n, n }) catch unreachable;',
            '    out.appendSlice("buf[@intCast(__koru_i)] = 0;") catch unreachable;',
            "    const block =",
            "        \\\\const v = grid.cells[grid.lookup(key)];",
            "    ;",
            "}",
        ]
    )
    import tempfile, os

    fd, tmp = tempfile.mkstemp(suffix=".kz")
    os.write(fd, fixture.encode())
    os.close(fd)
    try:
        sites = scan_spans(extract_spans(tmp))
    finally:
        os.unlink(tmp)

    broken = []
    fps = [s.fingerprint for s in sites]
    if not any("__koru_resolve(__koru_cyc)" in fp for fp in fps):
        broken.append("must-match: the store resolve-in-index template shape was not flagged")
    if not any("grid.lookup(key)" in fp for fp in fps):
        broken.append("must-match: call-valued index inside a \\\\ multiline block was not flagged")
    if any("__koru_r]" in fp for fp in fps):
        broken.append("must-not-match: the hoisted-const fix shape was flagged")
    if any("@intCast" in fp or "buf[" in fp for fp in fps):
        broken.append("must-not-match: a builtin-call index was flagged")
    if any("resolveOwn" in fp for fp in fps):
        broken.append("must-not-match: transform's own indexed load was flagged")
    if len(sites) != 2:
        broken.append(f"control fixture yielded {len(sites)} sites, expected exactly 2")
    return broken


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: check_call_valued_index.py <corpus_dir> [allow_file]")
        sys.exit(2)
    corpus_dir = sys.argv[1]
    allow = sys.argv[2] if len(sys.argv) > 2 else None
    run_check("call-valued-index", corpus_dir, allow, scan_spans, controls)
