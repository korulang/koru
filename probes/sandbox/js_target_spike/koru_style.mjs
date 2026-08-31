// Koru-LOWERED style: faithful to the emitted Zig shapes, transliterated to JS.
//   - effect branch `! step`  -> handler object passed as a param, called directly
//   - terminal branches       -> tagged-union return `{ tag, ... }`
//   - labeled-loop restart     -> `while (r.tag === 'restart') { ... }`
//   - phantom resource + auto-discharge -> acquire union + injected release call
//
// Modeled on 400_081 (ramp pump + restart loop) and 400_061 (acquire/discharge).
// CHUNK controls how often a terminal union is allocated (per CHUNK iterations);
// the `step` effect fires every iteration regardless.

let RELEASE_SINK = 0; // observable, identical work in both versions

const resource_acquire = {
  handler(input) {
    // like create_resource -> | created *Resource<allocated!>
    return { tag: 'created', created: { n: input.n, live: true } };
  },
};

const resource_release = {
  // non-memory discharge body: does real, observable work (not a GC no-op)
  handler(input) {
    input.res.live = false;
    RELEASE_SINK += input.res.n & 1;
  },
};

const ramp_event = {
  handler(input, H) {
    let i = input.start;
    const end = Math.min(input.start + input.chunk, input.n);
    for (; i < end; i++) {
      H.step(i); // effect-branch fire: direct call into the handler object
    }
    if (i < input.n) return { tag: 'restart', start: i }; // union alloc per chunk
    return { tag: 'done', total: i };
  },
};

export function flow0(n, chunk) {
  // acquire (phantom obligation introduced here)
  const acq = resource_acquire.handler({ n });
  const res = acq.created;

  // consumer-local the effect handler accumulates into (faithful closure capture)
  let acc = 0;
  const Handlers_0 = {
    step(v) {
      acc = (acc + ((v * v) ^ (v + 1))) | 0;
    },
  };

  let start = 0;
  let r = ramp_event.handler({ start, n, chunk }, Handlers_0);
  while (r.tag === 'restart') {
    start = r.start;
    r = ramp_event.handler({ start, n, chunk }, Handlers_0);
  }

  // injected auto-discharge for the [allocated!] obligation
  resource_release.handler({ res });

  return acc;
}

export const sink = () => RELEASE_SINK;
