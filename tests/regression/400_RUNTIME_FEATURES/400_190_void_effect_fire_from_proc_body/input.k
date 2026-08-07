// A VOID (payloadless) effect op fired from a proc body: `ready()` carries
// nothing, so the spliced arm binds nothing — the JS emitter must not mint a
// payload const with an empty right-hand side (`const _auto_N = ;`).
// 400_110 is this shape WITH a payload; the payloadless twin is the one the
// binding paths only meet here. Cross-target: both lanes print the same.
pub tor boot {}
! ready
pub tor report {}

boot()
! ready |> report()
