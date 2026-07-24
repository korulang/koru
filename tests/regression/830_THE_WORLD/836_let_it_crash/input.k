// The World in Koru — entry 6.
// Doorway: Erlang's "let it crash" — an OTP worker does not defensively
// handle every failure path. A malformed message crashes the worker
// process outright; a supervisor notices the crash and restarts it. The
// worker itself stays simple because the failure case is not its problem
// to hand-roll recovery for — that's what the supervision tree is for.
//
// Here in Koru: the crash surface is a TYPE, not a convention. `process-job`
// declares its malformed-input path as a PANIC branch — `| ?!badjob i64`, a
// THIRD branch kind alongside required `|` and optional `| ?`. Left
// unhandled, an unhandled panic branch synthesizes `@panic(...)` at that
// call site: the process crashes, loudly, the same as an Erlang worker with
// no try/catch around a bad message. The supervisor role is played by
// whichever CALLER opts in to handling `badjob` instead of leaving it to
// panic — recovery is visible in the source and typed, not a blanket catch
// wrapped around everything.
//
// This composes two corners the catalog hasn't touched together: panic
// branches (210_125-130 pin the branch KIND; nothing in the suite yet fires
// one from a pure-.k body) and the `if(...) | then => branch value` forward
// (810_111's istep/seek) used to PRODUCE into a panic-kind branch instead of
// a required one.
import std/io

pub tor process-job { code: i64 }
| ok i64
| ?!badjob i64

process-job = if(code < 0)
| then => badjob code
| else => ok code

// Five jobs land on the worker. Two are malformed (negative code). Each one
// crashes process-job's `badjob` path — but the caller here plays supervisor
// and catches it explicitly, so the run survives both crashes and keeps
// going, exactly the way OTP keeps a supervision tree alive across restarts.
process-job(code: 3)
| ok v |> std/io:print.ln("job {{ v:d }}: completed")
| badjob v |> std/io:print.ln("job {{ v:d }}: crashed, supervisor restarting worker")

process-job(code: -1)
| ok v |> std/io:print.ln("job {{ v:d }}: completed")
| badjob v |> std/io:print.ln("job {{ v:d }}: crashed, supervisor restarting worker")

process-job(code: 5)
| ok v |> std/io:print.ln("job {{ v:d }}: completed")
| badjob v |> std/io:print.ln("job {{ v:d }}: crashed, supervisor restarting worker")

process-job(code: -2)
| ok v |> std/io:print.ln("job {{ v:d }}: completed")
| badjob v |> std/io:print.ln("job {{ v:d }}: crashed, supervisor restarting worker")

process-job(code: 8)
| ok v |> std/io:print.ln("job {{ v:d }}: completed")
| badjob v |> std/io:print.ln("job {{ v:d }}: crashed, supervisor restarting worker")
