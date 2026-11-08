#!/usr/bin/env python3
"""CS-target sweep: measure every eligible regression test against the CS emitter.

For each positive MUST_RUN test that does NOT opt into JS via a LANGUAGES
marker, compile with `koruc --lang=cs`, run the emitted program under dotnet, compare
to expected.txt. Classifies each as:

  cs-pass          compile + node output matches expected.txt
  cs-mismatch      compiled and ran, but output != expected.txt
  cs-refused       compile refused cleanly (an error[KORU..] line, no crash)
  cs-compile-fail  compile failed without a located diagnostic (panic/crash)
  cs-noemit        compile reported success but produced no output_emitted.cs
  cs-runtime       dotnet exited non-zero after a successful compile
  cs-timeout       compile exceeded the timeout
  cs-run-timeout   node exceeded the runtime timeout
  cs-flags         skipped: test needs COMPILER_FLAGS the sweep does not model

Measurement only: never flips SUCCESS/FAILURE markers and never touches the
board. Artifacts it creates (output_emitted.cs, compile_cs.err, actual.cs.txt)
are removed per test. Results land in cs-sweep-results.jsonl (one JSON object
per line) plus a summary on stdout.

Env knobs: CS_SWEEP_JOBS (8), CS_SWEEP_COMPILE_TIMEOUT (120),
CS_SWEEP_RUN_TIMEOUT (30).
"""
import os
import sys
import json
import time
import subprocess
import concurrent.futures

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tests", "regression"))
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
KORUC = os.path.join(REPO, "zig-out", "bin", "koruc")
OUT = os.path.join(REPO, "cs-sweep-results.jsonl")
# The JS-REGRESSION baseline: the set of unmarked tests known to pass on JS.
# The sweep's only gate is that this set does not shrink — it never demands
# that MORE tests pass (CS is intentionally not-coherent, per Lars 2026-08-19).
BASELINE = os.path.join(REPO, "test-results", "cs-sweep-baseline.json")
JOBS = int(os.environ.get("CS_SWEEP_JOBS", "8"))
COMPILE_TIMEOUT = int(os.environ.get("CS_SWEEP_COMPILE_TIMEOUT", "120"))
RUN_TIMEOUT = int(os.environ.get("CS_SWEEP_RUN_TIMEOUT", "30"))

ARGS = sys.argv[1:]
UPDATE_BASELINE = "--cs-baseline-update" in ARGS
FAIL_ON_REGRESSION = "--fail-on-regression" in ARGS

# The sweep must NOT run concurrently with a regression suite: the suite clears
# and rewrites SUCCESS/FAILURE markers in waves, so mid-suite a candidate pool
# measured against `SUCCESS` is an inflated/deflated fiction (measured
# 2026-08-19: a sweep started under a foreign suite's lock saw 145 of 921
# candidates and reported 530 false regressions). Refuse loudly instead.
RUN_LOCK = os.path.join(REPO, ".regression-run.lock")
MACHINE_LOCK = os.path.join(os.environ.get("TMPDIR", "/tmp"), "koru-regression.lock")
if not UPDATE_BASELINE and "--ignore-suite-lock" not in ARGS:
    for lock in (RUN_LOCK, MACHINE_LOCK):
        if os.path.isdir(lock):
            print(f"[cs-sweep] REFUSE: a regression suite holds {lock} — the marker "
                  "state is mid-run and a sweep would measure fiction. Wait for the "
                  "suite to finish, or pass --ignore-suite-lock to force.", file=sys.stderr)
            sys.exit(2)

ENV = dict(os.environ)
ENV["KORU_STDLIB"] = os.path.join(REPO, "koru_std")
ENV["KORU_PATH"] = REPO


def collect_candidates():
    # LANGUAGES-marked dirs (the measured set) — sweep everything else that is
    # a positive, passing MUST_RUN test.
    lang = set()
    for dp, _dn, fn in os.walk(ROOT):
        if "LANGUAGES" in fn:
            lang.add(dp)
    cs_marked = {
        d for d in lang
        if "cs" in open(os.path.join(d, "LANGUAGES")).read().split()
    }

    tests = []
    for dp, dn, fn in os.walk(ROOT):
        if ".zig-cache" in dp.split(os.sep):
            dn[:] = [d for d in dn if d != ".zig-cache"]
            continue
        has_input = "input.k" in fn or "input.kz" in fn
        markers = set(fn) & {"TODO", "SKIP", "BROKEN", "SUCCESS", "FAILURE",
                             "MUST_ERROR", "EXPECT", "MUST_RUN", "LANGUAGES"}
        if has_input and markers:
            tests.append(dp)
            dn[:] = []

    def has(t, n):
        return os.path.exists(os.path.join(t, n))

    return [
        t for t in tests
        if t not in cs_marked
        and has(t, "MUST_RUN")
        and has(t, "expected.txt")
        and has(t, "SUCCESS")
        and not has(t, "FAILURE")
    ]


