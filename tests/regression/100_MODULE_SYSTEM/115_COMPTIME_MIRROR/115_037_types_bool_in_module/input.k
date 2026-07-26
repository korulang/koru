// MIRROR of 030_103_bool_type: `~bool` declaring a nominal boolean inside an
// imported .kz module, used as the parameter of a branching tor there.
//
// Completes the nominal-primitive set alongside 115_031 and 115_032. This one
// carries branches, so the minted type has to survive into branch dispatch and
// not just a parameter position.
import app/lib

app/lib:run()
