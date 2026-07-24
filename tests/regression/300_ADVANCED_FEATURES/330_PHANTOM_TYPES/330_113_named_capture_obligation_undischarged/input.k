// Pins: a BOUND head obligation must stay enforced when the head acquires a
// CONTINUATION. `light(): lamp` alone is caught (KORU030, "Resource 'lamp'");
// append one void continuation and the same live <lit!> is dropped silently.
//
// The continuation is the only difference between the caught form and this one.
// It is not the bind — named captures are enforced — and not the payload shape:
// a record-field obligation in this very position IS caught (330_096), because
// it seeds per-field under `binding.field` with the not_auto_dischargeable
// marker rather than riding the whole-value return_phantom.
//
// Distinct from 330_097, which pins the opposite end of the chain: an unbound
// TERMINAL invocation whose own return carries an obligation. Here the terminal
// call is void and mints nothing; the leak is the HEAD's obligation, live at
// exit, forgotten as soon as a continuation exists.
//
// Auto-discharge is disabled so the wall is under test rather than the LIFO
// insertion — which, with the flag on, correctly emits the douse for this exact
// program. Per frag-obligation-enforcement-keys-off-return-binding, disable opts
// out of INSERTING, never out of the discard staying visible to enforcement.
import std/io
import app/lantern

app/lantern:light(): lamp |> std/io:print.ln("in the dark")
