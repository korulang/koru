"""Extract EMITTED-Zig text from koru_std transforms.

A stdlib transform is a .kz file: Zig code whose string literals largely
exist to become emitted Zig (allocPrint formats, appendSlice literals,
\\ multiline blocks). Code OUTSIDE string literals is the transform's own
compile-time logic and is never emitted text.

This module yields the string-literal content of a .kz file, decoded the
way the emitted program will see it:

  - "..." literals: escape sequences decoded (\n, \t, \", \\, \').
    This matters: `...;\nwhile (...` places `while` after a NEWLINE in the
    emitted program, but after the letter `n` in the raw source — a raw
    word-boundary scan misses it (store.kz:7140 was exactly this site).
  - \\ multiline lines: raw, joined per consecutive block.
  - Format templates (either kind, detected by the presence of {{ }} or a
    {s}/{d}/{any}-style placeholder): {{ and }} decoded to single braces;
    placeholders are LEFT IN PLACE and treated as expression atoms by the
    pattern code in the checks.

Known, stated limits:
  - A runtime ~proc body's bare Zig also ships verbatim into emitted
    programs; this extractor cannot tell a runtime proc body from a
    comptime one without the compiler's annotation context, so bare code
    is uniformly treated as the transform's own. Checks over that surface
    are decided by inference at review time.
  - Prose strings (diagnostics, JSON declarations) are scanned like any
    other string content; the checks' patterns require Zig syntax
    (`while (`, `base[call()]`), which prose does not produce.
"""

import re
import sys
from pathlib import Path

PLACEHOLDER_RE = re.compile(r"\{[a-zA-Z_]*[0-9]*(?::[^{}]*)?\}")
FORMAT_HINT_RE = re.compile(r"\{\{|\}\}|\{[a-zA-Z_]*(?::[^{}]*)?\}")


class Span:
    """One piece of string-literal content, mapped back to file:line.

    multiline is True for a \\ block, where an embedded newline advances
    the physical line; a quoted literal lives on one physical line no
    matter how many \n escapes it carries.
    """

    __slots__ = ("file", "line", "text", "multiline")

    def __init__(self, file, line, text, multiline=False):
        self.file = file
        self.line = line
        self.text = text
        self.multiline = multiline

    def line_of(self, offset):
        if self.multiline:
            return self.line + self.text.count("\n", 0, offset)
        return self.line


def _decode_quoted(raw):
    out = []
    i = 0
    while i < len(raw):
        ch = raw[i]
        if ch == "\\" and i + 1 < len(raw):
            esc = raw[i + 1]
            out.append({"n": "\n", "t": "\t", "r": "\r"}.get(esc, esc))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _decode_format_braces(text):
    # {{ and }} are literal braces in a Zig format template. Placeholders
    # ({s}, {d}, {any}, {d:>3}, ...) are left as atoms.
    if FORMAT_HINT_RE.search(text):
        return text.replace("{{", "{").replace("}}", "}")
    return text


def extract_spans(path):
    """Yield Span objects for every string-literal region in a .kz file."""
    spans = []
    lines = Path(path).read_text(encoding="utf-8").splitlines()
    fname = Path(path).name

    multiline_buf = []   # (line_no, content) of a running \\ block
    def flush_multiline():
        if multiline_buf:
            joined = "\n".join(c for (_, c) in multiline_buf)
            spans.append(Span(fname, multiline_buf[0][0], _decode_format_braces(joined), multiline=True))
            multiline_buf.clear()

    for lineno, line in enumerate(lines, start=1):
        stripped = line.lstrip()
        if stripped.startswith("\\\\"):
            multiline_buf.append((lineno, stripped[2:]))
            continue
        flush_multiline()

        i = 0
        n = len(line)
        while i < n:
            ch = line[i]
            if ch == "/" and i + 1 < n and line[i + 1] == "/":
                break  # comment to end of line
            if ch == "'":
                # char literal: skip, handling '\'' and '\\'
                j = i + 1
                while j < n:
                    if line[j] == "\\":
                        j += 2
                        continue
                    if line[j] == "'":
                        break
                    j += 1
                i = j + 1
                continue
            if ch == '"':
                j = i + 1
                start = j
                while j < n:
                    if line[j] == "\\":
                        j += 2
                        continue
                    if line[j] == '"':
                        break
                    j += 1
                raw = line[start:j]
                spans.append(Span(fname, lineno, _decode_format_braces(_decode_quoted(raw))))
                i = j + 1
                continue
            i += 1

    flush_multiline()
    return spans


