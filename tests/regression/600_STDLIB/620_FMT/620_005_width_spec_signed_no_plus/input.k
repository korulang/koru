// Pins oracle-style width formatting of signed integers: {{ v:d:8 }} on a
// positive runtime i64 renders space-padded digits ("   14683"), sign only
// when negative — the shape every external benchmark oracle (CLBG, PLB
// nsieve) expects. `:d:N` is Koru-owned (ruled 2026-10-24): the spec never
// reaches the host format string — emitters wrap the arg as
// `__koru_pad_i(N, v)` under `{f}`, so Zig 0.15's '+' on width-formatted
// positive signed ints cannot leak through.
import std/io

pub tor thru { n: i64 } -> i64

thru = if(n > 0)
| then -> n
| else -> n

thru(n: 14683): v |> std/io:print.ln("[{{ v:d:8 }}]")
