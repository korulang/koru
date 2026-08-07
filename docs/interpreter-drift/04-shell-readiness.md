# 04 — Shell Readiness: twenty lines at a Koru prompt, and the three runtime questions

Scope: the INTERPRETER parser (`src/flow_parser.zig`, used by `koru_std/interpreter.kz`
via `koru_std/runtime.kz`), not the real compiler parser (`src/parser.zig`). Reached by
`std/runtime:run(source, scope)` → `interpreter:run` → `flow_parser.parseFlow`.

Reporter: ShellReadiness (scout). Probes run 2026-08-07 with the EXISTING
`zig-out/bin/koruc` (no rebuild). All `OBSERVED` rows are outputs I compiled and ran in
`.shell-probe/` and pasted verbatim below. Everything not prefixed `OBSERVED` is
`[INFERENCE]` from source reading.

---

## 0. What the framing ruling says (430_056/NEEDS_RULING) — read before everything

Bottom line of the ruling, restated in one sentence: **the interp is only lenient when
you write NO arms at all.** Partial handling (one arm) is the one shape that errors.
The three measured behaviors (430_056 `actual.txt`):

| source shape | firing branch | result |
|---|---|---|
| zero arms | `bad` | leaks: `result branch=[bad]` (payload intact) |
| one arm `\| ok` | `bad` | `DISPATCH ERROR: NoBranchMatch` |
| one arm `\| ok` | `ok` | arm runs, but `result branch=[]` — name lost |

I reconstruct all three of these below and add the shell-specific constraints.

---

## 1. Twenty lines (transcript of `std/runtime:run`, scope "shell")

Scope vocabulary (registered scope `shell`):

```koru
~pub tor say    { text }
~pub tor open   { path } | ok string | failed string
~pub tor append { path, text } | ok | failed string
~pub tor close  { path } | ok | failed string
```

`OBSERVED` — every line below is a real `run` from `probe.kz`, `probe2.kz`,
`probe3.kz` in `docs/interpreter-drift/.shell-probe/` (kept for repro). Outputs
verbatim.

