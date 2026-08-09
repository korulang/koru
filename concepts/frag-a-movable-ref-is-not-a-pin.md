---
type: belief
id: frag-a-movable-ref-is-not-a-pin
provenance: session 2026-08-09 (Lars + Claude) — bettermaker pass over the PrimeKoru submission package
ts: 2026-08-09
tags: [koru, packaging, docker, reproducibility, benchmarks, drag-race]
---

A shipped package that builds its own toolchain must pin it by an **immutable
full commit SHA**. A tag is not a pin: it is a name someone can move, and moving
it is exactly what people do when a tag turns out to point somewhere wrong.

The failure is not that the tag moves — it is that **the package and its pinned
toolchain drift into different eras and nothing notices**, because a package
whose build is never run has no way to complain. Two independent reviewers
flagged the pin on `PrimeKoru/solution_1` in June; the remedy applied was to
*retag*, which preserved the movable ref and therefore preserved the failure
mode. On 2026-08-09 the source in that directory was migrated to current Koru
while `KORU_REF=drag-race-v1` still named the 2026-06-30 compiler, and
`docker build`, which the file's own header documents as the way to use it,
could not have succeeded from that moment.

Proven at the point of use, in both directions, rather than inferred:

    docker build --build-arg KORU_REF=drag-race-v1 -t primekoru-oldpin .
    → exit 1, error[PARSE001] at faithful.k:12 — the June compiler
      does not understand `-> i64`

    docker build -t primekoru .            # KORU_REF = full SHA
    → exit 0
    docker run --rm primekoru
    → stdout: korulang;57658;5.000050252;1;algorithm=base,faithful=yes,bits=1
      stderr: validated primes: 78498

`git clone --depth 1 --branch <ref>` is what forced the movable ref — `--branch`
accepts a branch or a tag and nothing else. Fetching the SHA directly
(`git init` + `git fetch --depth 1 origin <sha>` + `checkout --detach
FETCH_HEAD`) keeps the shallow clone and takes an immutable pin, so there is no
tension between reproducibility and clone cost.

The wider claim, which is the part worth keeping: **an artifact nobody builds is
an artifact nobody can trust, and the interval over which it rots is the
interval since someone last opened its documented door.** Here that was six
weeks, and the rot was introduced by the same session that was repairing the
directory.

Open question: nothing in the repo builds this package, so the next drift is
equally silent. Whether a periodic build belongs in the suite — it needs network
and Docker, which the regression harness deliberately does not assume — is
unsettled.
