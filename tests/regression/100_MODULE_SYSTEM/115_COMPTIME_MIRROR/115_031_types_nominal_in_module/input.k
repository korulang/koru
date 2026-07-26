// MIRROR of 030_142_nominal_in_pipeline: `~string` and `~int` declaring nominal
// primitive types inside an imported .kz module, used as tor parameter types
// there.
//
// Both are BARE keyword transforms, and the types they mint are registry
// entries that a call site is checked against — so this pins that the registry
// entry a module declares is the one its own call site resolves. The
// original carries no expected.txt because it prints through the host's stderr;
// this one asserts that output anyway — the harness captures stderr, and a
// mirror that only checked for a clean run would score 115_036's silent wrong
// answer as green.
import app/lib

app/lib:run()
