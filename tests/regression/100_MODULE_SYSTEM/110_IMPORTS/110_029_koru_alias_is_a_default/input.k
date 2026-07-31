// Pins that `koru` is a DEFAULT import alias, needing no koru.json and no
// `std/compiler:paths` declaration — the same standing `std` and `app` have.
//
// The distinction this guards is between an alias that is UNDEFINED and a module
// that is ABSENT. Importing a module that does not exist under a known alias is
// KORU002 (module not found). Importing under an alias nobody declared is
// PARSE003 (unknown import alias). Before `koru` was defaulted, every program
// using the ecosystem's libraries got PARSE003 unless it carried a config file
// naming a directory — boilerplate repeated by every consumer and owned by none.
//
// Deliberately importing a module that cannot exist, so the test says the same
// thing whether or not koru-libs is installed on the machine running it: absent
// or present, a nonexistent module under a known alias is KORU002. A test that
// resolved a real library would pass here and fail on a machine without the
// sibling checkout.

import koru/definitely-not-a-real-module-xyz

tor main {}

main -> _
