// SUBFLOW-IMPLEMENTED EFFECTS, minimal case (pure .k, no proc) — the subflow
// sibling of 400_070. `ping` declares one void-ish effect arm and NO terminal
// branches; its impl is a SUBFLOW that FIRES the arm by CALLING it, exactly as
// a `proc` body calls `pong(msg)` today. Ruled 2026-07-02: firing introduces
// NO new grammar — inside the impl of the declaring event, the event's own
// arms are callable, and everything downstream reuses the established subflow
// forms. Here that's the simplest one: the impl body is a plain call head
// (`ping = pong(x)`, same shape as `run = step()` in 240).
//
// The prize over the proc version: the firing is now a KORU act the flow
// checker can see, instead of an opaque host call trusted "unsafe"-style.
import std/io

pub tor ping { x: i64 }
! pong i64

ping = pong(x)

ping(x: 41)
! pong reply |> std/io:print.ln("{{ reply + 1:d }}")
