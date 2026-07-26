// MIRROR of 690_014_store_stripe_scan_firing: `std/store:stripe` firing a
// watch across the corpus, inside an imported module.
//
// stripe runs the compiled standing rules once on demand rather than on a
// write, so it reaches the same synthesized write-subflow by a second route.
// A namespace that satisfies the write path but not the scan path shows up
// here and nowhere else.
import app/lib

app/lib:write() |> app/lib:fire()
