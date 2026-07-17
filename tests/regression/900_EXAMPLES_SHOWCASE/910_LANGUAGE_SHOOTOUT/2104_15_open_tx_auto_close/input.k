// Ground truth for korulang.org phantom explorer — commit then auto-close.
// The committed <active!> connection is bound and discarded (`: _`); auto-
// discharge inserts close() on the dropped obligation, exactly as the old
// `| committed _ |> _` branch discard did — the migration is mechanical.
//
// EXPECTED: Compiles and runs successfully

import app/db

app/db:open(connstr: "postgres://localhost/test")
| connected c |> app/db:tx.begin(conn: c): t |> app/db:tx.exec(tx: t, sql: "INSERT INTO users VALUES (1, 'alice')"): r |> app/db:tx.commit(tx: r): _
| connection-failed |> _
