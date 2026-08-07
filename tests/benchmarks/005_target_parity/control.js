// The CEILING for the JavaScript arm: the same loop a person would write by
// hand, over the same data layout Koru emits.
//
// This is deliberately not a fair-fight opponent — it is a bound. Koru's
// emitted JavaScript cannot beat it, and how close it gets is the only
// interesting number in this directory. A Zig-versus-JS gap tells you
// JavaScript is slower than native, which nobody needed a benchmark for.
//
// The four flat arrays are not a simplification of what Koru emits: the
// emitted store cell IS four flat arrays plus a scalar `len`, so the layouts
// are identical and the comparison isolates the LOWERING rather than the data
// structure.
const N = 4096;
const FRAMES = 50000;

const px = new Array(N).fill(0);
const vx = new Array(N).fill(0);
const py = new Array(N).fill(0);
const vy = new Array(N).fill(0);

for (let i = 0; i < N; i++) {
  px[i] = i;
  vx[i] = 1;
  py[i] = i;
  vy[i] = 2;
}

for (let f = 0; f < FRAMES; f++) {
  for (let i = 0; i < N; i++) {
    px[i] = px[i] + vx[i];
    py[i] = py[i] + vy[i];
  }
}

let sum = 0;
for (let i = 0; i < N; i++) sum = sum + px[i];

process.stdout.write("checksum " + sum + "\n");
