// Phase 3 rule 2 setup: the .k contract declares the canonical public
// event. The sibling .kz must NOT also declare it as public — the public
// surface lives in .k exclusively when a .k companion exists.

pub tor compute { x: u32 } -> u32
