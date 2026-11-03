# top_words

**One-line pitch**: report the five most frequent words in a text file, ties broken alphabetically.

**State**: pristine-green

## The task

The `tr ' ' '\n' | sort | uniq -c | sort -rn | head` pipeline: count every
word in a text file, then print the top five by frequency. Ties resolve
alphabetically so the report is a total order — the fixture carries two
ties (cat/dog at 4, ant/bee at 3) and one of them straddles the cutoff,
so the tie-break decides what rank 5 even is.

## How Koru does the work

- Counting half is the 820_004 pipeline: `std/fs:read-lines` streams the
  text, `std/regex:scan` `[a-z]+` fires once per word, counts fold into a
  `std/string-map` — plus a `capture` cell for the total.
- `std/string-map:each(m) ! pair { k, v }` drains the table — the tor
  that landed today and unblocked this whole shape. `k` is a borrow into
  the map's owned key bytes, so each `! pair` copies the word into an
  owned `*String<instance!>` (`from-page` + `take`) and `insert` moves
  custody into the `ranked` store's `word` column.
- Hash order is declared unstable, so ranking is **selection by
  max-extraction**, all in flows: `pick` sweeps `ranked` with
  `std/store:query`, tracking the winner in a `best` singleton —
  count desc, ties by `lex-before`. `report` runs
  `std/store:take(ranked[best.row])`; the `| item` branch carries the
  row's fields out, prints, and `std/string:free` discharges the owned
  word's obligation. `top` is a recursive subflow doing it N times.
- `lex-before` is pure Koru — `lex-at` recurses to the first differing
  byte on the `.data` slices, shorter-prefix-first settles equality.
  Spelled by hand because string `<` does not lower (it survives Koru's
  own check and the backend refuses `operator < not allowed for type
  '[]u8'`), and `std/string` has no compare tor. Noted as a surfaced
  constraint, not a pin: the task is green.

Procs are leaves only (`from-page`/`take`/`insert`/`free`, the
regex/map/store chain steps). Ordering, selection, recursion, and
custody are all flows.

## Gap filled

The catalog entry that asked for this. 820_004's README named the
frontier verbatim: "`std/string-map`'s declared surface […] has
no key-iteration, so 'print every distinct word' and 'top-N' cannot
yet be spelled" — `each` closed it (660_034 pins the tor; this entry
proves the *use case*). Beyond 820: the 810 AoC days never rank a
discovered key set, and while 800_006's `rule`-driven drains use `take`'s
`| item` handoff, no entry uses it for *ordered* selection — a query-swept
argmax resolved by a pure-Koru comparator.

## Frontier (if RED)

none — green.

## Output

Corpus totals, then the five winners with ranks — `cat` before `dog` and
`ant` over `bee` are the alphabetical tie-breaks — then the printed
count, which the program computes rather than asserts.
