# towers_of_hanoi

**One-line pitch**: print the move-by-move solution to the classic Towers of
Hanoi puzzle and verify the move count.

**State**: pristine-green

## The task

Towers of Hanoi (Rosetta Code task): three pegs, a stack of disks sorted by
size; move the whole stack peg-to-peg one disk at a time without placing a
larger disk on a smaller one. The published 3-disk solution is a fixed
7-move trace (2³ − 1), which this test pins end to end.

## How Koru does the work

One tor, `hanoi { n, from, to, spare } -> i64`, implemented as a pure
subflow. The `if` splits the base case (`-> 0`) from the recursive case,
which chains three steps: recurse n−1 to the spare peg, print the disk-n
move through `std/io:print.ln`, recurse n−1 to the target peg — non-tail
tree recursion with an interleaved effect, each call producing its move
count so the arm produces `a + 1 + b`. No procs, no host code, no capture
cells; the only leaf is the print transform. The program counts its own
moves, so the oracle's "7 moves total" is computed, not asserted.

## Gap filled

First entry in the 820 proof catalog. The AoC corpus proves line-folds
over input files; this entry proves tree recursion with sequenced effects —
the `320_124` pin proved the produce shape minimal as `fib(10)`, this is the
same spine as a user-visible task with a published trace.

## Frontier (if RED)

none — green.

## Output

Header, the 7 published moves for 3 disks (A→C via B), then the computed
move count.
