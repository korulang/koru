class PRNG {
    constructor(seed) { this.state = BigInt(seed); }
    next(max) {
        this.state = (this.state * 6364136223846793005n + 1442695040888963407n) & 0xFFFFFFFFFFFFFFFFn;
        return Number((this.state >> 33n) % BigInt(max));
    }
}

function add_handler(a, b) { return a + b; }
function mul_handler(a, b) { return a * b; }
function sub_handler(a, b) { return a - b; }
function div_handler(a, b) { return b !== 0 ? Math.trunc(a / b) : 0; }

const handlers = { add: add_handler, mul: mul_handler, sub: sub_handler, div: div_handler };
const events = ["add", "mul", "sub", "div"];

function dispatch(eventName, a, b) {
    const handler = handlers[eventName];
    if (handler) return handler(a, b);
    throw new Error("Unknown event");
}

const ITERATIONS = 10_000_000;
const prng = new PRNG(12345);

const start = process.hrtime.bigint();

let sum = 0;
for (let i = 0; i < ITERATIONS; i++) {
    const eventIdx = prng.next(4);
    const a = prng.next(100) + 1;
    const b = prng.next(100) + 1;
    sum += dispatch(events[eventIdx], a, b);
}

const end = process.hrtime.bigint();
const elapsed_ms = Number(end - start) / 1_000_000;
const ops_per_sec = ITERATIONS / (Number(end - start) / 1_000_000_000);

console.log("HONEST Node: " + elapsed_ms.toFixed(2) + "ms, " + Math.round(ops_per_sec) + " ops/sec, sum=" + sum);
