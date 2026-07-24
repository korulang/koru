// Cross-target effect-branch dispatch: the MINIMAL single-void-effect shape.
//
// Producer `ticker` fires one effect op `! tick` exactly once. The consumer
// dispatches it to a handler that records the hit, then `report` prints the
// accumulated count. The Koru FLOW is target-agnostic; only the proc bodies
// differ (input.kz = |zig, input.kjs = |js). Both targets must produce the
// SAME expected.txt — that's the cross-target contract.
//
// Modeled on 140_012 (dispatch) but stripped to one fire, no binding shadow.
pub tor ticker { n: u64 }
! tick u64
pub tor onTick { i: u64 }
pub tor report {}

ticker(n: 1)
! tick i |> onTick(i)
report()