def classify(td):
    rel = os.path.relpath(td, ROOT)
    entry = "input.kz" if os.path.exists(os.path.join(td, "input.kz")) else "input.k"
    entry_abs = os.path.join(td, entry)

    if os.path.exists(os.path.join(td, "COMPILER_FLAGS")):
        return {"dir": rel, "class": "cs-flags",
                "detail": open(os.path.join(td, "COMPILER_FLAGS")).read().strip()}

    try:
        cp = subprocess.run(
            [KORUC, entry_abs, "--lang=cs"],
            cwd=td, env=ENV, capture_output=True, text=True,
            timeout=COMPILE_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {"dir": rel, "class": "cs-timeout", "detail": f"compile >{COMPILE_TIMEOUT}s"}

    combined = (cp.stdout or "") + (cp.stderr or "")
    with open(os.path.join(td, "compile_cs.err"), "w") as f:
        f.write(combined)

    cs_out = os.path.join(td, "output_emitted.cs")
    if cp.returncode != 0:
        clean = "error[KORU" in combined and "panicked" not in combined \
            and "SIGABRT" not in combined and "SIGSEGV" not in combined
        return {"dir": rel,
                "class": "cs-refused" if clean else "cs-compile-fail",
                "detail": combined.strip().splitlines()[-1][:200] if combined.strip() else f"rc={cp.returncode}"}

    if not os.path.exists(cs_out) or os.path.getsize(cs_out) == 0:
        return {"dir": rel, "class": "cs-noemit", "detail": "no output_emitted.cs"}

    args = []
    if os.path.exists(os.path.join(td, "ARGS")):
        args = [l.rstrip("\n") for l in open(os.path.join(td, "ARGS")) if l.strip()]

    try:
        rp = subprocess.run(
            ["./a.out", *args],
            cwd=td, capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        return {"dir": rel, "class": "cs-run-timeout", "detail": f"run >{RUN_TIMEOUT}s"}

    actual_path = os.path.join(td, "actual.cs.txt")
    with open(actual_path, "w") as f:
        f.write(rp.stdout)

    if rp.returncode != 0:
        return {"dir": rel, "class": "cs-runtime",
                "detail": f"a.out exited {rp.returncode}: {(rp.stderr or rp.stdout).strip().splitlines()[-1][:200]}"}

    exp = open(os.path.join(td, "expected.txt")).read().rstrip()
    act = rp.stdout.rstrip()
    result = {"dir": rel, "class": "cs-pass" if exp == act else "cs-mismatch",
              "detail": "" if exp == act else f"expected {len(exp)}B, got {len(act)}B"}

    # Cleanup the artifacts this sweep created (all gitignored, but keep the
    # tree as we found it).
    for f in ("output_emitted.cs", "compile_cs.err", "actual.cs.txt",
                  "a.out", "a.out.dll", "a.out.deps.json", "a.out.pdb",
                  "a.out.runtimeconfig.json", "koru.csproj", "Program.cs",
                  "backend.zig", "backend_output_emitted.zig",
                  "build_backend.zig", "build.zig"):
        try:
            os.remove(os.path.join(td, f))
        except OSError:
            pass
    return result


def load_baseline():
    try:
        return set(json.load(open(BASELINE))["passed"])
    except Exception:
        return None


def write_baseline(passed, failed, refused, ts):
    base = list(sorted(passed))
    os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
    with open(BASELINE, "w") as f:
        json.dump({"passed": base, "summary": {"passed": len(passed), "failed": failed,
                                              "refused": refused, "ts": ts}},
                  f, indent=2, sort_keys=True)
    return BASELINE


def main():
    cands = collect_candidates()
    print(f"sweeping {len(cands)} eligible tests (not JS-marked) with {JOBS} workers", flush=True)
    counts = {}
    rows = []
    t0 = time.time()
    with open(OUT, "w") as out:
        with concurrent.futures.ThreadPoolExecutor(max_workers=JOBS) as ex:
            futs = {ex.submit(classify, t): t for t in cands}
            done = 0
            for fut in concurrent.futures.as_completed(futs):
                r = fut.result()
                rows.append(r)
                out.write(json.dumps(r) + "\n")
                counts[r["class"]] = counts.get(r["class"], 0) + 1
                done += 1
                if done % 100 == 0 or done == len(cands):
                    print(f"  {done}/{len(cands)} done...", flush=True)
    elapsed = time.time() - t0

    passed = {r["dir"] for r in rows if r["class"] == "cs-pass"}
    print(f"\n=== JS SWEEP SUMMARY ({elapsed:.0f}s, {len(cands)} tests) ===")
    for c in ["cs-pass", "cs-refused", "cs-mismatch", "cs-runtime", "cs-compile-fail",
              "cs-noemit", "cs-timeout", "cs-run-timeout", "cs-flags"]:
        print(f"  {c:16} {counts.get(c, 0)}")
    print(f"results: {OUT}")

    regressions = []
    improvements = []
    baseline = load_baseline()
    if baseline is None:
        print("\n[no baseline] first sweep — run with --cs-baseline-update to pin the "
              "JS-pass set as the regression baseline")
    else:
        regressions = sorted(baseline - passed)
        improvements = sorted(passed - baseline)
        print(f"\n=== JS REGRESSION CHECK (baseline {len(baseline)} passing) ===")
        print(f"  now passing: {len(passed)}")
        if regressions:
            print(f"  ⚠ {len(regressions)} REGRESSED (previously passed on JS):")
            for d in regressions:
                print(f"      {d}")
        else:
            print("  ✓ no regressions — every previously-passing test still passes")
        if improvements:
            print(f"  ✓ {len(improvements)} newly passing on JS:")
            for d in improvements:
                print(f"      {d}")

    if UPDATE_BASELINE:
        res = write_baseline(passed, counts.get("cs-runtime", 0) + counts.get("cs-mismatch", 0),
                             counts.get("cs-refused", 0), time.time())
        print(f"\n[baseline updated] {len(passed)} tests pinned at {res}")

    if FAIL_ON_REGRESSION and regressions:
        print("\n[cs-sweep] FAIL: CS regressions detected (--fail-on-regression)")
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
