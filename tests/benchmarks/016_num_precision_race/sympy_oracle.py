#!/usr/bin/env python3
"""Independent oracle for the koru quantity-numbers arc.

Layer A — mpmath recomputes every benchmark workload at mp.dps=2100/3100 and
         reports digit agreement against the recorded koru outputs.
Layer B — sympy verifies the emitted ODE certificates annihilate their
         functions, the recurrences hold on true series coefficients, and
         the rel-layer conservation claim. Koru never saw this checker.
"""
import re, time, sys, glob, os
if hasattr(sys, "set_int_max_str_digits"):
    sys.set_int_max_str_digits(200000)

# self-bootstrap: find sympy/mpmath in the nix store (or any PYTHONPATH)
if not os.environ.get("SYMPY_NO_BOOTSTRAP"):
    try:
        import sympy, mpmath
    except ImportError:
        for p in glob.glob("/nix/store/*sympy-*/lib/python*/site-packages") + \
                  glob.glob("/nix/store/*mpmath-*/lib/python*/site-packages"):
            if p not in sys.path:
                sys.path.insert(0, p)

import mpmath as mp
import sympy as sp

# ---------- Layer A: numeric agreement ----------

def parse_koru(path):
    out = {}
    for line in open(path):
        line = line.strip()
        if re.match(r"^w\d+=", line):
            k, v = line.split("=", 1)
            out[k] = v
    return out

HERE = os.path.dirname(os.path.abspath(__file__))
koru_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "koru.out")
koru = parse_koru(koru_path)
ns = {}
exec(open(os.path.join(HERE, "operands.py")).read(), ns)
A2000, B2000 = int(ns["A2000"]), int(ns["B2000"])
A5000, B997 = int(ns["A5000"]), int(ns["B997"])

mp.mp.dps = 3100
t0 = time.perf_counter()
exact_refs = {  # exact ops compare as digit strings, mpf can't hold them
    "w1": str(A2000 * B2000),
    "w2": str(3**100000),
    "w9": str(A5000 % B997),
}
refs = {
    "w3": mp.mpf(A2000) / mp.mpf(B2000),
    "w4": mp.sqrt(2),
}
mp_times = {}
mp.mp.dps = 2100
for k, fn in [("w5", lambda: mp.exp(1)), ("w6", lambda: mp.log(2)),
              ("w7", lambda: mp.sin(1)),
              ("w8", lambda: 16 * mp.atan(mp.mpf("0.2")) - 4 * mp.atan(mp.mpf(1) / 239)),
              ("w10", lambda: mp.power(2, mp.mpf("0.5")))]:
    t = time.perf_counter()
    refs[k] = fn()
    mp_times[k] = (time.perf_counter() - t) * 1000
print(f"[mpmath] reference computation: {(time.perf_counter()-t0)*1000:.0f} ms total")

def koru_digits(v):
    """'m<digits>e<exp>' -> digit string with leading zeros stripped."""
    m = re.match(r"^(-?)(\d*)\.?(\d*)e(-?\d+)$", v.strip())
    if not m:
        return v.strip().lstrip("-").lstrip("0") or "0"
    neg, a, b, e = m.groups()
    digits = (a + b).lstrip("0")
    shift = int(e) + len(a) - len((a + b))
    if shift >= 0:
        digits += "0" * shift
    else:
        digits = digits[:shift] if -shift < len(digits) else "0"
    return digits.lstrip("0") or "0"

def agree_digits(kval, ref):
    """Decimal digits of agreement between koru text and mpf reference."""
    try:
        kv = mp.mpf(kval)
    except Exception:
        return -1, "unparseable"
    if ref == 0:
        return (float("inf") if kv == 0 else 0), ""
    r = abs((kv - ref) / ref)
    if r == 0:
        return float("inf"), "exact"
    return -mp.log10(r), ""

def koru_mantissa(v):
    m = re.match(r"^(-?)(\d*)\.?(\d*)e(-?\d+)$", v.strip())
    if not m:
        return None, None
    return m.group(2) + m.group(3), int(m.group(4))

print("\n=== Layer A: koru vs mpmath ===")
for k in ["w1", "w2", "w9"]:
    kd, rd = koru_digits(koru[k]), exact_refs[k]
    n = 0
    while n < min(len(kd), len(rd)) and kd[n] == rd[n]:
        n += 1
    total = len(rd)
    print(f"{k}: {n}/{total} digits agree" + ("  EXACT" if kd == rd else ""))
