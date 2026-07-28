// PINS: an effect branch's PAYLOAD TYPE is qualified when the consumer sits in
// a different module than the event.
//
// `pulse` declares `! tick *Beat`, and `Beat` belongs to app/lib/pulse. The
// consumer here is the main module, so the synthesized Handlers struct emits
//
//     fn tick(b: *Beat) void { … }
//
// with the type written verbatim — and `Beat` is not in the consumer's scope:
//
//     error: use of undeclared identifier 'Beat'
//
// Same-module consumers work, which is why every effect-branch test in the
// corpus passes: 400_105's `*Resource` is declared in the file that handles it.
// The payload type needs the host path the emitter already computes for every
// other cross-module reference.
//
// Found in koru-examples/downloads, where a `! sweep` arm calls curl's `poll`
// and its `! progress *Progress` / `! finished *Response` arms land in the
// app's module. Reproduced here with no curl.
import std/io
import app/lib/pulse

app/lib/pulse:pulse(k: 2)
! tick b |> std/io:print.ln("tick {{ b.n:d }}")
| done |> _
