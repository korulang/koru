// Pins oracle-style width formatting of signed integers: {{ v:d:8 }} on a
// positive runtime i64 must render space-padded digits ("   14683"), sign
// only when negative — the shape every external benchmark oracle (CLBG,
// PLB nsieve) expects. The interpolation spec currently passes verbatim
// into Zig's format string, and Zig 0.15 prints an explicit '+' on
// width-formatted positive signed integers. The parked :d:N ruling
// (raw-Zig passthrough vs Koru-owned width semantic) decides the
// MECHANISM; this pin holds the SURFACE — if the ruling keeps verbatim
// passthrough, the oracle shape needs another spelling and this test
// moves with it.
import std/io

pub event thru { n: i64 } -> i64

thru = if(n > 0)
| then -> n
| else -> n

thru(n: 14683): v |> std/io:print.ln("[{{ v:d:8 }}]")
