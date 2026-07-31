#!/usr/bin/env python3
"""emit-for-not-while, decided mechanically.

Flags every `while (` inside EMITTED-Zig string content of the stdlib
transforms (see emitted_zig.py for what counts as emitted content). The
doctrine: a counted loop is a `for`; a `while` is legitimate only where
the trip count is not known up front. This check does not try to decide
countedness from a template fragment — it flags EVERY emitted `while`,
and the legitimately-unbounded ones carry a declared exemption (file +
condition fingerprint + reason) in emitted-while.allow, reviewed in git.
An exemption that no longer matches any site fails the check.

What it provably cannot see: a `while` in a runtime proc body's bare Zig
(ships verbatim, but indistinguishable from compile-time code without the
compiler's annotation context), and a `while` assembled from string
pieces none of which contains the token `while` itself.

Usage: check_emitted_while.py <corpus_dir> [allow_file]
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from emitted_zig import Span, extract_spans, matching_close, normalize, run_check

WHILE_TOKEN = "while"


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
        i = 0
        while True:
            i = text.find(WHILE_TOKEN, i)
            if i < 0:
                break
            before = text[i - 1] if i > 0 else "\n"
            j = i + len(WHILE_TOKEN)
            rest = text[j:].lstrip()
            # a word boundary on the DECODED text, and a following `(`
            if (not before.isalnum() and before not in "_@.") and rest.startswith("("):
                open_idx = text.index("(", j)
                close = matching_close(text, open_idx, "(", ")")
                cond = text[open_idx : close + 1] if close is not None else text[open_idx : open_idx + 80]
                sites.append(Site(span.file, span.line_of(i), normalize(f"while {cond}")))
            i = j
    return sites


def controls():
    """Patterns that MUST and MUST NOT match, run through the real
    extractor + scanner. Zero hits on a must-match means BROKEN."""
    fixture = "\n".join(
        [
            "~proc sweep|zig {",
            "    var j: usize = 0;",
            "    while (j < 3) : (j += 1) {} // transform's own loop: never flagged",
            '    const hdr = std.fmt.allocPrint(a, "{{\\nvar __i: usize = 0;\\nwhile (__i < __store_{s}.len) : (__i += 1) {{\\n", .{name}) catch unreachable;',
            "    const block =",
            "        \\\\var k: usize = 0;",
            "        \\\\while (k < cap) : (k += 1) {",
            "        \\\\}",
            "    ;",
            '    out.appendSlice("meanwhile (prose, not a loop header)...") catch unreachable;',
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
    # 1. the allocPrint format, `while` sitting after a \n escape — the
    #    store.kz:7140 shape a raw-text word boundary misses.
    if not any("__store_{s}.len" in fp for fp in fps):
        broken.append("must-match: while after \\n inside an allocPrint format was not flagged")
    # 2. the \\ multiline block form.
    if not any("k < cap" in fp for fp in fps):
        broken.append("must-match: while inside a \\\\ multiline block was not flagged")
    # 3. the transform's own while must NOT be flagged.
    if any("j < 3" in fp for fp in fps):
        broken.append("must-not-match: transform's own compile-time while was flagged")
    # 4. prose containing the letters 'while' without a loop header must NOT be flagged.
    if any("prose" in fp for fp in fps):
        broken.append("must-not-match: prose mention of while was flagged")
    if len(sites) != 2:
        broken.append(f"control fixture yielded {len(sites)} sites, expected exactly 2")
    return broken


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: check_emitted_while.py <corpus_dir> [allow_file]")
        sys.exit(2)
    corpus_dir = sys.argv[1]
    allow = sys.argv[2] if len(sys.argv) > 2 else None
    run_check("emitted-while", corpus_dir, allow, scan_spans, controls)
