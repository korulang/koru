// PINS: a bare return carrying an obligation auto-discharges even when nobody
// NAMED it.
//
// `abandon(j)` hands back a *Bin<owned!>. `bin.close` is its one void terminal,
// so there is nothing to decide — and the compiler proves it knows, because the
// refusal names the call it declines to make:
//
//   error[KORU030]: Resource 'return of abandon(...)' obligation <owned!> was
//                   not discharged. Call: bin.close
//
// The control is one character. Write `: b` and the identical program compiles,
// auto-discharge inserting `bin.close(b)`. A NAME is the only difference, and a
// name is not information the compiler was missing.
//
// Auto-discharge exists to settle obligations the author did not write down —
// `get(url) | ok r |> print(...)` gets its `close(r)` unasked. A mid-chain
// return is the same situation. The asymmetry is an accident of the mechanism:
// auto_discharge_inserter.zig records an unnamed return as
// `__unbound_return.<event>` and force-marks it not_auto_dischargeable, because
// an unnamed value has no referenceable expression to pass. The machinery to
// mint one already lives next door — cloneContinuationWithReturnBinding
// synthesizes `_auto_N` for `: _` discards.
//
// The `Bin` is an implementation detail of abandoning a `Job`; requiring `: b`
// purely so the next line can close it is ceremony over a value the author
// never asked for.
//
// Found writing koru-examples/downloads, where the natural spelling of a store
// drain is `! discharge item |> cancel(item.p)` and curl's `cancel` hands back
// the batch. The store and the effect arm are both BYSTANDERS: this reproduces
// at top level with neither, which is why the pin lives here and not in 690.
import app/lib/job

app/lib/job:start(): j |> app/lib/job:abandon(j)
