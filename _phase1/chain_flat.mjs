// chain_flat.mjs — the absolute lower bound: the SAME depth-3 nested
// computation written as plain nested loops with direct function calls and no
// dispatch abstraction whatsoever. This is what a perf-conscious JS dev writes
// when they don't reach for events at all. It is the "what does the dispatch
// abstraction cost vs nothing" reference floor.
//
// Result: counter === n^3, identical to the static and dynamic versions.

const n = parseInt(process.argv[2] || "10");
let counter = 0;

function inc() {
  counter++;
}

function leaf(m) {
  for (let i = 0; i < m; i++) inc();
}

function mid(m) {
  for (let i = 0; i < m; i++) leaf(n);
}

function outer(m) {
  for (let i = 0; i < m; i++) mid(n);
}

function report() {
  console.log("counter = " + counter);
}

outer(n);
report();
