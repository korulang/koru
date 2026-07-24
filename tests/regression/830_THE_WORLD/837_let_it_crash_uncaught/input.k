// The World in Koru — entry 6, the negative twin of 836_let_it_crash.
// Doorway: Erlang's "let it crash" with NO supervisor in the path — a malformed
// message reaches a worker that has no one catching its failure, and the process
// dies. That death is the whole point of the philosophy; the supervisor is what
// makes it survivable, and here there is none.
//
// In 836 every caller plays supervisor and catches `| badjob`. Here the caller
// does NOT — it handles only `| ok`, leaving `process-job`'s `?!badjob` panic
// branch unhandled. A good job completes; then a malformed one fires the panic
// branch, the compiler having synthesized `@panic(...)` at that call site, and
// the worker crashes at runtime. This is what makes `?!badjob` a PANIC branch
// and not a plain required branch: the distinguishing behaviour — unhandled ⇒
// crash — that 836 never exercises because it catches everything.
import std/io

pub tor process-job { code: i64 }
| ok i64
| ?!badjob i64

process-job = if(code < 0)
| then => badjob code
| else => ok code

process-job(code: 3)
| ok v |> std/io:print.ln("job {{ v:d }}: completed")

// No supervisor: `| badjob` is left unhandled, so this malformed job crashes.
process-job(code: -1)
| ok v |> std/io:print.ln("job {{ v:d }}: completed")
