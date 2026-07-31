// PINS: TWENTY-SIX stores live in one program — each declared, inserted,
// written through its own sweep, and read back, under one compilation.
//
// This is ecs_bench_suite's fragmented_iter (rust-gamedev's workload): 26
// component fragments, few entities each, `data *= 2` over every fragment. In
// an archetype engine the workload measures fragmentation cost; here presence
// is a predicate column, not schema membership (O13), so each fragment is
// simply its own store. What the shape stresses instead is store COUNT: no
// corpus program declared more than a couple, so the registry, the per-store
// transform mint, and the emitted-name space had never been asked for 26 of
// anything.
import std/io
import std/store

std/store:new(ca, capacity: 4) { data: f64 }
std/store:new(cb, capacity: 4) { data: f64 }
std/store:new(cc, capacity: 4) { data: f64 }
std/store:new(cd, capacity: 4) { data: f64 }
std/store:new(ce, capacity: 4) { data: f64 }
std/store:new(cf, capacity: 4) { data: f64 }
std/store:new(cg, capacity: 4) { data: f64 }
std/store:new(ch, capacity: 4) { data: f64 }
std/store:new(ci, capacity: 4) { data: f64 }
std/store:new(cj, capacity: 4) { data: f64 }
std/store:new(ck, capacity: 4) { data: f64 }
std/store:new(cl, capacity: 4) { data: f64 }
std/store:new(cm, capacity: 4) { data: f64 }
std/store:new(cn, capacity: 4) { data: f64 }
std/store:new(co, capacity: 4) { data: f64 }
std/store:new(cp, capacity: 4) { data: f64 }
std/store:new(cq, capacity: 4) { data: f64 }
std/store:new(cr, capacity: 4) { data: f64 }
std/store:new(cs, capacity: 4) { data: f64 }
std/store:new(ct, capacity: 4) { data: f64 }
std/store:new(cu, capacity: 4) { data: f64 }
std/store:new(cv, capacity: 4) { data: f64 }
std/store:new(cw, capacity: 4) { data: f64 }
std/store:new(cx, capacity: 4) { data: f64 }
std/store:new(cy, capacity: 4) { data: f64 }
std/store:new(cz, capacity: 4) { data: f64 }

std/store:insert(ca) { data: 1.0 }
std/store:insert(cb) { data: 2.0 }
std/store:insert(cc) { data: 3.0 }
std/store:insert(cd) { data: 4.0 }
std/store:insert(ce) { data: 5.0 }
std/store:insert(cf) { data: 6.0 }
std/store:insert(cg) { data: 7.0 }
std/store:insert(ch) { data: 8.0 }
std/store:insert(ci) { data: 9.0 }
std/store:insert(cj) { data: 10.0 }
std/store:insert(ck) { data: 11.0 }
std/store:insert(cl) { data: 12.0 }
std/store:insert(cm) { data: 13.0 }
std/store:insert(cn) { data: 14.0 }
std/store:insert(co) { data: 15.0 }
std/store:insert(cp) { data: 16.0 }
std/store:insert(cq) { data: 17.0 }
std/store:insert(cr) { data: 18.0 }
std/store:insert(cs) { data: 19.0 }
std/store:insert(ct) { data: 20.0 }
std/store:insert(cu) { data: 21.0 }
std/store:insert(cv) { data: 22.0 }
std/store:insert(cw) { data: 23.0 }
std/store:insert(cx) { data: 24.0 }
std/store:insert(cy) { data: 25.0 }
std/store:insert(cz) { data: 26.0 }

std/store:sweep(ca)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cb)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cc)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cd)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(ce)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cf)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cg)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(ch)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(ci)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cj)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(ck)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cl)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cm)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cn)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(co)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cp)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cq)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cr)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cs)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(ct)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cu)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cv)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cw)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cx)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cy)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(cz)
! sweep e |> std/store:stored { e.data: e.data * 2.0 }

std/store:sweep(ca)
! sweep r |> std/io:print.ln("ca {{ r.data:f }}")

std/store:sweep(cb)
! sweep r |> std/io:print.ln("cb {{ r.data:f }}")

std/store:sweep(cc)
! sweep r |> std/io:print.ln("cc {{ r.data:f }}")

std/store:sweep(cd)
! sweep r |> std/io:print.ln("cd {{ r.data:f }}")

std/store:sweep(ce)
! sweep r |> std/io:print.ln("ce {{ r.data:f }}")

std/store:sweep(cf)
! sweep r |> std/io:print.ln("cf {{ r.data:f }}")

std/store:sweep(cg)
! sweep r |> std/io:print.ln("cg {{ r.data:f }}")

std/store:sweep(ch)
! sweep r |> std/io:print.ln("ch {{ r.data:f }}")

std/store:sweep(ci)
! sweep r |> std/io:print.ln("ci {{ r.data:f }}")

std/store:sweep(cj)
! sweep r |> std/io:print.ln("cj {{ r.data:f }}")

std/store:sweep(ck)
! sweep r |> std/io:print.ln("ck {{ r.data:f }}")

std/store:sweep(cl)
! sweep r |> std/io:print.ln("cl {{ r.data:f }}")

std/store:sweep(cm)
! sweep r |> std/io:print.ln("cm {{ r.data:f }}")

std/store:sweep(cn)
! sweep r |> std/io:print.ln("cn {{ r.data:f }}")

std/store:sweep(co)
! sweep r |> std/io:print.ln("co {{ r.data:f }}")

std/store:sweep(cp)
! sweep r |> std/io:print.ln("cp {{ r.data:f }}")

std/store:sweep(cq)
! sweep r |> std/io:print.ln("cq {{ r.data:f }}")

std/store:sweep(cr)
! sweep r |> std/io:print.ln("cr {{ r.data:f }}")

std/store:sweep(cs)
! sweep r |> std/io:print.ln("cs {{ r.data:f }}")

std/store:sweep(ct)
! sweep r |> std/io:print.ln("ct {{ r.data:f }}")

std/store:sweep(cu)
! sweep r |> std/io:print.ln("cu {{ r.data:f }}")

std/store:sweep(cv)
! sweep r |> std/io:print.ln("cv {{ r.data:f }}")

std/store:sweep(cw)
! sweep r |> std/io:print.ln("cw {{ r.data:f }}")

std/store:sweep(cx)
! sweep r |> std/io:print.ln("cx {{ r.data:f }}")

std/store:sweep(cy)
! sweep r |> std/io:print.ln("cy {{ r.data:f }}")

std/store:sweep(cz)
! sweep r |> std/io:print.ln("cz {{ r.data:f }}")
