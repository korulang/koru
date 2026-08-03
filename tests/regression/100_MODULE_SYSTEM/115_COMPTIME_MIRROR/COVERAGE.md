# The comptime module-mirror wall — coverage manifest

Every comptime transform declared in `koru_std` MUST appear in the table below,
and prose-check **check D** fails the suite until it does. That is the whole
point: a transform added without a module mirror is invisible otherwise, because
the entry file collapses the file-derived name, the import-derived logical name
and the emitted `main_module` into one word — so nothing diverges until the
transform's subject lives somewhere else. Five libraries shipped the same class
of fault behind that collapse.

Column two is either the test directory that mirrors the transform, or a reason
it has none. The reasons are deliberately narrow; widen them only with a ruling,
because "no mirror" is exactly the state this file exists to make expensive.

| reason | meaning |
| --- | --- |
| `no-green-usage` | nothing green in the corpus to relocate. Also a finding about the suite, not a licence to skip. |
| `pins-unimplemented-surface` | its only usages are honest failing pins for a surface that does not exist yet. |
| `tested-in-koru-libs` | the transform lives in the sibling `koru-libs` repo and is exercised there. Listed for the record; check D does not enforce over out-of-repo libs. |

| transform | mirror-or-reason |
| --- | --- |
| `control:capture` | `115_024_capture_in_module` |
| `constructor:default` | no-green-usage |
| `constructor:struct` | `115_034_constructor_struct_in_module` |
| `field:mark-multiples` | `115_029_field_mark_multiples_in_module` |
| `field:new` | `115_004_field_new_in_module` |
| `field:new.on-stack` | no-green-usage |
| `fmt:fmt.blk` | no-green-usage |
| `fmt:ln` | `115_026_fmt_ln_in_module` |
| `io:eprint` | no-green-usage |
| `io:eprint.ln` | no-green-usage |
| `io:print` | `115_035_io_print_in_module` |
| `io:print.blk` | `115_015_print_blk_in_module` |
| `io:print.ln` | `115_001_io_print_ln_in_module` |
| `kernel:init` | `115_005_kernel_init_in_module` |
| `kernel:pairwise` | `115_027_kernel_pairwise_in_module` |
| `kernel:self` | `115_016_kernel_self_in_module` |
| `kernel:step` | `115_028_kernel_step_in_module` |
| `liquid_template:emit` | `115_014_liquid_emit_in_module` |
| `list:new` | `115_025_list_new_in_module` |
| `parser:grammar` | `115_012_parser_grammar_in_module` |
| `parser:parse` | `115_012_parser_grammar_in_module` |
| `regex:match` | `115_013_regex_match_in_module` |
| `regex:scan` | `115_003_regex_scan_in_module` |
| `runtime:register` | `115_036_runtime_register_in_module` |
| `store:default` | no-green-usage |
| `store:insert` | `115_018_store_insert_in_module` |
| `store:new` | `690_079_store_declared_in_imported_module` |
| `grid:new` | `115_045_grid_in_module` |
| `grid:stored` | `115_045_grid_in_module` |
| `grid:sweep` | `115_045_grid_in_module` |
| `store:preorder` | pins-unimplemented-surface |
| `store:query` | `115_019_store_query_in_module` |
| `store:rule` | `115_042_store_rule_in_module` |
| `store:stored` | `690_079_store_declared_in_imported_module` |
| `store:stripe` | `115_022_store_stripe_in_module` |
| `store:take` | `115_023_store_take_in_module` |
| `store:watch` | `115_021_store_watch_in_module` |
| `switch:char` | `115_002_switch_char_in_module` |
| `taps:tap` | `115_033_taps_tap_in_module` |
| `testing:assert` | no-green-usage |
| `testing:assert.ok` | no-green-usage |
| `testing:test` | no-green-usage |
| `testing:test.harness` | no-green-usage |
| `testing:test.property.equivalent` | no-green-usage |
| `testing:test.with-harness` | no-green-usage |
| `trellis:check` | `115_039_trellis_check_in_module` |
| `trellis:enforce` | `115_038_trellis_enforce_in_module` |
| `types:bool` | `115_037_types_bool_in_module` |
| `types:float` | `115_032_types_float_in_module` |
| `types:int` | `115_031_types_nominal_in_module` |
| `types:string` | `115_031_types_nominal_in_module` |
| `types:struct` | `115_030_types_struct_in_module` |
| `types:type` | no-green-usage |
| `sqlite3:query` | tested-in-koru-libs |
| `vaxis:component` | tested-in-koru-libs |
| `vaxis:default` | tested-in-koru-libs |
| `vaxis:shader` | tested-in-koru-libs |
| `vaxis:view` | tested-in-koru-libs |
