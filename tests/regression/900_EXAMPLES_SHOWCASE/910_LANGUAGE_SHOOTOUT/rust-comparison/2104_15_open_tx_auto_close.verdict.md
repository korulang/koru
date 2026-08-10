# 2104_15_open_tx_auto_close

**Command:**

    cd rust-comparison && rustc --edition 2021 -o /tmp/rustcmp_15 2104_15_open_tx_auto_close.rs

**rustc output:** compiled cleanly, no diagnostics (zero output, exit 0).

**Program output (`/tmp/rustcmp_15`):**

```
Executing: INSERT INTO users VALUES (1, 'alice')
COMMIT
Connection closed
```

**Rust:** the committed connection is discarded with `let _ = t.commit();` instead of an explicit `.close()` call, and the output is byte-identical to 2104_14 anyway — the same `Drop` impl on `Connection<Active>` that backs the explicit `close()` method also fires the instant the discarded value is dropped, so "auto-close on discard" needed no separate code path at all.

**Koru:** `MUST_RUN`, `expected.txt` is byte-identical to the three lines above. The test's own comment: "auto-discharge inserts close() on the dropped obligation, exactly as the old `| committed _ |> _` branch discard did — the migration is mechanical."

**DIFFERS: no** — and this is the strongest match-up in the set: Koru had to special-case "insert close() when an obligation is discarded" as dedicated compiler behavior, while Rust's `Drop` trait gives the identical guarantee for free, as a consequence of ownership a Rust programmer would reach for regardless of this comparison.
