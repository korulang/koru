// MIRROR of 030_142_nominal_in_pipeline: `~string` and `~int` declaring nominal
// primitive types inside an imported .kz module, used as tor parameter types
// there.
//
// Both are BARE keyword transforms, and the types they mint are registry
// entries that a call site is checked against — so this pins that the registry
// entry a module declares is the one its own call site resolves. No
// expected.txt: the original prints via the host's stderr, so compile-and-run
// is the pin, matching its convention.
import app/lib

app/lib:run()
