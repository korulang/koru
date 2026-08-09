// ⚠ `std/time:now(): n` below is a REROUTE, not a preference. This entry was
// written `std/time:now()` + `| t n |>` — the head-label binding sugar 210_195
// pins — and that spelling still does not compile in a subflow BODY: the
// emitter tag-dispatches over the returned scalar and leaks raw Zig. Pinned RED
// as 210_200. When that closes, either spelling works and this note goes with it.
// Do not read the bind form here as the shape this program wants.
import std/io
import std/time
import std/field
import std/control

const { sieve_bits: 500000 }

pub tor tick { deadline: i128, passes: i64 }
| live { deadline: i128, passes: i64 }
| expired i64

pub tor run { deadline: i128 } -> i64

tick = std/time:now(): n |> if(n < deadline)
| then => live { deadline, passes }
| else => expired passes

run = #L tick(deadline, passes: 0)
| live l |> std/field:new(bits: sieve_bits)
    | field f |> for(1..500)
        ! each i |> std/field:test(f, i): pv |> if(pv == 0)
            | then |> std/field:mark-multiples(f, from: 2 * i * (i + 1), stride: 2 * i + 1, limit: 499999)
        | done |> std/field:free(f) |> @L(l.deadline, passes: l.passes + 1)
    | err _ |> _
| expired e -> e

std/time:now(): t0 |> run(deadline: t0 + 5000000000): n |> std/time:now(): t1 |> std/field:new(bits: sieve_bits)
| field f |> for(1..500)
    ! each i |> std/field:test(f, i): pv |> if(pv == 0)
        | then |> std/field:mark-multiples(f, from: 2 * i * (i + 1), stride: 2 * i + 1, limit: 499999)
    | done |> std/field:count-zeros(f, lo: 1, hi: 500000): c |> std/io:eprint.ln("validated primes: {{ c + 1:d }}") |> std/io:print.ln("korulang;{{ n:d }};{{ @as(f64, @floatFromInt(t1 - t0)) / 1000000000.0:f }};1;algorithm=base,faithful=yes,bits=1") |> std/field:free(f)
| err _ |> _
