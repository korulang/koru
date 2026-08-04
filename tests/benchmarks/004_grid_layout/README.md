# 004_grid_layout — `[layout(row)]` cuts both ways

Two programs, identical arithmetic and identical output, differing only in
whether `std/grid:new` carries `[layout(row)]`. They exist to keep the
**tradeoff** honest, because a benchmark that only measured the winning
direction would turn a trade into a recommendation.

## The trade

A grid's cells are stored one array per field (`column`, the default) or one
record per cell (`row`).

- A **scatter** touches many fields of ONE cell at a computed index. Column
  layout pays one cache line per field; row layout pays one in total.
- A **sweep** touches ONE field of every cell. Column layout reads
  contiguously and vectorises; row layout strides by the whole record and
  cannot.

Both effects are large, and the sign depends entirely on the access shape.

## Measured

Sweep-dominated, this directory: nine `i64` fields, 1,000,000 cells, 400 sweeps
reading one field. Same total (`199999800000000`) from both.

| layout | time |
|---|---:|
| column | 0.04 s |
| **row** | **0.44 s** |

Column wins by ~11x.

Scatter-dominated, `003_ecs_reactive` boids: 100k boids scattering seven fields
into a 32,768-cell grid, 100 frames, interleaved, same checksum `592303452`.

| layout | time |
|---|---:|
| column | 98.7 ms |
| **row** | **91.5 ms** |

Row wins by ~7%.

## Why this is a declaration and not an inference (yet)

The store design already rules that "layout is the closure of the queries", and
the compiler genuinely has the information to decide: a grid's columns are
declared rather than allocated, the transform already walks every access site
in the program, and no pointer to a column escapes — so layout is unobservable
to the source and free to change.

The annotation lands first so the choice is available and MEASURABLE before any
inference is written, and it stays afterwards as the override. These two numbers
are what an inference pass would have to beat.

Note that boids wants BOTH answers — its scatter is row-shaped and its resolve
sweep is column-shaped — so a per-table toggle can only ever trade one against
the other. The real form of "closure of the queries" is clustering co-accessed
fields, not one flag per table.

## Run

```sh
sh run.sh
```

Correctness is the two totals agreeing; the timing is the point.
