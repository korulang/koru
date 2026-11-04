import std/io
import std/smt

// sat: x+y>10, x<5 -> model
std/smt:smt-check(q: "(check (declare x int) (declare y int) (assert (> (+ x y) 10)) (assert (< x 5)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

// unsat: x>10 and x<5
std/smt:smt-check(q: "(check (declare x int) (assert (> x 10)) (assert (< x 5)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

// bool var: b => x=1 style
std/smt:smt-check(q: "(check (declare b bool) (declare x int) (assert b) (assert (= x 1)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

// nonlinear still works (z3 decides): x*x = 9, x>0
std/smt:smt-check(q: "(check (declare x int) (assert (= (* x x) 9)) (assert (> x 0)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

// big numeral (arbitrary precision through mk_numeral)
std/smt:smt-check(q: "(check (declare x int) (assert (= x 123456789012345678901234567890)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

// not + and/or: (and (not (< x 0)) (or (= x 2) (= x 3)))
std/smt:smt-check(q: "(check (declare x int) (assert (and (not (< x 0)) (or (= x 2) (= x 3)))))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

// unary minus
std/smt:smt-check(q: "(check (declare x int) (assert (= (- x) 4)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

// named bads
std/smt:smt-check(q: "(check (declare x int) (assert (> x y)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

std/smt:smt-check(q: "(check (assert (> 1 0)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

std/smt:smt-check(q: "(frobnicate (declare x int))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

std/smt:smt-check(q: "(check (declare x real))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

std/smt:smt-check(q: "(check (declare x int) (assert (< x true)))")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)

std/smt:smt-check(q: "check (declare x int)")
| sat m |> std/io:print.ln("sat {{ m:s }}") |> std/io:free(content: m)
| unsat |> std/io:print.ln("unsat")
| unknown |> std/io:print.ln("unknown")
| bad r |> std/io:print.ln("bad:{{ r:s }}") |> std/io:free(content: r)
