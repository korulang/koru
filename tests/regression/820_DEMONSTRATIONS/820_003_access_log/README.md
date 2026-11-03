# access_log

**One-line pitch**: parse a web server's access log and print a per-endpoint traffic report.

**State**: pristine-green

## The task

Given an access log (`METHOD PATH STATUS BYTES` per line), report total
requests, total bytes served, error and POST counts, then per-endpoint hit
and byte totals in the order endpoints first appear. Awk's home turf —
the task people reach for a shell one-liner or a small script to do.

## How Koru does the work

- `std/fs:read-lines` streams the log; `std/regex:match` destructures each
  line into named groups `{ m, p, st: i64, by: i64 }` — the record schema is
  the pattern.
- A singleton `std/store` (`totals`) folds the global aggregates, including
  branchless counters via `@intFromBool(st >= 500)` and `m == "POST"`.
- Group-by-key is spelled directly: a `std/string-map` maps each path to its
  row handle in an `eps` store whose `label` column owns the path as
  `*std/string:String<instance!>` (`from-page` + `take` mint it; `insert`
  takes custody). Repeat hits update through `eps[r].<field>`; first sights
  insert and register the handle in the map.
- The report is a `std/store:query` sweep over `eps` in join order — which is
  also the first-seen order the task wants, for free.

No host leaves: the program is a pure `.k`. Every composite — the line
record, the aggregate fold, the keyed row table — is carried by Koru events,
flows, stores, and obligations (the owned-string column's custody is
compiler-tracked).

## Gap filled

The catalog's first proof: group-by-key aggregation over parsed records.
The AoC climb parses lines (day 2's regex dims, day 16's property map) but
never groups *records by a discovered key*; the 800 organ stresses stores
but never against a text source. This entry joins `read-lines` + regex
records + `string-map` keyed aggregation + an owned-column store + a join
-order sweep — the canonical log-analysis shape — in one program.

One friction surfaced while building (not a wall): `store[key: v]` keyed
addressing (`pool[id: 7]`, `store[key]` decl) is aspirational — `690_349`
pins its refusal — so key-to-row lookup goes through `std/string-map` of
path → row handle. That detour is honest and small, but a store whose
`key:` column could be an owned string would retire it.

## Frontier

none — green

## Output

`expected.txt`: one summary line (requests, bytes, errors, posts), then one
line per distinct endpoint (hits, bytes) in first-seen order.
