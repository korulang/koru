---
type: belief
id: frag-a-demo-that-renders-is-not-a-demo-that-works
provenance: raylib boids, 2026-08-04 — shipped as "boids", verified by screenshot, contained no flocking whatsoever. Lars spotted it in one glance: "very controlled and a bunch of stuff arranged on lines"
ts: 2026-08-04
---

# A demo that renders is not a demo that works — pixels verify the pipeline, never the behaviour (belief)

A boids demo was committed after being checked the way everything else here is
checked: build it, run it, capture the screen, look at the image. The window
opened, 160 amber dots appeared on the right background, the frame loop paced
correctly at 60fps. Every one of those observations was true and the demo was
worthless — there was no flocking in it at all.

The scatter used `(s*71) % 620` and `(s*137) % 440`, which lands on a regular
lattice, and the velocities came from `s%7` and `s%5`, which yields 35 distinct
directions. Nothing read anything else. It was a lattice translating.

## Why the check passed

The screenshot answered "did anything draw", and that had been the live question
for the previous hour — the window really had been black, for a real reason
(koru 697_012, a grid write swallowing its chain tail). Having just fixed a
rendering bug, a picture with dots in it read as success.

**The verification matched the last failure rather than the current claim.** The
claim was "boids". The check was "pixels". Those differ by the entire content of
the word.

## What follows

- **Name the behaviour the artifact is supposed to exhibit, then find the
  observation that would distinguish it from the nearest plausible fake.** For a
  flock that is: do sub-groups form, merge, and split over time? Two captures
  seconds apart answer it; one capture cannot, at any resolution.
- **A single frame is a type-check, not a test.** Anything animated needs at
  least two observations separated in time, because every static property of a
  flock is also a property of a lattice.
- **Freshly-fixed bugs distort the bar.** After a hard debugging session the
  first sign of life reads as completion. That is exactly when to state the
  acceptance criterion out loud, because the relief is doing the judging.

## The sibling failure, same day

`koru/concepts/frag-an-instrument-that-edits-the-specimen-fabricates-defects`
records the inverse from the same session: a probe harness silently rewrote its
INPUT, and six compiler bugs were reported that did not exist. Here the input
was fine and the OUTPUT was inspected too shallowly.

Both are the measurement apparatus reporting success about something other than
the claim. Instruments fail on both ends of the pipe, and neither failure
announces itself — the input case produced confident false positives, this one a
confident false negative about the work remaining.

## Open

Whether anything here can be automated. A checksum oracle works for the koru
ECS benchmark because the workload is deterministic and its answer is a number;
a flock has no natural scalar. The nearest cheap instrument is probably a
clustering statistic over two frames — mean nearest-neighbour distance should
FALL as sub-flocks form, where a lattice holds it constant. Not built, and it
may be more apparatus than a demo deserves.


## The second half: oscillating between failure modes means the FORMULATION is
## wrong, not the constants

Once the flocking was real it was still bad, and Lars named it precisely —
"they seem to EXTREMELY awkwardly clump and jitter". Fixing that took three
attempts, and only the third one was a fix.

The first bug was a genuine sign error in disguise: separation accumulated
`(x_i - x_j)`, which GROWS with distance, so the repulsion was weakest at
contact and strongest at the edge of its own radius. Boids could sit on top of
each other feeling nothing, and the only force they met came as they crossed
the radius, so they oscillated across it. Clumping and jitter were one bug seen
from two sides. Correct is `∝ 1/d`.

Then came the part worth recording. With separation fixed, the flock strung
into evenly-spaced diagonal filaments. Reduce separation and raise cohesion: it
collapsed into a single dense ball. **Two opposite failure modes, reachable by
nudging the same two numbers in opposite directions, with nothing good in
between.**

That is the signature of a formulation problem, and it has a name here: the
three rules produce vectors with wildly different NATURAL MAGNITUDES —
cohesion is a distance (up to the perception radius, ~52), alignment is a
velocity difference (~4), separation is a sum of reciprocals (well under 1).
Weighting the raw vectors means the weights are not comparable to each other,
so there is no stable region to tune toward; every adjustment trades one
pathology for its opposite.

Reynolds normalises each steering vector to unit length BEFORE weighting. Then
a weight is literally the contribution, the three are commensurable, and the
first set of numbers tried worked. The structural change cost less than the
tuning did.

**The test, and it is cheap:** if two adjustments in opposite directions
produce two different pathologies and no improvement, stop adjusting. Something
in the model is not comparable to something else it is being summed with. This
generalises well past flocking — any weighted sum of terms with unlike units
has it, which includes most cost models and most heuristics.

## What it settles into, and why that is not a bug

The flock reaches a steady state: a few large groups, moving coherently,
visually samey after a minute. That is the model behaving correctly rather than
a defect. Alignment is a consensus process, and consensus over a connected
neighbourhood graph with no noise converges to global order — this is the
Vicsek model at zero noise, where the ordered phase is the only phase.

The standard remedy is the standard control parameter: a small random
perturbation added per boid per frame, which is exactly what Vicsek varies to
move the system between ordered and disordered. Obstacles or a predator do the
same job with more structure. Not added here; the demo exists to show the three
rules working, and it does.