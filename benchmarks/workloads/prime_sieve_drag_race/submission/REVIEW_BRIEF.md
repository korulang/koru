# PrimeKoru — Drag-Race Submission: Reviewer Sign-Off Brief

You are one of several independent agents asked to give a **final adversarial
sign-off** on a benchmark submission **before** it is opened as a public pull
request. Nothing has been submitted. Nothing is public. Your job is to find what's
wrong *before the maintainers do* — this is reputational, it goes out under the
maintainer's name, so err toward skepticism.

This brief is self-contained: every file and rule you need is inlined below. You do
not need repo access to review it. If you do have repo access, the package lives at
`benchmarks/workloads/prime_sieve_drag_race/submission/PrimeKoru/solution_1/` in the
`korulang/koru` repo — **read those committed files as canonical; the inline copies in
§7 are the pre-fix versions, kept for context.**

---

## Round 2 — for the second reviewer (what changed since the first pass)

A first independent reviewer (GLM) returned **FIX-FIRST** with two blockers and three
should-fixes. All were verified against the source and addressed; your job is to (a)
confirm the fixes actually landed and are honest, and (b) find anything the first pass
missed. The fixes:

- **B1 — "SIMD" overclaim (was a blocker).** The README/Dockerfile claimed the compiler
  "writes the SIMD." Verified against the *emitted* Zig: `mark-multiples` lowers to
  **unrolled scalar** `data[w+c] |= mask` with baked-immediate masks — **zero `@Vector`**.
  (Koru *does* have a real `@Vector` SIMD path, but it lives in `strike`, a runtime event
  the sieve never calls.) Fixed: the docs now credit Koru with the unrolling +
  residue-specialization and the backend (LLVM) with any auto-vectorization. **Scrutinize
  the new wording — is it now accurate, and does anything still overclaim?**
- **B2 — output channel (was a blocker, and it was worse than reported).** Running the
  binary with channels split revealed Koru's whole `print` family wrote to **stderr**, so
  the official result line wasn't reaching stdout at all. This was fixed at the toolchain
  level: `print`/`print.ln`/`print.blk` now go to **stdout**, a new `eprint`/`eprint.ln`
  goes to **stderr**, and `faithful.k` now emits the official line on stdout and the
  `validated primes` check on stderr. **Verify by running it:** `./a.out 1>out 2>err` —
  `out` must contain ONLY the `koru;…` line.
- **S1 — comptime-size faithfulness wrinkle:** now stated explicitly in the README.
- **N1 — `field` named as the class-equivalent:** added.
- **S2 (mark-multiples framing), S3 (tag push):** S2 judged honest, no change; S3 is a
  logistical step at PR time.

**Still deliberately open** (weigh in if you disagree): one solution vs two (we ship the
`faithful=yes` entry; a `faithful=no` reuse variant could be `solution_2`), and the
`faithful=yes` tag itself remains a judgment call (defensible, with the wrinkle owned).

Give the same output as before: **SHIP / FIX-FIRST / DO-NOT-SHIP** + severity-tagged
findings. Take **no public action** — read and advise only.

---

## 1. What this is

