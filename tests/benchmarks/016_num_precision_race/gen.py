#!/usr/bin/env python3
"""Generate the three-way race rig: Koru .k, bc scripts, python decimal bench.

bc gets one file per workload (process-level timing; ~2ms startup reported
separately). Koru times in-process via std/time (now(): t heads the timed
statement, report ends it — bindings are per-statement). Union arms of a call
nest one level deeper than the producing arm.
"""
import random

random.seed(42)
B = "/tmp/korubench"

def digits(n):
    return "".join(random.choice("0123456789") for _ in range(n))

A2000 = digits(2000).lstrip("0") or "7"
B2000 = digits(2000).lstrip("0") or "3"
A5000 = digits(5000).lstrip("0") or "9"
B997 = digits(997).lstrip("0") or "7"

from decimal import Decimal, getcontext
getcontext().prec = 2400
INV239 = str(Decimal(1) / Decimal(239))

P_BIG = 3000
P_TR = 2000

with open(f"{B}/operands.py", "w") as f:
    f.write(f'A2000="{A2000}"\nB2000="{B2000}"\nA5000="{A5000}"\n')
    f.write(f'B997="{B997}"\nINV239="{INV239}"\n')

K = ['import std/io', 'import std/num', 'import std/time', '']

def kw(w, body):
    K.append(f'std/time:now(): t_{w}')
    K.extend(body.splitlines())
    K.append('')

# single-operand union-result: lit | exact a |> op -> | arms | bad
def single(w, lit_s, opcall, arms):
    out = [f'  |> std/num:lit(s: "{lit_s}")',
           f'  | exact a |> {opcall}']
    for arm, tail in arms:
        out.append(f'      | {arm} |> {tail}')
    out.append('  | bad _ |> std/io:print.ln("bad")')
    return out

P = 'std/io:print.ln'
F = 'std/num:free(n: r)'

# w1 mul exact
kw("w1", f'''  |> std/num:lit(s: "{A2000}")
  | exact a |> std/num:lit(s: "{B2000}")
      | exact b |> std/num:mul(a, b): r
          |> {P}("w1={{{{ r:s }}}}")
          |> {F}
          |> std/time:report(start: t_w1, label: "w1-mul")
      | bad _ |> {P}("w1-badb")
  | bad _ |> {P}("w1-bada")''')

# w2 pow 3^100000
kw("w2", f'''  |> std/num:lit(s: "3")
  | exact a |> std/num:pow(a, n: 100000)
      | exact r |> {P}("w2={{{{ r:s }}}}")
          |> {F}
          |> std/time:report(start: t_w2, label: "w2-pow")
      | neg-exp |> {P}("w2-negexp")
  | bad _ |> {P}("w2-bad")''')

# w3 div
kw("w3", f'''  |> std/num:lit(s: "{A2000}")
  | exact a |> std/num:lit(s: "{B2000}")
      | exact b |> std/num:div(a, b, prec: {P_BIG})
          | exact r |> {P}("w3={{{{ r:s }}}}")
              |> {F}
              |> std/time:report(start: t_w3, label: "w3-div")
          | div-zero |> {P}("w3-divzero")
      | bad _ |> {P}("w3-badb")
  | bad _ |> {P}("w3-bada")''')

# w4 sqrt(2)
kw("w4", f'''  |> std/num:lit(s: "2")
  | exact a |> std/num:sqrt(a, prec: {P_BIG})
      | exact r |> {P}("w4={{{{ r:s }}}}")
          |> {F}
          |> std/time:report(start: t_w4, label: "w4-sqrt")
      | negative |> {P}("w4-neg")
  | bad _ |> {P}("w4-bad")''')

# w5 exp(1)
kw("w5", f'''  |> std/num:lit(s: "1")
  | exact a |> std/num:exp(a, prec: {P_TR})
      | exact r |> {P}("w5={{{{ r:s }}}}")
          |> {F}
          |> std/time:report(start: t_w5, label: "w5-exp")
      | overflow |> {P}("w5-of")
  | bad _ |> {P}("w5-bad")''')

# w6 ln(2)
kw("w6", f'''  |> std/num:lit(s: "2")
  | exact a |> std/num:ln(a, prec: {P_TR})
      | exact r |> {P}("w6={{{{ r:s }}}}")
          |> {F}
          |> std/time:report(start: t_w6, label: "w6-ln")
      | non-pos |> {P}("w6-nonpos")
  | bad _ |> {P}("w6-bad")''')

# w7 sin(1)
kw("w7", f'''  |> std/num:lit(s: "1")
  | exact a |> std/num:sin(a, prec: {P_TR})
      | exact r |> {P}("w7={{{{ r:s }}}}")
          |> {F}
          |> std/time:report(start: t_w7, label: "w7-sin")
      | overflow |> {P}("w7-of")
  | bad _ |> {P}("w7-bad")''')

# w8 pi via Machin — atan is arrow-return (: bind), nested lits for 16/4
kw("w8", f'''  |> std/num:lit(s: "0.2")
  | exact a1 |> std/num:atan(a: a1, prec: {P_TR + 20}): t1
      |> std/num:lit(s: "{INV239}")
      | exact a2 |> std/num:atan(a: a2, prec: {P_TR + 20}): t2
          |> std/num:lit(s: "16")
          | exact s16 |> std/num:mul(a: s16, b: t1): m1
              |> std/num:lit(s: "4")
              | exact s4 |> std/num:mul(a: s4, b: t2): m2
                  |> std/num:sub(a: m1, b: m2): r
                  |> {P}("w8={{{{ r:s }}}}")
                  |> {F}
                  |> std/time:report(start: t_w8, label: "w8-machin")
              | bad _ |> {P}("w8-b4")
          | bad _ |> {P}("w8-b16")
      | bad _ |> {P}("w8-b2")
  | bad _ |> {P}("w8-b1")''')

