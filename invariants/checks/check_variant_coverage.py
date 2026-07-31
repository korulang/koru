#!/usr/bin/env python3
"""every-emitted-variant-has-a-witness, decided mechanically.

The other two checks in this directory are static over emitter source —
they read what the emitter COULD write. This one is dynamic over emitted
artifacts — it reads what the corpus actually MADE the emitter write, and
fails when a piece of emittable surface appears in no test's output. A
variant no test ever produces is invisible surface: it ships, a green
board says nothing about it, and the first execution it ever gets is a
user's (__kz_wd, the raw_posix integer digit writer, was found exactly
this way — by hand, while editing it).

DERIVED, NOT WRITTEN. The variant set is not a hand list. A variant is
identified by its marker: a compiler-invented `__`-prefixed symbol
occurring in the EMITTED-Zig string content of the koru_std transforms
(same extraction as the sibling checks — see emitted_zig.py). Every
branch an emitter can take that writes distinguishable code writes at
least one such symbol; the symbol set is re-derived from source on every
run, so a new emitter shape enters the check the moment it is written.
Templated names keep their placeholders as wildcards (`__store_write_{}`
matches `__store_write_point`). A trailing-underscore fragment that is a
proper prefix of another derived marker is folded into the longer form:
those fragments are concatenation heads (`"const __KoruStoreT_"` ++ name)
or startsWith predicates, and their specific duals carry the coverage
question honestly.

THE COVERAGE SIDE reads each test's `output_emitted.zig` — the final
user program, the only artifact where koru_std emitter output
materialises as code. The inversion that keeps this honest: emitted text
lives INSIDE string literals of the emitter source, and materialises as
BARE code in the artifact — while emitter source embedded in an artifact
keeps its markers inside string literals. So the artifact scan strips
comments, quoted strings, char literals and \\\\ multiline lines, and
counts only bare tokens. A marker no artifact carries bare is UNCOVERED.

ARTIFACTS ARE EPHEMERAL — present only after a run, and a filtered run
leaves them in only the tests it ran. A naive scan of that state would
report the whole emitter uncovered: the a-check-that-cannot-match-
reports-clean failure mode. So the check refuses to judge unless at
least half of the test directories carry an artifact (a full board
measures ~65% — negative frontend tests produce none; a filtered run
measures ~1%). Below the bar it reports BROKEN and voids the verdict,
never clean. A file vanishing mid-scan (a live suite) is also BROKEN.

What it provably cannot see: a variant that emits only anonymous code
(no `__` symbol of its own — e.g. a bare posix.write fallback shares its
witness with every sibling using the same helper); the |js variant
(console.log, lands in output_emitted.js, no Zig artifact); emitter
templates in src/; and a marker that only ever materialises INSIDE a
string literal of the final program. Coverage is judged for THIS host's
board — a variant reachable only under another --build target reports
uncovered here, and that is the finding, not an error; rule it with an
exemption naming the host.

Exemptions in variant-coverage.allow (`file | symbol | reason`, reason
mandatory, a stale exemption FAILS).

Exit codes: 0 clean, 1 uncovered/stale-exemption, 2 cannot judge
(corpus/artifacts missing or too thin) — BROKEN, 3 self-test failure.

Usage: check_variant_coverage.py <stdlib_dir> <tests_dir> [allow_file]
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from emitted_zig import Allowlist, extract_spans

# A placeholder inside a derived symbol ({s}, {d}, {d:>3}...) becomes a
# sentinel char so the symbol tokenizer keeps it as one token.
PLACEHOLDER_RE = re.compile(r"\{[a-zA-Z_]*[0-9]*(?::[^{}]*)?\}")
SENTINEL = "\x00"
MARKER_RE = re.compile(r"(?<![A-Za-z0-9_\x00])__[A-Za-z0-9_\x00]*[A-Za-z0-9][A-Za-z0-9_\x00]*")
BARE_TOKEN_RE = re.compile(r"(?<![A-Za-z0-9_])__[A-Za-z0-9_]+")

# Judgment bar: fraction of test dirs that must carry an artifact before
# the verdict means anything. Measured 2026-07-31 on a full board:
# 986/1514 = 65% (MUST_ERROR frontend tests emit nothing); a filtered run
# leaves ~1%. 0.5 separates the regimes with a wide margin on both sides.
MIN_ARTIFACT_FRACTION = 0.5


def derive_markers(corpus_files):
    """symbol -> first `file:line` that can emit it, from emitted spans."""
    markers = {}
    for f in corpus_files:
        for span in extract_spans(f):
            text = PLACEHOLDER_RE.sub(SENTINEL, span.text)
            for m in MARKER_RE.finditer(text):
                name = m.group(0).replace(SENTINEL, "{}")
                markers.setdefault(name, f"{span.file}:{span.line_of(m.start())}")
    return fold_prefixes(markers)


def fold_prefixes(markers):
    """Drop a trailing-underscore fragment that is a proper prefix of
    another marker: concatenation heads and startsWith predicates whose
    templated dual carries the real coverage question."""
    names = sorted(markers)
    folded = {}
    for name in names:
        if name.endswith("_"):
            if any(other != name and other.startswith(name) for other in names):
                continue
        folded[name] = markers[name]
    return folded


def marker_pattern(name):
    """None for an exact symbol; a compiled fullmatch regex when the
    symbol carries placeholders or is an unfolded concatenation head."""
    if "{}" not in name and not name.endswith("_"):
        return None
    pat = re.escape(name).replace(r"\{\}", r"[A-Za-z0-9_]*")
    if name.endswith("_"):
        pat += r"[A-Za-z0-9_]*"
    return re.compile(pat + r"$")


def bare_tokens(path):
    """The `__`-prefixed identifiers in a Zig file's BARE code — after
    stripping comments, quoted strings, char literals, and \\\\ lines."""
    found = set()
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        if line.lstrip().startswith("\\\\"):
            continue
        i, n = 0, len(line)
        code = []
        while i < n:
            ch = line[i]
            if ch == "/" and i + 1 < n and line[i + 1] == "/":
                break
            if ch == '"' or ch == "'":
                quote = ch
                i += 1
                while i < n and line[i] != quote:
                    i += 2 if line[i] == "\\" else 1
                i += 1
                code.append(" ")
                continue
            code.append(ch)
            i += 1
        found.update(BARE_TOKEN_RE.findall("".join(code)))
    return found


def controls():
    """Fixtures through the REAL derivation and artifact scanners. Any
    miss means the check cannot speak: BROKEN, verdict void."""
    import os
    import tempfile

    broken = []

    emitter_fixture = "\n".join([
        "~proc fixture|zig {",
        "    const __kfix_bare = 1; // bare transform code: must NOT derive",
        "    // __kfix_comment: must NOT derive",
        '    const a = std.fmt.allocPrint(alloc, "const __kfix_probe = __kfix_t_{s};", .{name}) catch unreachable;',
        "    const b =",
        "        \\\\fn __kfix_ml() void {}",
        "    ;",
        '    pc.appendSlice(allocator, "const __kfix_t_") catch unreachable; // prefix folds into __kfix_t_{}',
        "}",
    ])
    fd, tmp = tempfile.mkstemp(suffix=".kz")
    os.write(fd, emitter_fixture.encode())
    os.close(fd)
    try:
        derived = derive_markers([tmp])
    finally:
        os.unlink(tmp)
    for want in ("__kfix_probe", "__kfix_t_{}", "__kfix_ml"):
        if want not in derived:
            broken.append(f"must-derive: {want} not derived from the emitter fixture")
    for reject in ("__kfix_bare", "__kfix_comment", "__kfix_t_"):
        if reject in derived:
            broken.append(f"must-not-derive: {reject} was derived ({'bare code' if reject != '__kfix_t_' else 'unfolded prefix'})")

    artifact_fixture = "\n".join([
        "// __kfix_chidden in a comment: must not count",
        'const s = "__kfix_hidden";  // inside a string literal: must not count',
        "const ml =",
        "    \\\\__kfix_mlhidden",
        ";",
        "pub fn main() void { __kfix_probe(); const x = __kfix_t_row; _ = x; }",
    ])
    fd, tmp = tempfile.mkstemp(suffix=".zig")
    os.write(fd, artifact_fixture.encode())
    os.close(fd)
    try:
        tokens = bare_tokens(tmp)
    finally:
        os.unlink(tmp)
    for want in ("__kfix_probe", "__kfix_t_row"):
        if want not in tokens:
            broken.append(f"must-count: bare {want} not seen in the artifact fixture")
    for reject in ("__kfix_hidden", "__kfix_chidden", "__kfix_mlhidden"):
        if reject in tokens:
            broken.append(f"must-not-count: {reject} counted from non-code content")

    # end to end: the templated marker must match its instantiated token,
    # and an unwitnessed marker must come out uncovered.
    pat = marker_pattern("__kfix_t_{}")
    if pat is None or not any(pat.match(t) for t in tokens):
        broken.append("must-match: __kfix_t_{} did not match bare __kfix_t_row")
    if "__kfix_probe" not in tokens or "__kfix_gone" in tokens:
        broken.append("control fixture tokens are not what the fixture wrote")
    return broken


def main():
    if len(sys.argv) < 3:
        print("usage: check_variant_coverage.py <stdlib_dir> <tests_dir> [allow_file]")
        sys.exit(2)
    stdlib_dir, tests_dir = Path(sys.argv[1]), Path(sys.argv[2])
    allow_path = sys.argv[3] if len(sys.argv) > 3 else None
    name = "variant-coverage"

    broken = controls()
    if broken:
        print(f"{name}: BROKEN — self-test failed, verdict void:")
        for b in broken:
            print(f"  {b}")
        sys.exit(3)

    corpus = sorted(stdlib_dir.glob("*.kz"))
    if not corpus:
        print(f"{name}: BROKEN — stdlib corpus {stdlib_dir} matched no .kz files")
        sys.exit(2)

    test_dirs = {p.parent for p in tests_dir.rglob("input.k")} | {
        p.parent for p in tests_dir.rglob("input.kz")
    }
    artifacts = sorted(tests_dir.rglob("output_emitted.zig"))
    if not test_dirs:
        print(f"{name}: BROKEN — {tests_dir} contains no test dirs (no input.k/input.kz)")
        sys.exit(2)
    fraction = len(artifacts) / len(test_dirs)
    if fraction < MIN_ARTIFACT_FRACTION:
        print(
            f"{name}: BROKEN — verdict void: only {len(artifacts)} of {len(test_dirs)} "
            f"test dirs carry output_emitted.zig ({fraction:.1%}, bar is "
            f"{MIN_ARTIFACT_FRACTION:.0%}). Artifacts are ephemeral and a filtered "
            f"run leaves only its own; judging coverage from a partial board would "
            f"report live surface as invisible. Run the full board first."
        )
        sys.exit(2)

    markers = derive_markers(corpus)

    seen = set()
    try:
        for a in artifacts:
            seen |= bare_tokens(a)
    except (OSError, UnicodeDecodeError) as e:
        print(f"{name}: BROKEN — artifact corpus unstable or unreadable mid-scan ({e}); is a suite live?")
        sys.exit(2)

    allow = Allowlist(allow_path)
    if allow.errors:
        for e in allow.errors:
            print(e)
        sys.exit(1)

    covered, exempted, uncovered = [], [], []
    for sym in sorted(markers):
        site = markers[sym]
        pat = marker_pattern(sym)
        hit = (sym in seen) if pat is None else any(pat.match(t) for t in seen)
        if hit:
            covered.append(sym)
            continue
        reason = allow.match(site.split(":")[0], sym)
        if reason is not None:
            exempted.append((sym, site, reason))
        else:
            uncovered.append((sym, site))

    stale = allow.stale()

    print(
        f"{name}: {len(corpus)} stdlib files, {len(markers)} emittable symbols derived, "
        f"{len(artifacts)}/{len(test_dirs)} test dirs carry artifacts "
        f"({len(seen)} distinct bare symbols seen), {len(covered)} covered, "
        f"{len(exempted)} exempted, {len(uncovered)} UNCOVERED"
    )
    for sym, site, reason in exempted:
        print(f"  exempt     {sym}  emitted at {site}  ({reason})")
    for sym, site in uncovered:
        print(f"  UNCOVERED  {sym}  emitted at {site} — no test's emitted output contains it")
    for s in stale:
        print(f"  STALE  {s}")

    sys.exit(1 if (uncovered or stale) else 0)


if __name__ == "__main__":
    main()
