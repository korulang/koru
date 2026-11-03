// The compiler-env import is auto-injected by scanning the raw source for the
// substring `import std/compiler` (src/main.zig) — and a COMMENT containing
// that text satisfies the scan. This program only *mentions* the import;
// nothing here declares it. With the injection suppressed, every
// `std/compiler:` host-type reference inside stdlib transforms fails KORU117
// pointing into koru_std files the author never opened — and the comment that
// caused it is never named.
//
// Two states the tool cannot tell apart: "the import is present" and "the
// import is a substring inside a comment". The pin: prose mentioning the
// import must not count as declaring it.

import std/io

std/io:print.ln("comment is not a declaration")
