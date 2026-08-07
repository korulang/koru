// Importing `std/net` without reaching for a tor still builds.
//
// The module's refusal is positional: it fires where a tor is USED, not where
// the module is imported. That is what lets an unimplemented surface keep its
// declarations and carry its teaching to the site that asks for it, instead of
// making the module unnameable. 670_001 pins the refusing half.

import std/io
import std/net

std/io:print.ln("imported, unused")
