# koru-libs/z3 — vendored Z3 SMT solver

Prebuilt Z3 release, vendored for `std/smt` (the SMT checker lane).

- **Version**: 5.3.2 (`z3-5.3.2` tag)
- **Source**: `https://github.com/Z3Prover/z3/releases/download/z3-4.13.0/z3-4.13.0-x64-glibc-2.31.zip`
- **Zip SHA-256**: `bc31ad12446d7db1bd9d0ac82dec9d7b5129b8b8dd6e44b571a83ac6010d2f9b`
- **License**: MIT (see `LICENSE.txt`)
- **Contents**: `lib/libz3.so` (shared lib, linux x86-64), `include/` (C API headers, reference only — `std/smt` declares the needed externs itself)

Only the dynamic library is vendored — the release's `libz3.a` is ~137 MB and buys nothing the rpath link doesn't give. `std/smt`'s `~requires` adds `koru-libs/z3/lib` to the emitted program's library path *and* rpath, so linked binaries run from any cwd.