# w9 mod
kw("w9", f'''  |> std/num:lit(s: "{A5000}")
  | exact a |> std/num:lit(s: "{B997}")
      | exact b |> std/num:mod(a, b)
          | exact r |> {P}("w9={{{{ r:s }}}}")
              |> {F}
              |> std/time:report(start: t_w9, label: "w9-mod")
          | div-zero |> {P}("w9-dz")
      | bad _ |> {P}("w9-badb")
  | bad _ |> {P}("w9-bada")''')

# w10 powf 2^0.5
kw("w10", f'''  |> std/num:lit(s: "2")
  | exact a |> std/num:lit(s: "0.5")
      | exact e |> std/num:powf(a, e, prec: {P_TR})
          | exact r |> {P}("w10={{{{ r:s }}}}")
              |> {F}
              |> std/time:report(start: t_w10, label: "w10-powf")
          | neg-base |> {P}("w10-nb")
          | non-pos |> {P}("w10-np")
          | overflow |> {P}("w10-of")
      | bad _ |> {P}("w10-be")
  | bad _ |> {P}("w10-ba")''')

with open(f"{B}/input.k", "w") as f:
    f.write("\n".join(K) + "\n")

# ---- bc scripts ------------------------------------------------------------
bc = {
 "w1": f'scale=0\n{A2000}*{B2000}\n',
 "w2": 'scale=0\n3^100000\n',
 "w3": f'scale={P_BIG}\n{A2000}/{B2000}\n',
 "w4": f'scale={P_BIG}\nsqrt(2)\n',
 "w5": f'scale={P_TR}\ne(1)\n',
 "w6": f'scale={P_TR}\nl(2)\n',
 "w7": f'scale={P_TR}\ns(1)\n',
 "w8": f'scale={P_TR + 20}\n16*a(0.2)-4*a({INV239})\n',
 "w9": f'scale=0\n{A5000}%{B997}\n',
 "w10": f'scale={P_TR}\ne(l(2)*0.5)\n',
}
for w, s in bc.items():
    with open(f"{B}/{w}.bc", "w") as f:
        f.write(s)

# ---- python bench ----------------------------------------------------------
PY = f'''#!/usr/bin/env python3
import time, sys
sys.path.insert(0, "{B}")
from operands import *
from decimal import Decimal, getcontext

getcontext().prec = 5200
D = Decimal
RES = {{}}

def timed(label, fn):
    t = time.perf_counter()
    r = fn()
    ms = (time.perf_counter() - t) * 1000
    RES[label] = str(r)
    print(f"PY {{label}}: {{ms:.2f}}ms", file=sys.stderr, flush=True)
    return r

def dexp(x, prec):
    getcontext().prec = prec + 20
    s, term, n = D(1), D(1), 1
    while True:
        term = term * x / n
        if term.is_zero() or abs(term) < D(10) ** (-(prec + 15)):
            break
        s += term; n += 1
    getcontext().prec = prec
    return +s

def datanh(x, prec):
    getcontext().prec = prec + 20
    s, x2, k = x, x * x, 1
    term = x
    while True:
        term = term * x2
        add = term / (k + 2)
        if add.is_zero() or abs(add) < D(10) ** (-(prec + 15)):
            break
        s += add; k += 2
    getcontext().prec = prec
    return +s

def dln(x, prec):
    getcontext().prec = prec + 20
    y = (x - 1) / (x + 1)
    r = 2 * datanh(y, prec + 20)
    getcontext().prec = prec
    return +r

def datan(x, prec):
    getcontext().prec = prec + 20
    s, x2, k, sign = x, x * x, 1, 1
    term = x
    while True:
        term = term * x2
        add = term / (k + 2)
        if add.is_zero() or abs(add) < D(10) ** (-(prec + 15)):
            break
        s += (-add if sign > 0 else add); sign = -sign; k += 2
    getcontext().prec = prec
    return +s

def dsin(x, prec):
    getcontext().prec = prec + 20
    s, term, k = x, x, 3
    x2 = x * x
    while True:
        term = -term * x2 / (k * (k - 1))
        if term.is_zero() or abs(term) < D(10) ** (-(prec + 15)):
            break
        s += term; k += 2
    getcontext().prec = prec
    return +s

timed("w1", lambda: D(A2000) * D(B2000))
timed("w2", lambda: D(3) ** 100000)
def w3():
    getcontext().prec = {P_BIG} + 10
    return + (D(A2000) / D(B2000))
timed("w3", w3)
def w4():
    getcontext().prec = {P_BIG} + 10
    return + D(2).sqrt()
timed("w4", w4)
timed("w5", lambda: dexp(D(1), {P_TR}))
timed("w6", lambda: dln(D(2), {P_TR}))
timed("w7", lambda: dsin(D(1), {P_TR}))
timed("w8", lambda: 16 * datan(D("0.2"), {P_TR} + 20) - 4 * datan(D(INV239), {P_TR} + 20))
timed("w9", lambda: D(A5000) % D(B997))
timed("w10", lambda: dexp(dln(D(2), {P_TR} + 20) * D("0.5"), {P_TR}))

for k in sorted(RES):
    print(f"{{k}}={{RES[k]}}")
'''
with open(f"{B}/bench.py", "w") as f:
    f.write(PY)

print("generated")
