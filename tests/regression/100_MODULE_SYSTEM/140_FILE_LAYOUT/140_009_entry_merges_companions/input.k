// Contract: the public events live here, in the pure .k facet. The entry
// being compiled is input.kz, but `koruc input.kz` must merge THIS sibling
// (same stem `input`) so these events are in scope for the flow + procs.
pub event compute { x: u32 }
| done u32

pub event show { v: u32 }
