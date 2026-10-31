#!/usr/bin/env python3
import time, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from operands import *
from decimal import Decimal, getcontext

getcontext().prec = 5200
D = Decimal
RES = {}
P_BIG = 3000
P_TR = 2000

def timed(label, fn):
    t = time.perf_counter()
    r = fn()
    ms = (time.perf_counter() - t) * 1000
    RES[label] = str(r)
    print(f"PY {label}: {ms:.2f}ms", file=sys.stderr, flush=True)
    return r

# int variants: python int is the reference-grade bigint (Karatsuba/FFT)
def timed_int(label, fn):
    t = time.perf_counter()
    r = fn()
    ms = (time.perf_counter() - t) * 1000
    RES[label] = str(r)
    print(f"PYi {label}: {ms:.2f}ms", file=sys.stderr, flush=True)
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
timed_int("w1i", lambda: int(A2000) * int(B2000))
timed("w2", lambda: D(3) ** 100000)
timed_int("w2i", lambda: 3 ** 100000)
def w3():
    getcontext().prec = P_BIG + 10
    return + (D(A2000) / D(B2000))
timed("w3", w3)
def w4():
    getcontext().prec = P_BIG + 10
    return + D(2).sqrt()
timed("w4", w4)
def w4i():  # isqrt reference: floor(sqrt(2*10^(2P))) => P+1 sig digits
    import math
    return math.isqrt(2 * 10 ** (2 * P_BIG))
timed_int("w4i", w4i)
timed("w5", lambda: dexp(D(1), P_TR))
timed("w6", lambda: dln(D(2), P_TR))
timed("w7", lambda: dsin(D(1), P_TR))
timed("w8", lambda: 16 * datan(D("0.2"), P_TR + 20) - 4 * datan(D(INV239), P_TR + 20))
timed("w9", lambda: int(A5000) % int(B997))
timed("w10", lambda: dexp(dln(D(2), P_TR + 20) * D("0.5"), P_TR))

for k in sorted(RES):
    print(f"{k}={RES[k]}")
