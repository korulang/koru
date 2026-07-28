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
// The consumer is a SUBFLOW on purpose. A top-level consumer inlines the
// effectful call and never synthesizes a Handlers struct at all, so it dodges
// this; a subflow always synthesizes one and reaches it. That is also why every
// effect-branch test in the corpus passes — 400_105's `*Resource` is declared
// in the file that handles it, and the top-level sites inline.
//
// The payload's home is the module that DECLARES the event: that is where the
// author wrote the bare name and the only scope it ever resolved in.
//
// Found in koru-examples/downloads, where a `! sweep` arm calls curl's `poll`
// and its `! progress *Progress` / `! finished *Response` arms land in the
// app's module. Reproduced here with no curl.
import std/io
import app/lib/pulse

tor drive { k: i64 }
drive = app/lib/pulse:pulse(k)
! tick b |> std/io:print.ln("tick {{ b.n:d }}")
| done |> _

drive(k: 2)
