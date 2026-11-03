# base64

**One-line pitch**: encode and decode text in base64 — the `base64` command's job, both directions, plus a self-checking roundtrip.

**State**: pristine-green

## The task

Base64 (RFC 4648): pack every 3 bytes of input into 4 printable
characters so binary data survives text channels. The program encodes
and decodes the RFC's seven published §10 vectors in both directions
(`""`, `f`, `fo`, … `foobar`), then encodes a payload, decodes its own
output, and reports whether it got the payload back.

## How Koru does the work

- `encode` / `decode` are capture+`for` state machines: `encode` packs
  bytes into a 24-bit accumulator and flushes a group every third char
  (the tail left-justifies and pads with `=`); `decode` accumulates a
  bit stream, emits a byte every time 8+ bits collect, and keeps the
  accumulator masked so it cannot overflow. One `captured` write per
  `! each` arm — the branch picks which cell value lands.
- The alphabet is arithmetic in producing subflows (`quad.char`,
  `un.sextet`): no tables, no lookup procs.
- The output buffers are two owned `*String` columns on one store row,
  borrowed through `! query` — the mail_merge ferry, because proc-effect
  arms see module scope only. Teardown frees both.
- The roundtrip's produced encoding crosses `*String → string` through
  `fmt.blk` + `split(sep: "")` (split's documented whole-slice path);
  `! piece` binds the unqualified `string` `for` accepts.
- The verdict is computed: `len` + `contains` on the decoded buffer.
  Procs are std leaves only (append-char, clear, len, contains, print,
  fmt, split).

## Gap filled

First implemented codec. The catalog verifies checksums (820_002
consumes `crc32`) but nothing encodes/decodes a byte format in Koru
structure — no published-vector codec exists in 820, 810, or 800.
This proves bit-packing, alphabet mapping, padding, and a verified
end-to-end roundtrip in pure `.k`.

## Frontier (if RED)

None — green. Friction worth recording for the next contestant:

- `std/string:detach` yields an owned `string` nothing can dispose —
  `std/io:free` discharges only `<allocated!>`-labeled slices, so a
  detached buffer trips the runtime leak check. The `*String → string`
  read-out that survives is `fmt.blk` → `split("")`.
- `for` iterates only unqualified `string` (`string<*>`, `*String`,
  `string<allocated!>` are all refused — KORU030).
- Two sequential `captured` writes inside one `! each` arm did not
  behave as ordered cell updates — spell it as one write per arm under
  exclusive branches.
- An owned `*String` column requires `capacity:` > 1 on the store
  (KORU161); the singleton tier is scalar-only.
- `| then`/`| else` arms start on their own lines — same-line arms
  after `= if(...)` hit PARSE001.

## Output

`expected.txt`: the seven RFC 4648 §10 encode checks, the six decode
checks, then `roundtrip MATCH:` with the recovered payload.
