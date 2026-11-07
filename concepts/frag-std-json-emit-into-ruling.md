---
type: belief
id: frag-std-json-emit-into-ruling
provenance: session 2026-11-07 (Lars + Devin) — orisha HANDOFF "QUEUED TASK: std/json:emit.into + zero-copy respond"
ts: 2026-11-07
tags: [koru, stdlib, json, emit, transforms, ruling]
---

`std/json:emit.into` is a ruled spelling (Lars, 2026-11-07): the third
EmitDrive mode beside `emit` (heap) and `emit.ln` (per-callsite
threadlocal scratch). Call syntax `emit.into(buf: <slice>,
value: {...}): n` — `buf:` and `value:` resolve BY NAME in either
order; `buf` is a writable `[]u8` spliced verbatim into the generated
writer; the site returns `usize` (bytes written — snprintf contract,
no slice return, because the phantom system cannot honestly express
"borrows caller's buf"). Overflow panics naming emit.into with "exceeds
the provided buffer" (the length is runtime). No reserve pass, same as
emit.ln. Intended consumer: a connection's send region rendered
contiguous with its head — orisha's respond-filled path.

EmitDrive.drive(comptime mode: Mode{heap,ln,into}) swaps only the
writer prelude and epilogue; schema resolution, refusals, and the write
sequence are shared verbatim. Lives in `koru_std/json.emitdrive.kz`
(~part emitdrive); the emit.ln/emit.into decls stay in
`json.emitln.kz` — the line wall pins every part file, so the driver and
the decls split rather than grow.
