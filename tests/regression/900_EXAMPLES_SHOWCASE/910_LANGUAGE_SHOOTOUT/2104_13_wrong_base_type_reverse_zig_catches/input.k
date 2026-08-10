// TEST: pass a Connection where a Transaction is expected — the reverse of
// 2104_12, refused by Koru's own front end, with no flag.
//
// commit() expects: *Transaction<!active>
// this passes:      *Connection<active!>
//
// Same shape as 2104_12: the phantom state agrees, the type name does not.

import app/db

// The handler below passes c (*Connection) to commit(), which takes a
// *Transaction.
app/db:connect(host: "localhost")
| ok c |> app/db:commit(tx: c)
| err _ |> _
