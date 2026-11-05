# package-assay: pg — the native pgwire driver

Target: `koru-libs/pg` (`index.kz`, 321 lines, `DESIGN.md`), a native
PostgreSQL wire-protocol driver — connect, simple 'Q' query, streaming
rows, extended protocol (prepare / bind.exec / send.pending pipelining),
drain contract, zero-copy column views, caller-owned fd for event-loop
driving. Assayed against koru `main @ b88e4a3dc` (worktree `assay-pg`)
and koru-libs `0fcacb9` — note `pg/DESIGN.md` carries uncommitted WIP
and `pg/tests/bench.out` is untracked; this map reads the working tree.

The package compiles today: `koruc -c` over a copy of
`tests/first_query.k` in the probe worktree (koru.json `paths` alias
`koru` → package root) — `✓ Shape checking passed`. No live postgres was
run; runtime claims below are read off the code and the DESIGN spikes,
not re-measured.

## exists (named surface + evidence)

- **The wire surface itself** — `connect`, `socket`, `set-nonblocking`,
  `disconnect`, `query`, `row.next`, `col.bytes`, `prepare`, `bind.exec`,
  `send.pending` (`pg/index.kz`). Trust auth only; the DESIGN's remaining
  protocol work is package work, not toolchain.
- **Phantom lifecycle** — `*Conn<connected!>` issued by `connect`,
  `*Conn<!connected>` consumed by `disconnect`, `*Conn<*>` wildcard on
  `socket` — the machinery for `<connecting!|in_tx!|failed!>` is already
  in use in this file; more states are declaration-side work.
- **Caller-owned fd** — `socket -> i32` + `set-nonblocking` (`index.kz`)
  hand the event loop everything it needs to poll. The pump-side waiters
  queue is orisha's per DESIGN.
- **fd-readiness interest vocabulary** — `koru_std/pump.wait.kz`: a
  pump participant declares blocking interest by return type — `-> i32`
  = fd to poll, `-> i128` = re-poll ns, `-> { fd, wait_ns }` = both.
  The `! wait` contract is the language-level seam the pg suspension
  design names.
- **WouldBlock distinguishable** — `koru-libs/udp/index.kz:145`
  (`if (e == error.WouldBlock) break`) — a `| pending`-style arm on a
  nonblocking read is writable in a proc today.
- **Compile-time SQL transform** — `libs/sqlite3`'s
  `[comptime|transform]pub tor query` (`sqlite3/index.kz:603`) takes the
  `{ SQL }` block source, reads scope bindings, and emits per-site code
  with a `! row` effect arm — the exact mechanism DESIGN wants to
  "lift and exceed" for Parse/Bind/Execute + per-query decode shape.
- **Streaming effect arms** — `std/string-map:each` (`! pair`),
  `std/fs:read-lines` (`! line`), sqlite3 `! row` — a
  `! row`-armed pg tor is a proven shape.
- **Scoped-view spelling** — `string<*@scoped>` is spellable in a tor
  return position (probe: `tor f {} -> string<*@scoped>` shape-checks).
  `col.bytes`' "view valid until `row.next`" contract has a spelled
  form; sqlite3's `<row>` scoped-borrow phantom on `*Statement` is the
  richer precedent (`sqlite3/index.kz:283-299`).
- **Structured errors** — record/variant branch payloads
  (`| err { code, msg, severity }`-shaped arms are ordinary) for 'E'
  frames; `std/string:parse-int` / `std/num` for text-column → typed
  decode at the call site.
- **Config + deadlines** — `std/env` (`get`/`get.or`/`require`),
  `std/time` (`now`, `elapsed`, `sleep-until`) for connect params and
  wait deadlines.
- **Package growth path** — `~part` splitting (string-map/map each+del
  +free precedent), npm `package.json` with `koru.entry` already in
  place, `koru/<name>` namespace resolution via `paths` alias.
- **Hash substrate in Zig procs** — `std/crypto`'s `md5-check`
  (`koru_std/crypto.kz:22`) shows the move: `std.crypto.hash.Md5` inside
  a `~proc`, Koru orchestration outside. Portable to sha256/hmac/pbkdf2.

## missing-blocker (probed or cited absence)

**None found.** Every surface the stated purpose needs either exists
(above) or is absent-in-the-package in a way a proc body or declaration
can carry — see the portable column. No toolchain refusal is standing
between this package and its DESIGN.

## missing-but-portable (absent, workaround shape obvious)

- **md5 / SCRAM auth** — `connect` accepts only AuthenticationOk
  (`code != 0 → "auth method unsupported (non-trust)"`, index.kz). The
  digests are absent as *stdlib surfaces* (`std/crypto` ships only the
  narrow `md5-check` leaf), but a pg-local `~proc` calling
  `std.crypto.hash.Md5` / `Sasl`/`hmac`/`pbkdf2` is the same move
  `crypto.kz` already makes. If Lars wants hashes in std, that's one
  small stdlib commission, not a blocker.
- **Nonblocking/pending codec arm** — `readFull`, `skipRem`,
  `row.next`, `sendAll` treat *any* read/write error as stream end
  (`catch return false`), so on a `set-nonblocking` fd the first EAGAIN
  silently ends the row stream — a real fitness gap vs the
  event-loop-native goal, but the fix is distinguishing
  `error.WouldBlock` into a `| pending`-shaped state inside the existing
  Zig (udp:145 precedent). Package work.
- **Multi-param + binary binds** — `bind.exec` takes one `param: string`.
  N params wants repeated append tors or a record arg (record args are
  ordinary — `std/store:insert` takes `{ key, val }`); binary
  int4/float8 encoding is more proc Zig. Package work.
- **`<in_tx>`/`<failed>` tracking** — 'Z' carries the tx byte; the codec
  doesn't read it and the phantom isn't declared. Both sides exist.
- **Rows > 64 KB** — `rx` is a fixed `[65536]u8`; a growable buffer is
  package work.
- **Cancel / 'X' mid-query, TLS, SASLprep** — not in the stated purpose;
  all proc-level when they come.
- **Per-worker conn pool + `pending_pg` exchange variant** — orisha's
  pump and Response enum, explicitly assigned there by DESIGN.

## Commission recommendation

**Package work — no toolchain commission.** The stated purpose compiles
and runs against today's surface; what remains (nonblocking codec arm,
md5/SCRAM auth, multi-param binds, the `[comptime|transform] query`
lift, `in_tx` tracking, structured 'E' errors, >64KB rows) is ordinary
package implementation against surfaces that already exist. The one
optional stdlib item is a general crypto-digest leaf set
(md5/sha256/hmac) if pg's auth should read `std/crypto:` rather than a
local proc — *stdlib surface* cost class, small. No compiler feature is
needed; the two mechanisms the DESIGN leaned on hardest — comptime
transform and the `! wait` fd-interest contract — already ship.
