// MIRROR of 010_055_bare_import: the same `std/io:print.ln` invocation, moved
// out of the entry file and into an imported module.
//
// One variable changes between the two tests — which file the transform's
// invocation lives in. `io:print.ln` is a SITE-LOCAL transform: it rewrites its
// own invocation and synthesizes no declaration that anything else refers to,
// so it has no namespace to get wrong. This is the control arm of the mirror
// wall: if a site-local transform were to break here, the fault would be in the
// module machinery rather than in any library's name-minting.
import app/lib

app/lib:run()
