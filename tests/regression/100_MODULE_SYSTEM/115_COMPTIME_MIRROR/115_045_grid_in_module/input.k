// MIRROR for `std/grid:new` and `std/grid:stored`: declared and written from an
// imported module rather than the entry file.
//
// The mirror wall asked for this the moment the transforms landed, and it earned
// its keep immediately — the first version named the generated write unit in
// `flow.module`, the FILE-derived name (`lib`), while every cross-module path
// resolves through the module's IMPORT-derived logical name (`app.lib`). It
// failed exactly as 115_018 records for the store: `unknown tor 'lib:__grid_write_L8'`.
//
// The entry file collapses those two names into one, so a single-file test
// cannot tell a correct qualifier from a lucky one. 697_001 is that control and
// it was green while this was broken. This is the test that can see it.
import app/lib

app/lib:bump() |> app/lib:bump() |> app/lib:overflow()
