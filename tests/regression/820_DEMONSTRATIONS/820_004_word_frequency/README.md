# word_frequency

**One-line pitch**: count how often each tracked word appears in a text file, plus corpus totals.

**State**: pristine-green

## The task

Point the program at a text file; it counts every word, reports how often
each tracked keyword occurs (0 when the text never uses it), and prints the
total and distinct word counts — the keyword-density half of a
word-frequency tool, the thing `grep -o | sort | uniq -c` does in one pass.

## How Koru does the work

`std/fs:read-lines` streams the file as an `! line` effect; inside each
line, `std/regex:scan` `[a-z]+` fires `!` once per word — tokenization IS
the effect stream, so punctuation never becomes a token. Every word folds
into a `std/string-map` (`get` → `set` c+1, `missing` → `set` 1), the
running word total rides a `capture`/`captured` fold, and the map's
`<map!>` obligation crosses both nested effect streams to discharge at
`free` in the report's `| done`. The tracked vocabulary is enumerated by a
second `scan` over a literal, so watchlist order is the report order. Pure
`.k`; procs are std leaves only.

## Gap filled

First text-statistics entry — no such use case existed in any
catalog. 810's string days fold per-line answers out of token streams but
never build a frequency map; 800 stresses feature combinations, not use
cases. This proves the pipeline streaming-tokenizer → hash-map histogram →
deterministically-ordered report end to end.

## Frontier

none — green. Noted for the next contestant, not a pin: `std/string-map`'s
declared surface is six events (`new/set/get/contains/count/free`) with no
key-iteration, so "print every distinct word" and "top-N" cannot yet be
spelled from the map — this entry reports a fixed watchlist, which is the
use case it proves.

## Output

`words: 62`, `distinct: 36`, then eight tracked words with counts; `to`
prints `0` through the `| missing` arm (the text never uses it).
