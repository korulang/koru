// MIRROR for `std/grid:new`, `std/grid:stored` and `std/grid:sweep`: all three
// declared and used from an imported module rather than the entry file.
//
// The wall asked for this the moment the transforms landed and it earned its
// keep immediately. The first version named the generated write unit in
// `flow.module` — the FILE-derived name (`lib`) — where every cross-module path
// resolves through the module's IMPORT-derived logical name (`app.lib`). It
// failed exactly as 115_018 records for the store:
// `unknown tor 'lib:__grid_write_L8'`.
//
// The entry file collapses those two names into one, so a single-file test
// cannot tell a correct qualifier from a lucky one. 697_001/003 are those
// controls and they were green while this was broken. This is the test that can
// see it.
import app/lib

app/lib:bump() |> app/lib:bump() |> app/lib:total() |> app/lib:show()
