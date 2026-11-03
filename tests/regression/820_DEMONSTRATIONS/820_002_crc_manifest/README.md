# crc_manifest

**One-line pitch**: verify a `path crc32` manifest against real files — the `cksum -c` task.

**State**: pristine-green

## The task

A manifest lists a file path and the CRC-32 its contents should have
(one claim per line). For each entry the program reads the named file,
reconstructs its bytes, checksums them, and prints a per-entry verdict —
`OK`, `FAILED got … want …`, or `UNREADABLE` — then a tally. The fixture
deliberately carries one corrupted claim and one missing file so all
three verdicts fire.

## How Koru does the work

- `std/fs:read-lines` streams the manifest; a `capture` cell tallies the
  verdicts across its `! line` effect arm.
- `std/regex:match` with a named-group pattern is the line's schema —
  `{ name: string, want: usize }` destructures the claim at the splice.
- `verify` is a pure-subflow tor: a second nested `read-lines` streams the
  payload into an owned `String` (`from-page` → `take` gives
  `*String<instance!>`, appended per line), `std/compress:crc32` checksums
  the buffer's `data` slice, `free` discharges the obligation exactly once
  per outcome, and `| captured` maps to the `ok` / `mismatch` /
  `unreadable` branches via `if`/`=>` — no proc anywhere in the program.

## Gap filled

First `820_DEMONSTRATIONS` entry. Codec lane: the catalogs had gzip *emission*
pins (643_00x) but no checksum-*verification* consumer task — nothing
drove `crc32` against external data through nested file effects with an
owned accumulator. `810_081` (AoC day 8) counts escape bytes but reads
only one file and owns nothing.

## Frontier

None — green. One notable constraint surfaced while writing it: `++` on
strings is comptime-only, so runtime path building wants the `String`
handle API (which is what the proof uses anyway for accumulation).

## Output

`expected.txt`: three `OK` verdicts, one `FAILED got/want`, one
`UNREADABLE`, then `3 ok, 2 bad`.
