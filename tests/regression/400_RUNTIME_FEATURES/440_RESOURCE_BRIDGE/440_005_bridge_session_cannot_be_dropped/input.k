// TEST: the dropped session is VISIBLE to enforcement even when nobody will
// insert the hang-up for you.
//
// `create` mints `*Bridge<session!>`; only `close`, taking `<!session>`,
// discharges it. This flow opens a session, asks it a question, and walks away.
//
// In the DEFAULT mode that program compiles, because `close` is void and
// auto-discharge appends it — which is the guarantee working, not a hole, and
// `440_006` is the positive half. `--auto-discharge=disable` opts out of
// INSERTING a discharger; it never opts out of the obligation being SEEN. So
// the same program under the flag must still be refused by name.
//
// That distinction is the whole reason this test carries a flag: without it,
// making a disposer auto-insertable would silently retire the wall along with
// the chore.
import std/bridge
import std/io

[with]std/bridge:create(id: "s1", scope: "files"): br |> get-handles(br): n |> std/io:print.ln("holding {{ n:d }}")
