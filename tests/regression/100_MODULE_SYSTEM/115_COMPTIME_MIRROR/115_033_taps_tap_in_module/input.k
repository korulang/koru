// MIRROR of 330_042_metatype_binding_scope: `tap` relocated into an imported
// .kz module, tapping a tor declared in that same module.
//
// tap is the most invasive transform on the wall: it walks the whole program
// finding matching transitions and WRAPS their continuations, then erases
// itself. Nothing else here rewrites code it did not appear next to, so this is
// the arm that says whether a program-wide rewrite is anchored to the tap's own
// module or to the entry.
import app/lib

app/lib:run()
