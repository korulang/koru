// TEST: pass a Transaction where a Connection is expected — refused by Koru's
// own front end, with no flag.
//
// close() expects: *Connection<!active>
// this passes:     *Transaction<active!>
//
// The phantom STATE matches on both sides (active), so state checking alone
// waves it through; what refuses it is the base-type check, comparing the
// type's own name and seeing Connection against Transaction.
//
// Until 2026-08-10 this pinned a ZIG error naming Koru's generated module
// paths, because the base-type check sat behind --strict-base-types and was off
// by default. It pins a Koru diagnostic now, and the flag no longer exists.

import app/db

// The handler below passes t (*Transaction) to close(), which takes a
// *Connection.
app/db:connect(host: "localhost")
| ok c |> app/db:begin(conn: c)
    | ok t |> app/db:close(conn: t)
    | err _ |> _
| err _ |> _
