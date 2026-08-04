---
type: belief
id: frag-a-forced-workaround-becomes-the-house-style
provenance: raylib boids, 2026-08-04 — Lars read the finished demo and asked "are we even USING the store at all here? it just looks like a bunch of for-loops to me". It was. Three of its five passes had no reason to be loops
ts: 2026-08-04
---

# A workaround forced in one place becomes the style everywhere, including where nothing forces it (belief)

The boids demo needed two things Koru could not do: draw from a store sweep (the
frame borrow does not survive into one, koru `690_252`) and pipe anything after
a grid write (koru `697_012`). Both are real, both are pinned.

Working around them produced a counted `for` loop over a positional grid. That
shape was necessary for the draw pass and for the O(N^2) neighbour gather, which
needs two indices at once and therefore cannot be a sweep at all.

**Then every other pass got written the same way.** Clearing the accumulators,
normalising the steering vectors, and applying them are all strictly per-cell,
touch no borrow, and need no index. `std/grid:sweep` handles them exactly, has
handled them since the grid landed, and is pinned green for the writes-its-own-
cell shape. Three of five passes were loops for no reason but momentum.

Nobody decided that. The first workaround set a local idiom and the rest of the
file matched it, which is what files do.

## Why it is worth catching

The cost is not aesthetic. A reader — Lars, in one glance — could not tell what
the program was demonstrating, because the distinctive constructs were absent
from a file whose entire purpose was to exercise them. **A demo written around
the walls stops being evidence about the language and becomes evidence about the
walls**, and it does not say which it is.

There is also a measurement version of the same trap: had this shipped, the next
person to ask "how expressive is the grid surface" would have read this file and
concluded "you write loops", which is false and would have been sourced from us.

## What follows

- **After working around a wall, re-derive every OTHER site from scratch.** The
  question is not "does this match the file" but "would I write it this way in a
  file where the wall did not exist". The blast radius of a workaround is
  whatever the author's consistency instinct reaches.
- **Count your constructs before publishing a demo.** `grep -oE 'std/[a-z]+:[a-z]+'
  | sort | uniq -c` took one command and said `grid:new 1, grid:stored 7` and
  nothing else. A demo of a data surface that names two verbs is not a demo.
- **The sibling in koru is
  [[frag-a-corpus-exercises-its-authors-idioms]]**, which is the same drift at
  corpus scale and cost a correctness bug there (`697_012` survived because
  every grid test writes in statements). Here it cost legibility. Same
  mechanism, different blast radius: an idiom nobody chose, propagating because
  matching the surrounding code always looks like the careful move.

## Open

Whether the remaining loops are really irreducible. The gather genuinely needs
two simultaneous indices. The draw genuinely needs the frame borrow. But the
SCATTER pass only needs each cell's own index, and a sweep does not offer one —
`[ordinal]` exists on a store query and has no grid equivalent. That may be a
real gap in the grid surface rather than a fact about loops.
