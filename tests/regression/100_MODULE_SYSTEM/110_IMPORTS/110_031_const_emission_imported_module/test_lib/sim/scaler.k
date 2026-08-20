// The flow implementation `bump` references `SCALE` from this module's const
// block. That reference only resolves inside this module's emitted struct.
// The fix: a cross-module call resolves through the module's emitted handler
// (consts in scope) instead of splicing the flow body into the caller's flow.

const { SCALE: 3 }

pub tor bump { v: i32 } -> i32

bump -> v + SCALE