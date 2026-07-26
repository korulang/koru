// MIRROR of 690_076_store_indexed_field_read_in_stored: two stores, an indexed
// field read in a `stored` RHS, and a `std/store:query` readback, all inside an
// imported module.
//
// The indexed read has to lower to the SoA column of a store whose home is the
// module, and the query arm has to bind against it — two synthesized names that
// must agree on the same namespace. Split across two exported tors because a
// subflow body is one flow; the entry chains them.
import app/lib

app/lib:run() |> app/lib:show()
