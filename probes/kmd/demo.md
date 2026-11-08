
# The Document Is The Program

Prose is prose — **bold**, `code`, lists, quotes. The only sigil
is `~` at column 0: that line is Koru, same rules as `.kz`.

| construct   | emits        |
|-------------|--------------|
| table rows  | literal text |
| `~` lines   | koru calls   |

```koru
~import std/io
std/io:print "fences stay literal, sigils included"
```

## A computed section

- stat row 1: computed
- stat row 2: computed
- stat row 3: computed

## Inline calls

generated 2026-10-25 by a doc that is also a program.


---
*end of document*
