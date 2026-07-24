// Cross-target effect-branch dispatch: MULTIPLE effect kinds, multi-fire.
//
// `tokenize` yields two distinct effect kinds — `! token` and `! warning` —
// fired interleaved by the producer. Each kind dispatches to its own handler;
// the synthesized Handlers struct must compose both handler-fns and route each
// call site to the right one. This is the vaxis/Orisha pump shape (cf. the
// zig-only 400_073), now proven on BOTH targets.
//
// Output goes through a per-target `report` proc (std.debug.print | console.log)
// so we never touch print.blk/print.ln (zig-only comptime transforms with no
// JS path). Handlers accumulate counts into module vars; report prints them.
//
// NOTE on arg names: the JS inline-plain-handler path resolves dispatch args
// by FIELD-name match, so the punned dispatch arg's name must equal the target
// event's field name (on-token's field is `t`, dispatched as `on-token(t)`). The
// case where they differ is a real JS-emitter gap, pinned separately by
// 400_112_effect_branch_arg_name_mismatch_cross_target.
pub tor tokenize { n: u64 }
! token u64
! warning u64
pub tor on-token { t: u64 }
pub tor on-warning { w: u64 }
pub tor report {}

tokenize(n: 5)
! token t |> on-token(t)
! warning w |> on-warning(w)
report()
