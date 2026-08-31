// IDIOMATIC JS: the same computation a competent JS dev would write by hand.
// Identical arithmetic and identical resource-release work as koru_style.mjs,
// but with the natural control-flow shape: a flat loop, no per-iteration
// objects, no handler indirection, try/finally for the resource.

let RELEASE_SINK = 0;

export function flow0(n, _chunk) {
  const res = { n, live: true };
  let acc = 0;
  try {
    for (let i = 0; i < n; i++) {
      acc = (acc + ((i * i) ^ (i + 1))) | 0;
    }
  } finally {
    // identical release work to the Koru-style discharge
    res.live = false;
    RELEASE_SINK += res.n & 1;
  }
  return acc;
}

export const sink = () => RELEASE_SINK;
