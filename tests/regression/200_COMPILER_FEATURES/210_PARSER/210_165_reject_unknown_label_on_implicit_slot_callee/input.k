// An explicit `label: value` names a parameter. A callee that declares an
// implicit slot (`if { expr: Expression }`) does not make up for a label that
// names nothing — `cond` is not a parameter of `if`, and saying so is the
// frontend's job.
//
// The bare form `if(true)` is the canonical spelling and the implicit slot
// absorbs it (219 call sites across the suite). What this pins is the other
// side: the slot excuses BARE arguments, never a wrong label.
import std/io

if(cond: true)
  | then |> std/io:print.ln("then branch")
  | else |> std/io:print.ln("else branch")
