#!/usr/bin/env python3
"""kz-extension-is-earned, decided by the parser.

`.k` is the default spelling for a pure-Koru program; `.kz` is the host
facet — for files that need bare Zig, host type decls, or `~proc` bodies.
A `.kz` that carries ZERO host content is a `.k` wearing the wrong
extension. That question is decidable, so it goes to no judge: `koruc
--check-k-convertible` answers it from the top-level AST (any non-comment
host_line, host_type_decl, or proc_decl → the facet is earned).

The check is diff-scoped: it judges every `.kz` path in the staged diff
(Added, Modified, Renamed — catching both new files and edits that removed
a file's last host line), reading the STAGED blob (`git show :path`), so
partial staging can't make the gate rule on bytes the commit won't ship.

Exemptions — the cases where a convertible `.kz` is legitimately `.kz`:
  - expected.json sibling  — AST-snapshot tests embed the literal input.kz
    filename; converting changes the snapshot. They stay .kz.
  - MUST_ERROR or error-EXPECT — negatives; a rename can change which
    error fires, and `.kz`-semantics pins (bare Koru = host_line) live here.
  - LANGUAGES — multi-target facet dirs.
  - input.k sibling — a deliberate both-facets dir.
  - tests/broken/ — parked tests are not migration targets.
  - checks/kz-preference.allow — `path | reason` for the deliberate cases
    (a positive test whose PURPOSE is the .kz parse surface, etc.). An
    entry only matters when its path is staged; dormant entries are notes,
    not failures — the diff-scope makes "matches no site" the normal case.

What it provably cannot see: whether a `.kz` is nearly pure (1-3 stray
host lines feeding emission vs residue — that gradient is judgment, the
future warning channel's class). And an UNPARSEABLE staged .kz is skipped
with a note — extension honesty is not parseability's job; the suite owns
that refusal.

Usage: check_kz_preference.py <koruc> [repo] [allow_file]
  koruc — the compiler binary (its --check-k-convertible is the oracle)
  repo  — repo whose STAGED diff is judged (default: the manifest repo)
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ERROR_TOKENS = ("FRONTEND_COMPILE_ERROR", "BACKEND_COMPILE_ERROR",
                "BACKEND_RUNTIME_ERROR", "BACKEND_EXEC_ERROR", "MUST_ERROR")


def broken(msg):
    print(f"BROKEN: {msg}", file=sys.stderr)
    sys.exit(2)


def classify(koruc, kz_bytes):
    """Run the oracle on a blob; returns (status, detail)."""
    fd, tmp = tempfile.mkstemp(suffix=".kz")
    try:
        os.write(fd, kz_bytes)
        os.close(fd)
        proc = subprocess.run([koruc, tmp, "--check-k-convertible"],
                              capture_output=True, text=True)
        line = (proc.stdout.strip().splitlines() or [""])[0]
        parts = line.split("\t")
        status = parts[0]
        detail = parts[2] if len(parts) > 2 else ""
        if status not in ("CONVERTIBLE", "NOT_CONVERTIBLE", "UNPARSEABLE"):
            return "UNPARSEABLE", f"unexpected oracle output: {line[:80]}"
        return status, detail
    finally:
        os.unlink(tmp)


def self_test(koruc):
    """The oracle is exercised, not trusted: three fixtures through the
    real path — pure Koru must flag, a host line and a ~proc must not."""
    pure = b"// a comment never blocks conversion\n~tor main {}\n~main()\n"
    host_line = b"const x: i64 = 1;\n~tor main {}\n~main()\n"
    proc_body = b"~proc main|zig {}\n~tor main {}\n~main()\n"
    failures = []
    s, _ = classify(koruc, pure)
    if s != "CONVERTIBLE":
        failures.append(f"must-match: pure-Koru .kz classified {s}")
    s, _ = classify(koruc, host_line)
    if s != "NOT_CONVERTIBLE":
        failures.append("must-not-match: a bare host line was not seen")
    s, _ = classify(koruc, proc_body)
    if s != "NOT_CONVERTIBLE":
        failures.append("must-not-match: a ~proc decl was not seen")
    return failures


def exempted(repo, rel, allow):
    """returns a reason string, or None."""
    d = os.path.dirname(os.path.join(repo, rel))
    if os.path.normpath(rel).startswith("tests/broken/"):
        return "tests/broken is parked"
    if rel in allow:
        return f"allow: {allow[rel]}"
    for marker in ("expected.json", "LANGUAGES", "MUST_ERROR", "input.k"):
        if os.path.exists(os.path.join(d, marker)):
            return f"sibling {marker}"
    exp = os.path.join(d, "EXPECT")
    if os.path.exists(exp):
        try:
            if any(t in open(exp).read() for t in ERROR_TOKENS):
                return "error-EXPECT dir"
        except OSError:
            pass
    return None


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__.strip().splitlines()[-3])
        return 2
    koruc = os.path.abspath(args[0])
    if not os.path.exists(koruc) and os.path.exists(koruc + ".exe"):
        koruc += ".exe"  # Windows host: the binary carries an extension
    repo = os.path.abspath(args[1]) if len(args) > 1 else \
        os.path.abspath(os.path.join(HERE, "..", ".."))
    allow_path = args[2] if len(args) > 2 else \
        os.path.join(HERE, "kz-preference.allow")

    if not os.path.exists(koruc):
        broken(f"no koruc at {koruc}")

    allow = {}
    if os.path.exists(allow_path):
        for ln in open(allow_path):
            ln = ln.strip()
            if not ln or ln.startswith("#"):
                continue
            path, _, reason = (p.strip() for p in ln.partition("|"))
            if not reason:
                broken(f"{allow_path}: entry '{path}' carries no reason")
            allow[path] = reason

    fails = self_test(koruc)
    if fails:
        broken("oracle self-test failed — the sweep below cannot be trusted\n"
               + "\n".join("  " + f for f in fails))

    proc = subprocess.run(
        ["git", "-C", repo, "diff", "--staged", "--name-only",
         "--diff-filter=AMR", "-z", "--", "*.kz"],
        capture_output=True)
    if proc.returncode != 0:
        broken(f"git diff --staged failed in {repo}: "
               f"{proc.stderr.decode()[:200]}")
    staged = [p for p in proc.stdout.decode().split("\0") if p]
    if not staged:
        return 0

    violations = []
    notes = []
    for rel in staged:
        reason = exempted(repo, rel, allow)
        blob = subprocess.run(["git", "-C", repo, "show", f":{rel}"],
                              capture_output=True)
        if blob.returncode != 0:
            notes.append(f"{rel} — staged path has no index blob; unjudged")
            continue
        status, detail = classify(koruc, blob.stdout)
        if status == "CONVERTIBLE":
            if reason:
                notes.append(f"{rel} — convertible, exempt ({reason})")
            else:
                violations.append(rel)
        elif status == "UNPARSEABLE":
            notes.append(f"{rel} — unparseable to the oracle; unjudged "
                         f"({detail or 'parse errors'})")

    for n in notes:
        print(f"note  {n}")
    for v in violations:
        print(f"VIOLATION  {v} — pure Koru wearing .kz; rename to .k "
              f"(or rule the exemption in checks/kz-preference.allow)")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