[Koru](https://github.com/korulang/koru) is a high-level, effect-oriented language.
We are submitting a Sieve of Eratosthenes entry to **Dave Plummer's "Software Drag
Racing"** (`PlummersSoftwareLLC/Primes`) — primes ≤ 1,000,000, self-timed for 5
seconds, single-threaded, one bit per flag, tagged `faithful=yes`.

**The interesting claim** is that Koru's *compiler generates the SIMD marker*:
`std/field:mark-multiples(...)` is a `[comptime|transform]` event, so the program
states *which* multiples to cross out and the compiler emits a specialized, unrolled,
residue-class-specialized native marker (same machinery as Koru's regex→DFA). The
sieve, the 5-second timing loop, and the pass counting are all written in Koru; the
only host effect is reading the clock.

## 2. What we need from you

A verdict — **SHIP / FIX-FIRST / DO-NOT-SHIP** — plus a list of concrete findings,
each with a severity (blocker / should-fix / nit) and, where you can, a suggested fix.
We especially want you to **challenge the claims we think are already settled** (§5).

The single highest-stakes thing to judge: **is the `faithful=yes` claim honest and
defensible, and is it presented without overclaiming?** (§4, §5). If you think it
isn't, say so plainly — we would rather submit `faithful=no` than have a `faithful=yes`
bounced.

## 3. The rules we must satisfy (verbatim from the repo's `CONTRIBUTING.md`, `drag-race` branch)

**Faithfulness** — an implementation is faithful if:
> - It uses no external dependencies to calculate the actual sieve.
> - It uses a class to encapsulate the sieve, or a (closest) equivalent feature in your language if a class construct is not available. This class must contain the full state of the sieve. Each iteration should re-create a new instance of this class from scratch.
> - The sieve size and corresponding prime candidate memory buffer (or language equivalent) are set/allocated dynamically at runtime. The size of the memory buffer must correspond to the size of the sieve.
> - It conforms to the base rules.

**Honest representation:**
> A solution submitted as a language X entry must implement the benchmark logic - the sieve, the timing loop, the pass counting - in language X. Using another language for those parts and calling into language X for a subroutine does not qualify as a language X entry. In certain cases, implementations in language X where certain features are supported using a different language may be admissible as a Mixed language solution - this is decided upon at the maintainers' discretion.
> The description of a solution in its README and in the pull request must accurately represent what the code does. Fabricated benchmark results, unsupported claims about language capabilities, or descriptions that do not match the submitted code are grounds for rejection.

**Build from source:**
> If a solution depends on an external compiler, interpreter, or toolchain that is not a standard distribution package, that toolchain must be built from source within the Dockerfile. Pre-built opaque binaries fetched from external URLs at build time are not acceptable.

**Output:** one line to stdout, exactly:
`<label>;<passes>;<seconds>;<threads>;algorithm=base,faithful=yes,bits=1` (en_US decimals).
Auxiliary output should go to stderr if the language allows.

## 4. The faithfulness argument (the crux — judge this hardest)

The entry allocates a fresh sieve (`std/field:new`) every pass and frees it, inside
the timed loop. Koru's compiler then applies **escape analysis**: it proves the
per-pass buffer does not escape the loop body and places it **on the stack**.

Our position: this is `faithful=yes` because —
- the *source* genuinely re-creates a fresh, sized-to-the-sieve instance each pass
  (not a reused or static buffer);
- stack placement is a compiler optimization of *where* the bytes live; the program's
  meaning is unchanged;
- this is the **same optimization the JVM performs** (escape analysis / scalar
  replacement) for Java entries already accepted as `faithful=yes` in this repo, and
  that Go performs for non-escaping `make()`.

**The known wrinkle:** the sieve size in the entry is a compile-time constant
(`bits: 500000`), and stack-placement currently fires only for a comptime size. A
strict reading of *"sieve size … set/allocated dynamically at runtime"* could be read
as a miss. Our counter: the reference solutions also hardcode the 1,000,000 constant,
so "set dynamically at runtime" is about per-pass runtime *allocation* (not a reused
static), which we do.

**Questions for you:**
1. Is this argument sound, or is there a hole a strict maintainer would catch?
2. Is it presented *honestly* in the README (§7), or does any phrasing overclaim?
3. Would you submit it `faithful=yes`, or play it safe as `faithful=no`? Why?

## 5. What we've already verified — challenge these, don't take them on faith

- **hadolint**: clean (exit 0) against the repo's `config/hadolint.yml`.
- **Build smoke-test** (arm64, Docker, building koru from the public `main` branch):
  builds end-to-end and `docker run` prints:
  `validated primes: 78498` then
  `koru;82788;5.000043585;1;algorithm=base,faithful=yes,bits=1`.
  (The 82,788 is an arm64-in-Docker sanity number, **not** a performance claim — the
  official numbers come from the maintainers' machines.)
- **Zig-fetch precedent**: the Dockerfile fetches Zig (koruc's build toolchain) from
  ziglang.org. All three existing `PrimeZig` solutions obtain Zig the same way, so this
  is established precedent. koruc itself is built from source.
- **Repo is public**, so the maintainers' CI can `git clone` it during the build.

## 6. Honest-representation question (judge this too)

The benchmark logic — sieve, timing loop, pass counting — is in Koru. But the *marker*
that `mark-multiples` emits is native code (Koru's compiler lowers the transform to
Zig). We frame this as "a Koru stdlib transform that generates the marker — the same
category as Rust intrinsics or C builtins." **Is that framing honest, or is it the
kind of 'calling into another language for the hot part' that the honest-representation
rule is meant to exclude?** This is maintainer discretion; we want your read on whether
our framing is fair or spun.

## 7. The files under review (inlined in full)

> ⚠️ **SUPERSEDED — these inline copies are the Round-1 (pre-fix) versions, kept for
> historical context.** The canonical, corrected files are committed under
> `submission/PrimeKoru/solution_1/`. Differences since: the `print.ln`→`eprint.ln`
> validation split, the corrected (non-"SIMD") marker wording, the `korulang` output
> label, and the README template title. Read the committed files, not these, for review.

### 7a. `faithful.k` — the entry source

```
import std/io
import std/time
import std/field
import std/control

pub event tick { deadline: i128, passes: i64 }
| live { deadline: i128, passes: i64 }
| expired i64

pub event run { deadline: i128 }
| total i64

tick = std/time:now()
| t n |> if(n < deadline)
    | then => live { deadline, passes }
    | else => expired passes

run = #L tick(deadline, passes: 0)
| live l |> std/field:new(bits: 500000)
    | field f |> for(1..500)
        ! each i |> std/field:test(f, i): pv |> if(pv == 0)
            | then |> std/field:mark-multiples(f, 2 * i * (i + 1), 2 * i + 1, 499999)
        | done |> std/field:free(f) |> @L(l.deadline, passes: l.passes + 1)
    | err _ |> _
| expired e => total e

std/time:now()
| t t0 |> run(deadline: t0 + 5000000000)
    | total n |> std/time:now()
        | t t1 |> std/field:new(bits: 500000)
            | field g |> for(1..500)
                ! each i |> std/field:test(g, i): pv |> if(pv == 0)
                    | then |> std/field:mark-multiples(g, 2 * i * (i + 1), 2 * i + 1, 499999)
                | done |> std/field:count-zeros(g, 1, 500000): c |> std/io:eprint.ln("validated primes: {{ c + 1:d }}") |> std/io:print.ln("koru;{{ n:d }};{{ @as(f64, @floatFromInt(t1 - t0)) / 1000000000.0:f }};1;algorithm=base,faithful=yes,bits=1") |> std/field:free(g)
            | err _ |> _
```

Notes for the reviewer: `{{ … }}` is Koru's interpolation syntax (not a templating
artifact). The first block is the timed 5s loop (re-creating the field each pass); the
second block is a single validation pass that prints the prime count and the official
line. `#L`/`@L` is Koru's conditional-back-edge loop; the loop condition lives in the
`tick` head event (`| live` continues, `| expired` exits).

### 7b. `Dockerfile`

```dockerfile
# (multi-stage: build koruc from source at a pinned tag, then compile the sieve)
FROM debian:bookworm-slim AS build
ARG ZIG_VERSION=0.15.2
ARG KORU_REPO=https://github.com/korulang/koru.git
ARG KORU_REF=drag-race-v1
# hadolint ignore=DL3008
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
        amd64) zarch=x86_64 ;; \
        arm64) zarch=aarch64 ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zarch}-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; /opt/zig/zig version
ENV PATH=/opt/zig:$PATH
RUN git clone --depth 1 --branch "${KORU_REF}" "${KORU_REPO}" /koru
WORKDIR /koru
RUN zig build
WORKDIR /work
COPY faithful.k ./faithful.k
RUN /koru/zig-out/bin/koruc faithful.k

FROM debian:bookworm-slim
WORKDIR /work
COPY --from=build /work/a.out /work/program.ast.json ./
CMD ["./a.out"]
```

Reviewer notes: `KORU_REF` defaults to a tag (`drag-race-v1`) that is **not yet pushed**
(we hold it until PR time). The smoke-test built with `--build-arg KORU_REF=main`.
koruc emits `program.ast.json` and reads it back at runtime, so the runtime stage
copies `a.out` + `program.ast.json` (confirmed sufficient).

### 7c. `README.md` (the public-facing writeup — judge for honesty and tone)

````markdown
# PrimeKoru solution_1 — Koru

A Sieve of Eratosthenes in [Koru](https://github.com/korulang/koru), a high-level
language whose compiler **generates** the SIMD marker.

![Algorithm](https://img.shields.io/badge/Algorithm-base-green)
![Faithfulness](https://img.shields.io/badge/Faithful-yes-green)
![Parallelism](https://img.shields.io/badge/Parallel-no-green)
![Bit count](https://img.shields.io/badge/Bits-1-green)

## What this is

Koru is a high-level, effect-oriented language. The interesting thing it does for
this benchmark is in the marking step. The sieve calls:

    std/field:mark-multiples(f, from, stride, limit)

`mark-multiples` is a `[transform]` — a **compile-time** event. The program states
*which* multiples to cross out; at each call site the compiler reads the access
pattern and **emits a specialized, unrolled, vectorized native marker** (a
residue-class-specialized function per stride, dispatched through a function-pointer
table). It's the same machinery Koru uses to compile a regular expression to a DFA:
the readable, high-level call and the fast code are the same source. You write "cross
out the multiples"; the compiler writes the SIMD.

The **sieve, the 5-second timing loop, and the pass counting are all written in
Koru** (a `#L`/`@L` label-fold loop). The only thing that drops to a host effect is
reading the clock (`std/time:now`) — which is how Koru performs every effect, the
same category as a stdlib call in any language.

## Faithfulness

This entry is tagged `faithful=yes`. The case, stated plainly so reviewers can judge it:

- The sieve state is encapsulated in a `field` (Koru's bit-array type), and the
  source allocates a **fresh `field` every pass** (`std/field:new` … `std/field:free`)
  inside the timed loop — it is genuinely re-created from scratch each iteration, not
  a reused or static buffer.
- The buffer is sized to the sieve and allocated by the per-pass `new`.
- Koru's compiler applies **escape analysis**: it proves the per-pass `field` does not
  escape the loop body and places it on the stack. This is a compiler optimization of
  *where* the allocation lives — the program's meaning is unchanged — and it is the
  same optimization the JVM performs (escape analysis / scalar replacement) for Java
  entries already accepted as `faithful=yes` in this repository, and that Go performs
  for non-escaping `make()`.

In other words: the source models faithful per-pass allocation; the compiler makes it
cheap underneath. If the maintainers read the rule differently, we're glad to discuss
or re-tag — the base algorithm, the fresh-instance-per-pass structure, and `bits=1`
are accurate regardless.

## Build and run

The Dockerfile builds the Koru toolchain (`koruc`) **from source** at a pinned tag,
then compiles the sieve through Koru's full pipeline. Zig — `koruc`'s own build
toolchain — is fetched from the official ziglang.org release, the same way the
existing PrimeZig solutions obtain it.

    docker build -t primekoru .
    docker run --rm primekoru

Supports `amd64` and `arm64`.

## Output

On stdout:

    validated primes: 78498
    koru;<passes>;<seconds>;1;algorithm=base,faithful=yes,bits=1

The first line is a correctness check (π(1,000,000) = 78,498); the second is the
official result line.
````

## 8. Open items we already know about (confirm / weigh in, don't just re-report)

1. **Validation line on stdout.** `validated primes: 78498` currently prints to stdout
   alongside the official line. The rules say aux output *should* go to stderr if the
   language allows — Koru has `std/io:eprintln`. Moving it changes the benchmarked
   source, so we left it. Is the extra stdout line a real risk (does the repo's parser
   tolerate it), or should we move it to stderr before submitting?
2. **One solution or two?** We could also submit the `faithful=no` variant (a
   reused/cleared buffer, faster) as `solution_2`, the way the Zig/C++ entries ship
   multiple. Worth it, or does one clean `faithful=yes` entry read better?
3. **mark-multiples framing** (§6).

## 9. Ground rules for your review

- **Be adversarial.** Assume the maintainers are strict and time-pressed and will
  close a PR that looks like it overclaims or doesn't fit the rules.
- **Do not take §5 on faith** — challenge the verified claims if you see a gap.
- **Honesty is the top priority.** Flag any overclaim or any place the description
  doesn't match what the code does, hardest of all.
- **Take NO public action.** Do not submit, fork, push, or post anything. This is a
  read-and-advise pass only. Return your findings as text.
