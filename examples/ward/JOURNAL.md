# Ward, Java → Rust → Koru

The public program is [Ward](https://github.com/B-Software/Ward) (Java Spring),
ported to Rust as [ward-rs](https://github.com/AntonyLeons/ward-rs) in April 2026.
This is the next hop.

Friction is recorded here as it happens. A missing surface is a toolchain
job, not a reason to reshape Ward.

## 2026-08-17 — `std/fmt:fmt.blk` was dead

The dashboard HTML is larger than `fmt:ln`'s thread-local buffer. `fmt.blk`
is the allocating twin; 620_007 pinned it red. Three defects in `koru_std/fmt.kz`:
`fmt.blk.impl` had no return/branch, the inline body broke to a dangling `:__blk`,
and it named `std.io.FormattedText` which does not exist. Fixed in this port:
impl is `-> string<std.io:allocated!>`, break is `__KORU_INLINE__`, auto-discharge
inserts `std/io:free`. 620_007 is green. Ward's page uses that surface.

## 2026-08-17 — router `: bind` emitted `switch (x) { . =>`

`! [GET /api/usage] |> usage(): u |> fmt:ln(...)` is a bare-return bind inside
an orisha:router arm. continuation_codegen treated every nested continuation as
a tagged-union switch, so a `: u` bind became `switch (result) { . =>` — not
Zig. 350_015 already pinned the visitor_emitter copy; 350_021 pins this copy.
Fix: a `: bind` (or empty-branch `|>` chain) binds the value and continues;
only non-empty branch names switch.

Dead strip then deleted `usage` because the router had inlined the call into a
string. Reachability is a fact about the source program: the pass now also
walks `original_ast` and scans `inline_body` for `name_event.handler`.

## 2026-08-17 — trailing comma made `string` a Zig identifier

A multiline `-> { name: string, }` is a legal record. `struct_literal.splitFields`
treated the empty slice after the last comma as a field, `parseFields` refused
it, and `writeBareReturnType` pasted the shape verbatim — `string` never
lowered. One-line `{ days: string }` has no trailing comma, so it worked.
020_063 now carries a `string` field so the pin is the lowering, not just the
join. Ward's `info` tor keeps its multiline shape.

## 2026-08-17 — HTML `>{{` was typed-source syntax

`fmt.blk { <h1>{{ name:s }}</h1> }` inside an orisha:router arm parsed the
interpolation as `event <h1>{ … }`. The scan for `>{` anywhere in the
invocation is how `<Type>{` was spelled; HTML `<tag>{{` is that substring.
The typed `<Type>` sits on the source-opening `{` only. 350_022 pins it.
Ward's GET / is this combination: bind `info()`, format HTML.
fmt.blk allocates; auto-discharge cannot see a site the router has already
inlined to Zig, so continuation_codegen frees the buffer after the arm
uses it (print, 350_022). An arm that `return`s the slice must not free —
the Response still holds it.

## 2026-08-17 — allocated HTML through Response/send

A router arm that `return`s fmt.blk's slice cannot free in the arm (the
Response holds it) and cannot rely on auto-discharge (the site is already
Zig). `Response.body_allocated` is false by default (JSON `fmt:ln` TLS,
static slices). continuation_codegen sets it true when the arm returns an
allocPrint buffer. `orisha:answer` passes the flag through; `serve` calls
`orisha:release-body` after reply. 350_023 pins handler = router, fmt.blk
HTML as `body: f`, answer, print, release — leak-check green. Ward GET /
is that path: setup.html via fmt.blk, 200 this session.

A file-level `const { port: "4000" }` interpolated as `{{ port:s }}` inside
that inlined handler is undeclared: the const lives on `main_module`, the
handler body is emitted on `koru_orisha`. Setup's default is `value="4000"`
matching `serve(port: 4000)` until `--port` binds a local in the arm — that
qualification is the next hole, not a reason to skip interpolating then.

## 2026-08-18 — `std/fs:write`, POST /api/setup, configured GET /

`std/fs` only streamed. `| written` / `| failed` is the other half; 650_008
pins write then `read-lines`. Ward's POST `/api/setup` parses the JSON body
(`parse-setup(req.body)` puns — the last path segment is `body`) and writes
`setup.ini` through that surface. GET / `read-file`s the ini: `| ok` is the
dashboard (fmt.blk over `parse-ini` + `info` + `uptime`), `| not-found` is
setup, `| failed` is 500 with the io string.

Three more holes on the way, all pinned, none rerouted:

- Source-block text shallower than the branch that opened it (`| cfg` at 8,
  HTML at 4) stopped the gatherer (PARSE001). 210_207. Sibling `|`/`!` still
  stop it (210_139).
- Kebab tor names inlined into a router arm were emitted as subtraction
  (`parse-setup_event`). `appendMangled` in `buildEventPath`. 350_024.
- Orisha's `const c = std.c` sat at module scope; a Koru bind named `c`
  (`| cfg c`) is a Zig 0.15 shadow error. The libc alias is `libc`. 350_025.

Backend cache still hashes `src/` + `koru_std` and not Orisha. An orisha
edit can cache-hit a stale `a.out`. Bust the key (change a stdlib byte) or
`zig build --build-file build_backend.zig` against the live `output_emitted.zig`.

## 2026-08-18 — processor stuck at 000%

`kern.cp_time` is not an oid on this Darwin (`sysctl: unknown oid`). Every
`/api/usage` hit `catch return 0`, so the gauge looked idle. RAM and storage
were real. Mach `host_statistics(HOST_CPU_LOAD_INFO)` is the load ticks
(USER/SYSTEM/IDLE/NICE); idle is index 2. Failure panics instead of looking
like 0%. First sample after boot is still 0 — there is no interval yet.


## 2026-08-17 — multiline `-> { record }` was a new construct per line

`.k` synthesizes `~` on every top-level line. `pub tor info {} -> {` left the
record unclosed, so `processor_name: string,` became KORU040 unknown tor.
Input shapes already gathered following lines; the return type did not.
020_063 pins the join. Twin of parseEventInputShapeFromFollowingLines.
