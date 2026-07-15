// PIN: outer resource discharged inside the ! each body.
// Even with a single-iteration loop (0..1), the body is a repeating scope
// boundary — discharging there violates the @scope rule.
// Austral rule: "a linear value defined outside a loop cannot appear in the loop body."
//
// Grounding:
//   Legal form (discharge in | done): 330_044_for_manual_done_ok/input.kz:3-6
//   Illegal form (discharge in ! each): 330_045_for_manual_each_error/input.kz:3-6
//     (330_045 uses 0..3; this test uses 0..1 to isolate the scope issue from count)
//   for + each + done structure: 330_032_nested_for_scopes/input.kz:4-9
//   KORU032 message: "Cannot discharge outer-scope resource inside @scope boundary"
import std/control
import app/fs
app/fs:open(path: "outer.txt"): outer_f |> for(0..1)
    ! each _ |> app/fs:close(file: outer_f)  // ERROR: outer_f is in @scope, body runs once but COULD run N times
    | done |> _
