// PINS: a singleton cell path read in an INSERT literal's rhs. The cell
// rewrite that lowers `cfg.base` in if/when expressions (690_074) and in
// stored rhs must reach the insert literal too — it is the same read in the
// one remaining write-envelope position. A deserializer meets this shape
// immediately: the pending parsed value sits in a staging singleton and the
// rebuilt row is inserted from it (690_190 detours through an echo tor).
import std/io
import std/store

std/store:new(cfg) { base: 7[i64] }
std/store:new(dst, capacity: 2) { id: i64 }

std/store:insert(dst) { id: cfg.base }

std/store:query(dst)
! query d |> std/io:print.ln("row {{ d.id:d }}")