# koru emits the floor-magnitude prefix — the first `prec` digits of the
# true expansion, error-bound-checked via the Fx layer (same contract as
# div/sqrt). The honest check is pure prefix agreement: every emitted
# digit must be a digit of the true expansion.
for k in ["w3", "w4", "w5", "w6", "w7", "w8", "w10"]:
    if k not in koru:
        print(f"{k}: MISSING")
        continue
    kd, e = koru_mantissa(koru[k])
    rs = mp.nstr(refs[k], len(kd) + 40).replace(".", "").lstrip("0")
    n = 0
    while n < min(len(kd), len(rs)) and kd[n] == rs[n]:
        n += 1
    mpt = f"  (mpmath: {mp_times[k]:.1f} ms)" if k in mp_times else ""
    status = "  TRUE PREFIX" if n == len(kd) else f"  DIVERGES AT DIGIT {n + 1}"
    print(f"{k}: {n}/{len(kd)} prefix digits{status}{mpt}")

# ---------- Layer B: symbolic annihilation ----------

x = sp.symbols("x")

def check_ode(name, coeffs, f):
    """sum_i p_i(x) f^(i)(x) == 0?"""
    expr = sum(p * sp.diff(f, x, i) for i, p in enumerate(coeffs))
    res = sp.simplify(expr)
    print(f"  {name}: residual = {res}" + ("  OK" if res == 0 else "  FAIL"))

print("\n=== Layer B: ODE certs annihilate their functions? ===")
check_ode("exp law p0=-1 p1=1 on e^x",
          [-1, 1], sp.exp(x))
check_ode("shifted exp -h'+h'' on e^x",
          [0, -1, 1], sp.exp(x))
check_ode("sqrt cert -g+(2+2x)g' on (1+x)^(1/2)",
          [-1, 2 + 2 * x], sp.sqrt(1 + x))
check_ode("shifted sqrt -h'+(2+2x)h'' on (2/3)(1+x)^(3/2)",
          [0, -1, 2 + 2 * x], sp.Rational(2, 3) * (1 + x) ** sp.Rational(3, 2))
check_ode("sum exp+exp -f+f' on 2e^x",
          [-1, 1], 2 * sp.exp(x))
check_ode("prod exp*exp -2h+h' on e^(2x)",
          [-2, 1], sp.exp(2 * x))
check_ode("mixed sum cert on e^x + 1/(1-x)",
          [-1 - x, 1 + 2 * x - x**2, x**2 - x],
          sp.exp(x) + 1 / (1 - x))
check_ode("quartic cert -g+(4+4x)g' on (1+x)^(1/4)",
          [-1, 4 + 4 * x], (1 + x) ** sp.Rational(1, 4))
check_ode("shifted quartic -h'+(4+4x)h'' on (4/5)(1+x)^(5/4)",
          [0, -1, 4 + 4 * x], sp.Rational(4, 5) * (1 + x) ** sp.Rational(5, 4))
check_ode("inv cert -g+(1-x)g' on 1/(1-x)",
          [-1, 1 - x], 1 / (1 - x))
check_ode("shifted inv -h'+(1-x)h'' on -ln(1-x)",
          [0, -1, 1 - x], -sp.log(1 - x))
check_ode("x cert -f+xf' on x",
          [-1, x], x)  # xf'-f=0

print("\n=== recurrences on true coefficients ===")
ser_e = sp.series(sp.exp(x), x, 0, 10).removeO().as_poly(x)
ce = [ser_e.nth(i) for i in range(10)]
ok = all(sp.simplify(-ce[n] + (n + 1) * ce[n + 1]) == 0 for n in range(9))
print("  exp rec -a_n+(n+1)a_{n+1}=0 on series(e^x):", "OK" if ok else "FAIL")
ser_s = sp.series(sp.sqrt(1 + x), x, 0, 10).removeO().as_poly(x)
cs = [ser_s.nth(i) for i in range(10)]
ok = all(sp.simplify((2 * n + 1) * cs[n + 1] + (2 * n + 4) * cs[n + 2]) == 0
         for n in range(8))
print("  sqrt rec (2n+1)a_{n+1}+(2n+4)a_{n+2}=0 on series((1+x)^(1/2)):",
      "OK" if ok else "FAIL")
ser_c = sp.series(1 / (1 - x), x, 0, 10).removeO().as_poly(x)
cc = [ser_c.nth(i) for i in range(10)]
ok = all(sp.simplify((n + 2) * cc[n + 1] - (n + 2) * cc[n + 2]) == 0
         for n in range(8))
