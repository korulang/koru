// The contract facet: a public event signature and no host body, in a `.k`.
// Its implementation lives in the sibling `contract.kz`, and the two files —
// same stem, different Koru extension — are ONE module named `contract`.
//
// This is the layout that keeps `~` out of the code a reader reads: everything
// declarative here, with no host language to switch away from, and the Zig
// confined to the companion.

pub tor compute { x: u32 } -> u32