| # | what a person types | observed result |
|---|---|---|
| 1 | happy-path one-liner `say(text: "hello")` | `> say: hello`; `result branch=[] nfields=0` |
| 2 | `append(\"a.txt\",\"x\") | ok` — head + arm, NO body, one line | `result branch=[ok] nfields=0` — parses & runs! |
| 3 | `append(\"a.txt\",\"x\")\n| ok` — arm on next line | `result branch=[ok] nfields=0` |
| 4 | typo'd event `apend(...)` | `EVENT DENIED: apend` (not dispatch-error) |
| 5 | missing arg `append(path:"a.txt")` | `result branch=[ok]` — missing `text` silently empty, NO error |
| 6 | wrong-typed `append(path: 42, ...)` | `result branch=[ok]` — `"42"` passed as string, NO error |
| 7 | extra arg `append(..., bogus:"c")` | `result branch=[ok]` — unknown arg ignored, NO error |
| 8 | unhandled branch, one arm `\| ok` (open missing) | `DISPATCH ERROR: NoBranchMatch` |
| 9 | unhandled branch, ZERO arms (open missing) | `result branch=[failed] nfields=1` — LEAK, payload survives |
| 10 | `open(\"notes.txt\")` — handle from previous line | `result branch=[ok] nfields=1`; see §3, a fresh pool can't carry it |
| 11 | empty line `""` | `PARSE ERROR: No flow found in source` |
| 12 | whitespace only `"   "` | `PARSE ERROR: No flow found in source` |
| 13 | trailing comment `say(...) // note` | `> say: ` (EMPTY!) — the trailing comment empties the string arg. Defect. |
| 14 | partial line `say(text:` | `> say: ` (EMPTY) — NOT an error; silently runs `say("")`. Defect. |
| 15 | very long line (400 x's) | runs fine, full text echoed |
| 16 | quoted `|>` in string `say(text: "a |> b")` | `> say: a |> b` — `|>` inside a string does NOT split. Good. |
| 17 | unicode `say(text: "hællo → 世界")` | `> say: hællo → 世界` — correct. |
| 18 | `~say(text:"hi")` | `PARSE ERROR: \`~\` is not legal in interpreter source…` (explanatory) |
| 19 | chained `open(...) \| ok h \|> close(...) \n \| ok` | `result branch=[ok] nfields=0` — happy-path chain runs |
| 20 | catch-all `\| _` | `DISPATCH ERROR: NoBranchMatch` — **`| _` is NOT a catch-all in the interpreter** |

### Nuance probe (probe2/probe3) — the exact NEEDS_RULING shell case

`OBSERVED` — `probe3.kz`:

| label | source | observed |
|---|---|---|
| N1 | SAME line `append(...) | ok |> say("done")` | **`PARSE ERROR: No flow found in source`** — the shell blocker |
| N2 | NEXT line `append(...)\n| ok |> say("done")` | body runs (`> say: done`), result `branch=[] nfields=0` — the C name loss |
| N3 | EXACT arm `open(missing)\n| failed` | `result branch=[failed] nfields=1 name0=__type_ref` — exact arm catches, name kept |
| N4 | ZERO arms `open(missing)` | `result branch=[failed] nfields=1 name0=__type_ref` — payload survives leak |
| N5 | `\| _` catch-all | `DISPATCH ERROR: NoBranchMatch` |

### What the transcript says about a SHELL

1. **You can write the happy path with a body only if you SPLIT the `| ok` arm onto its
own line** (N2 runs; N1 parse-fails). The real shell one-liner from NEEDS_RULING
(`read(...) | ok lines |> print.ln(...)`) is exactly N1 → it errors before it runs.
That parse failure is separable and is a flow_parser issue, cheap and useful on its own.
2. Even when it runs, an arm **with a body** erases the branch name from the result
(N2 → `branch=[]`). A shell that wants to see "which branch did I get back" cannot
see it once a body follows the arm — only `nfields` and no name. This is the known 430_056 C defect.
3. **No catch-all.** `| _` does not catch; you must name the exact branch (N5 vs N3).
An LLM generating Koru that reaches for `| _` gets NoBranchMatch.
4. **Malformed / partial / commented lines do not fail loudly** (13, 14): they silently
run with empty args. A shell that echoes confidence on these will mislead.
5. Trailing `//` comments empty the preceding string argument (13) — a parse defect
worth pinning.
6. `~`, quotes around `|>`, unicode, and very long lines are all handled well (16–18; 15).
7. Events that don't exist are surfaced as `EVENT DENIED` (4) — that one IS good.

---

## 2. The three questions, answered with evidence

### Q1 — When a run leaks an unhandled branch, what EXACTLY does the caller receive, and does the payload survive?

It depends on HOW MANY arms were written, and the three cases disagree (that is the
ruling). Precisely, from `koru_std/interpreter.kz`:

- **Zero arms → LEAK.** `executeFlow` returns the dispatch result directly when there
  are no continuations (`interpreter.kz:2301-2305`: `if flow.body.continuations.len == 0 return Value.fromDispatch(dispatch_result.branch, dispatch_result.fields)`).
  The caller receives **`.result { value, used, handles }`** where
  `value = Value{ branch: "failed", fields: [ { name: "__type_ref", value: string "ENOENT" } ] }`
  (OBSERVED N4). **The payload survives intact** — it is carried in `value.fields`,
  which `clonePersistent` copies before the arena is torn down (`interpreter.kz:312-328`),
  and serializes to JSON `{"branch":"failed","fields":{"__type_ref":"ENOENT"}}`
  (`interpreter.kz:253-278`). `used` and `handles` are `u64`/`u32` counts.
- **One arm that does NOT match → `.dispatch_error { event_name, message }`.**
  `executeFlow` falls through the continuation loop with no exact match and returns
  `error.NoBranchMatch` (`interpreter.kz:2462`), which `run` converts to
  `.dispatch_error` (`interpreter.kz:1262-1266`, surfaced at `runtime.kz:1617`).
  **The payload is DROPPED** — only `event_name` (the flow head, from `persistentEventName`)
  and `message="NoBranchMatch"` are returned. (OBSERVED probe1[8], N5.)
- **One arm that IS the branch**: handled; branch name preserved only if there is **no
  body** after it (OBSERVED N3 `branch=[failed]`). With a body, the name is lost to `[]`
  (OBSERVED N2).

So the answer to "does the payload survive a leak": **yes, fully, in the zero-arm
leak** (it becomes the `run` result's `.value` with fields), and **no, it is thrown away
in the one-arm NoBranchMatch** case. The resource-bridge consequence flagged in the
ruling — an unhandled `| opened` outcome carrying a HANDLE — only survives in the
leak shape, and even then only as `value.fields`; nothing tells the host the handle is
an obligation owner (see Q2/Q3).

### Q2 — Can the caller discover the NAMES of handles still held, or only the count?

**Through every Koru surface today: only the COUNT.**

- `std/runtime:run` / `run-cached` result: `| result { value, used, handles: u32 }`,
  `| exhausted { used, last_event, handles: u32 }` (`interpreter.kz:1073-1077`),
  populated by `handles = @intCast(active_pool.countUndischarged())`
  (`interpreter.kz:1275`). A number, not names.
- `std/bridge:get-handles { br } -> u32` returns `br.getHandleCount()` (`bridge.kz:128-132`) — also a count.
- The NEEDS_RULING note is exact: "run returns handles as a COUNT today — and
a count is not the thing."

The NAMES exist and are recoverable only by dropping into Zig on an external pool:
`HandlePool.getAllHandles()` and `getUndischarged()` (`interpreter.kz:514-537`) return
`[]Handle`, each `Handle` carrying `handle_id`, `obligation_module`, `obligation_name`
(the phantom state), `discharge_event`, `created_by_event`, `resource_type`, `scope_name`
(`interpreter.kz:440-453`). A caller that passes its OWN `handle_pool` into `run` (the
bridge does — `bridge.kz:171-174`) can read those names off the pool after the run.
But no `run` result and no `bridge` tor exposes them; the ONLY names a shell can see
are the ones the event returned as an ordinary payload field (e.g. `note_0` from
`open`, OBSERVED line 10) — which is not the obligation record.

**Answer: count only via the runtime surface; names only via dipping into the Zig
HandlePool of a caller-owned external bridge pool.**

### Q3 — Is there any existing runtime surface that reports which tors a scope contains, or which tors accept a handle's current phantom state?

**No. Neither exists at runtime. The `690_056` discharger discovery is compile-time only.**

- Which tors a scope contains: `get-scope` (`runtime.kz:1384-1397`) hands back
  **function pointers** — `dispatcher`, `cost_fn`, `creates/`discharges_obligations_fn`,
  `discharge_event_fn`, `creates/`discharges_spec_fn` — with NO names and no
  enumeration tor. There is no `list-tors` / `list-events` surface anywhere
  (searched: `interpreter.kz`, `runtime.kz`, `bridge.kz`; none). `lookupEventBranches`
  (`runtime.kz:1420-1432`) retrieves branch specs only when the CALLER already supplies
  the event name — it cannot enumerate. [INFERENCE: negative from grep across koru_std.]
- Which tors accept a handle's current phantom state: the mapping obligation→discharge-event
  is **baked in at registration / compile time.** The registry derives `discharge_event_fn`
  (and creates/discharges specs) from the event signatures' phantom syntax
  (`runtime.kz:197-199, 588-680` — the extract/create spec builders). At RUNTIME,
  `dischargeAllHandles` (`interpreter.kz:1518-1560`) walks the pool's held handles and
  calls each handle's RECORDED `discharge_event` (`Handle.discharge_event`, written at
  `pool.acquire` time, `interpreter.kz:2258-2260` and legacy 2244-2260). So the runtime
  discharge loop uses a **static, precomputed** per-obligation discharger; it never asks
  "which tors accept phantom X" at runtime.
- The frag's claim (`concepts/frag-typed-at-runtime-is-not-interpreted.md`):
  *"discharger discovery already computes something equivalent (690_056…)"* — is true at
  **COMPILE time only.** `690_056_store_file_open_column` is a STORE teardown that
  auto-inserts a discharger closure via the compile-time `auto_discharge_inserter` pass
  (see the pass pipeline in `compiler.kz:1269-1275` and `koru_std/store.kz`'s generated
  teardown). None of that is a runtime query; the interpreter never materialises
  "tors accepting a live phantom state."

**So what a SHELL would need does not exist and must be built:** a runtime manifest that
(1) enumerates the events/tors of a scope, and (2) given a held handle's
`obligation_name` (the phantom), returns the tors (and their signatures) that accept it.
The handle already records its phantom (`Handle.obligation_name`), so half the data is
live; the missing half is the per-scope tor→phantom acceptance table, which today only
lives in compile-time generated dispatch/scope-descriptor code. The frag lists exactly
this under **Open: "No manifest exists…"** — this investigation confirms it is not
reachable at runtime and is the piece a shell/wire-protocol would have to add.

---

## 3. Defects found (reconnaissance only — nothing fixed)

1. **Same-line head + `| arm |> body` parse-fails** with "No flow found in source"
   (OBSERVED N1) while the same head + `| arm` (no body) on one line parses fine
   (OBSERVED #2). Separable flow_parser issue; cheap; the shell blocker.
2. **Branch name lost when an arm has a body** (OBSERVED N2 → `branch=[]`). The 430_056 C defect.
3. **No catch-all `| _`** in the interpreter (OBSERVED N5 → NoBranchMatch).
4. **Trailing `//` comment empties the preceding string argument** (OBSERVED #13: `say: ` empty).
5. **Partial line doesn't error** — `say(text:` runs `say("")` silently (OBSERVED #14).
6. **Missing / wrong-typed / extra args are all silently accepted** (OBSERVED #5,#6,#7) —
   no arity/type check at runtime.
7. For Q2/Q3: no named-handle result field, no scope-tor enumeration, no live
   phantom-acceptance query — all must be built for a shell/wire protocol.

Probe sources kept at `docs/interpreter-drift/.shell-probe/` (`probe.kz`, `probe2.kz`,
`probe3.kz`) for the lead to pin as regression tests if desired.