print("  inv rec (n+2)(a_{n+1}-a_{n+2})=0 on series(1/(1-x)):",
      "OK" if ok else "FAIL")

print("\n=== cser tail vs sympy series (sqrt(1+x)) ===")
# 615_047 generated cser coefficients for (1+x)^(1/2):
koru_tail = [sp.Rational(1), sp.Rational(1, 2), sp.Rational(-1, 8),
             sp.Rational(1, 16), sp.Rational(-5, 128), sp.Rational(7, 256)]
true_tail = [cs[i] for i in range(6)]
match = all(sp.simplify(koru_tail[i] - true_tail[i]) == 0 for i in range(6))
print("  koru cser coeffs == sympy series coeffs:", "OK" if match else "FAIL",
      koru_tail, "vs", true_tail)

print("\n=== rel-layer conservation ===")
r = sp.simplify(sp.diff(sp.sin(x) ** 2 + sp.cos(x) ** 2, x))
print("  D(sin^2+cos^2) residual:", r, "OK" if r == 0 else "FAIL")

print("\n=== decide-ode Airy sanity ===")
print("  dsolve(y''=xy) returns Airy (non-elementary, consistent with",
      "non-Liouvillian):", sp.dsolve(sp.Eq(sp.Function('y')(x).diff(x, 2), x * sp.Function('y')(x))))

print("\n=== Layer C: Hermite antiderivatives differentiate back (615_051) ===")
def check_anti(name, anti, f):
    res = sp.simplify(sp.diff(anti, x) - f)
    print(f"  {name}: d/dx(anti) - f = {res}" + ("  OK" if res == 0 else "  FAIL"))
check_anti("x/(1+x^2)^2 -> -1/(2(1+x^2))",
           -sp.Rational(1, 2) / (1 + x**2), x / (1 + x**2) ** 2)
check_anti("1/(2x+2)^2 -> -1/(4(1+x))",
           -sp.Rational(1, 4) / (1 + x), 1 / (2 * x + 2) ** 2)
check_anti("(x^4+1)/x^3 -> x^2/2 - 1/(2x^2)",
           x**2 / 2 - 1 / (2 * x**2), (x**4 + 1) / x**3)
check_anti("(x+1)/x^2 -> -1/x + log x (log part named as 1/x)",
           -1 / x + sp.log(x), (x + 1) / x**2)

print("\n=== Kovacic soundness: the formerly 'proven' cases have Liouvillian solutions ===")
check_ode("y'' = (x^2+1) y has exp(x^2/2)", [-(x**2 + 1), 0, 1], sp.exp(x**2 / 2))
check_ode("y'' = (2/x^2) y has x^2", [-2 / x**2, 0, 1], x**2)

print("\n=== Catalan (615_052) ===")
C = (1 - sp.sqrt(1 - 4 * x)) / (2 * x)
check_ode("catalan ode 2f + (-2+10x)f' + (-x+4x^2)f''", [2, -2 + 10 * x, -x + 4 * x**2], C)
ser_cat = sp.series(C, x, 0, 10).removeO().as_poly(x)
cat = [ser_cat.nth(i) for i in range(10)]
print("  series == catalan(n):", "OK" if cat == [sp.catalan(n) for n in range(10)] else "FAIL", cat)
ok = all(sp.simplify((4 * n**2 + 22 * n + 30) * sp.catalan(n + 2) - (n**2 + 7 * n + 12) * sp.catalan(n + 3)) == 0
         for n in range(20))
print("  bridge rec (4n^2+22n+30)a_{n+2} = (n^2+7n+12)a_{n+3} on catalan(n):", "OK" if ok else "FAIL")
r1 = sp.series((sp.sqrt(1 + x) - 1) / x, x, 0, 5).removeO().as_poly(x)
print("  (sqrt(1+x)-1)/x coeffs:", "OK" if [r1.nth(i) for i in range(5)] ==
      [sp.Rational(1, 2), -sp.Rational(1, 8), sp.Rational(1, 16), -sp.Rational(5, 128), sp.Rational(7, 256)] else "FAIL")
r2 = sp.series(x**2 * sp.sqrt(1 + x), x, 0, 5).removeO().as_poly(x)
print("  x^2 sqrt(1+x) coeffs:", "OK" if [r2.nth(i) for i in range(5)] ==
      [0, 0, 1, sp.Rational(1, 2), -sp.Rational(1, 8)] else "FAIL")