def matching_close(text, open_idx, open_ch, close_ch):
    """Index of the close matching text[open_idx]; None if unbalanced.

    Skips over quoted segments so a bracket inside an emitted string
    literal does not miscount.
    """
    depth = 0
    i = open_idx
    n = len(text)
    while i < n:
        ch = text[i]
        if ch == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == "\\" else 1
            i += 1
            continue
        if ch == open_ch:
            depth += 1
        elif ch == close_ch:
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def normalize(s):
    return re.sub(r"\s+", " ", s).strip()


class Allowlist:
    """Declared exemptions: `file | fingerprint | reason` lines, tracked in
    git. An exemption is invalid without a reason; an exemption that
    matches no site is stale and FAILS the check — never silence."""

    def __init__(self, path):
        self.entries = []  # (file, fingerprint, reason, lineno)
        self.errors = []
        self.hits = []
        self.path = path
        if path is None or not Path(path).exists():
            return
        for lineno, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|", 2)]
            if len(parts) != 3 or not all(parts):
                self.errors.append(f"{path}:{lineno}: malformed exemption (want `file | fingerprint | reason`): {line}")
                continue
            self.entries.append((parts[0], parts[1], parts[2], lineno))
        self.hits = [0] * len(self.entries)

    def match(self, file, fingerprint):
        for idx, (f, fp, reason, _) in enumerate(self.entries):
            if f == file and normalize(fp) == normalize(fingerprint):
                self.hits[idx] += 1
                return reason
        return None

    def stale(self):
        return [
            f"{self.path}:{ln}: stale exemption matches no site: {f} | {fp}"
            for (f, fp, _, ln), h in zip(self.entries, self.hits)
            if h == 0
        ]


def run_check(name, corpus_dir, allow_path, scan_spans_fn, controls_fn):
    """Shared driver: controls first, then the corpus, then verdict.

    Exit codes: 0 clean, 1 violations/stale exemptions, 2 corpus missing
    or unreadable, 3 self-test (control) failure. A check that cannot
    prove it can match reports BROKEN, never clean.
    """
    broken = controls_fn()
    if broken:
        print(f"{name}: BROKEN — self-test failed, verdict void:")
        for b in broken:
            print(f"  {b}")
        sys.exit(3)

    corpus = sorted(Path(corpus_dir).glob("*.kz"))
    if not corpus:
        print(f"{name}: BROKEN — corpus {corpus_dir} matched no .kz files")
        sys.exit(2)

    allow = Allowlist(allow_path)
    if allow.errors:
        for e in allow.errors:
            print(e)
        sys.exit(1)

    violations = []
    exempted = []
    total_spans = 0
    total_sites = 0
    for f in corpus:
        spans = extract_spans(f)
        total_spans += len(spans)
        for site in scan_spans_fn(spans):
            total_sites += 1
            reason = allow.match(site.file, site.fingerprint)
            if reason is not None:
                exempted.append((site, reason))
            else:
                violations.append(site)

    stale = allow.stale()

    print(
        f"{name}: {len(corpus)} files, {total_spans} emitted-string spans, "
        f"{total_sites} sites matched, {len(exempted)} exempted, {len(violations)} violations"
    )
    for site, reason in exempted:
        print(f"  exempt  {site.file}:{site.line}  {site.fingerprint}  ({reason})")
    for site in violations:
        print(f"  VIOLATION  {site.file}:{site.line}  {site.fingerprint}")
    for s in stale:
        print(f"  STALE  {s}")

    sys.exit(1 if (violations or stale) else 0)
