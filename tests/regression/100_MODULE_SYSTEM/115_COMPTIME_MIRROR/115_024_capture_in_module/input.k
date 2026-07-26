// MIRROR of 670_010_capture_under_flow_head: a `capture` fold relocated into an
// imported module.
//
// capture is invoked BARE as the keyword it is, and it rewrites its containing
// flow rather than appending a declaration — the site-local class. It is also
// the most-used transform in the corpus after io, so a boundary fault here
// would reach nearly every module anyone writes.
import app/lib

app/lib:run()
