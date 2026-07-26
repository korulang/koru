// MIRROR of 690_069_store_sweep_row_ordinal: `std/store:sweep` with the
// reserved `row` ordinal, relocated into an imported module.
//
// sweep is the render-bridge shape — a layout cursor over a module's own rows.
// One exported tor per seeding insert because the original writes three
// sequential top-level statements and a subflow body is a single flow; chaining
// inserts with `|>` is a form the corpus never writes, so it is not invented
// here.
import app/lib

app/lib:seed-a() |> app/lib:seed-b() |> app/lib:seed-c() |> app/lib:draw()
