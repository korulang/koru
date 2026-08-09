// PINS: after `commit` the connection comes back `<active!>` and is dropped
// into `| ok _ |> _`. `close` (db.kz:78) is void and accepts `<!active>`, so
// it is the one auto-discharge candidate and the inserter appends it — the
// program runs and the connection IS closed. "Connection closed" in the
// expected output is the proof, not decoration.
//
// This is the same behavior 2104_15 pins on the newer db surface. The refusal
// half lives in 2104_21, which is this program under
// `--auto-discharge=disable`: turn the inserter off and the undischarged
// `<active!>` is rejected. Two files, two halves; neither is this one's job.
//
// (Before auto-discharge existed, this file pinned "forget to close is a leak."
// It is not one — the compiler closes it — so the pin was inverted rather than
// left claiming a refusal that never comes.)

~import app/db

~app/db:connect(host: "localhost")
| ok c |> app/db:begin(conn: c)
    | ok t |> app/db:exec(tx: t, sql: "INSERT INTO users VALUES (1, 'alice')")
        | ok r |> app/db:commit(tx: r)
            | ok _ |> _
            | err _ |> _
        | err _ |> _
    | err _ |> _
| err _ |> _
