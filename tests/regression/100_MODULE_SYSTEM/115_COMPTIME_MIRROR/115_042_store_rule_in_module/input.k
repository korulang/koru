// MIRROR for `std/store:rule`: a standing rule over a store whose home is an
// imported module. `rule` arrived by rename (koru 19d9393d: the old `query`
// became `rule`), so the mirror wall had no row for it and check D was right
// to say so.
//
// ASPIRATIONAL — it joins a family, and that is the finding. Every
// `*_in_module` store mirror is red (115_018/019/020/021/022/023) and both
// `*_in_entry_tor` controls are green (115_017, 115_040): a store declared in
// an imported module is not found by the store transforms sitting in that same
// module, which refuse with KORU161 "unknown store". Seven verbs, one fault.
// They flip together or the fix was not the fix.
//
// The rule fires once at its own program position, so `install()` between the
// seed and the readback is that position: 5 becomes 6.
import app/lib

app/lib:seed() |> app/lib:install() |> app/lib:show()
