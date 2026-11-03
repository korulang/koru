# kv_protocol

**One-line pitch**: serve a scripted line-protocol session — AUTH, SET/GET/DEL/INCR, QUIT — the redis-cli task.

**State**: pristine-green

## The task

A tiny key-value server that speaks a text protocol, run over a recorded
client session. Each input line is one command; the server answers with one
reply line — `PONG`, `OK`, `"value"`, `(nil)`, `(integer) n`, or an `ERR`.
KV verbs are refused until `AUTH` unlocks the session, and `QUIT` closes
it: lines that arrive after close get no reply at all.

## How Koru does the work

Three pieces of structure carry the program, no procs:

- `session` — a singleton `std/store` row holding the connection stage
  (anonymous → authed → closed). Every command arm checks the stage; the
  outer `! line` gate drops post-`QUIT` lines silently, the way a closed
  socket stops answering.
- `kv` — a `std/store` whose rows own their key and value strings
  (`*String<instance!>` columns). SET moves custody in on insert and on
  overwrite (`stored` reissues custody, freeing the old value); DEL takes
  the row and the caller frees both fields. The obligations are the
  protocol's memory discipline.
- `index` — a `std/string-map` from key text to row handle. DEL parks the
  entry at -1 because row handles are generation-stable across swap-remove
  (690_092) but a stale-handle *read* traps — absence is spelled as a dead
  handle, and readers check the sign before dereferencing.

Dispatch is one `std/regex:match` per line: each command is a pattern arm
whose body is a flow, including the INCR read-modify-write
(`parse-int` → `from-int` → custody hand-off → `stored`).

## Gap filled

The catalog's first five proofs are all batch transforms (puzzle, checksum,
log report, word count, mail merge). This is the first **stateful,
turn-taking** entry: request → reply against a session that mutates between
commands, with an auth state machine and connection lifecycle.

## Frontier

none — green. One rough edge surfaced, not blocking: `string-map` has no
delete verb, so DEL's "remove the index entry" is spelled as a `-1` tombstone
rather than a real removal. A `std/string-map:del` would be the pristine
spelling.

## Output

21 replies for a 23-line session — one per command until `QUIT` (`bye`),
then silence for the two post-close lines.
