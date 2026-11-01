"""qcalc race: random ops vs an exact Fraction oracle, plus throughput."""
import os, random, subprocess, sys, time
from fractions import Fraction
from decimal import Decimal, getcontext

getcontext().prec = 60
random.seed(int(sys.argv[2]) if len(sys.argv) > 2 else 7)
N = int(sys.argv[1]) if len(sys.argv) > 1 else 2000

DIMS = ["m", "s", "kg", "A", "K", "mol", "cd"]
UNITS = {  # unit -> (scale, dim vector)
    "m": (Fraction(1), (1, 0, 0, 0, 0, 0, 0)),
    "s": (Fraction(1), (0, 1, 0, 0, 0, 0, 0)),
    "kg": (Fraction(1), (0, 0, 1, 0, 0, 0, 0)),
    "g": (Fraction(1, 1000), (0, 0, 1, 0, 0, 0, 0)),
    "N": (Fraction(1), (1, -2, 1, 0, 0, 0, 0)),
    "J": (Fraction(1), (2, -2, 1, 0, 0, 0, 0)),
    "m/s": (Fraction(1), (1, -1, 0, 0, 0, 0, 0)),
    "A": (Fraction(1), (0, 0, 0, 1, 0, 0, 0)),
}

def rnd_mag():
    k = random.random()
    if k < 0.3:
        return str(random.randint(-10**6, 10**6))
    if k < 0.6:
        return f"{random.randint(-10**9, 10**9)}.{random.randint(0, 10**6):06d}"
    if k < 0.8:
        return str(random.randint(10**25, 10**30))
    return f"0.{random.randint(1, 10**8):08d}"

lines, want = [], []
for _ in range(N):
    ua, ub = random.choice(list(UNITS)), random.choice(list(UNITS))
    op = random.choice(["add", "sub", "mul", "div"])
    if op in ("add", "sub") and random.random() < 0.7:
        ub = ua
    a, b = rnd_mag(), rnd_mag()
    lines.append(f"{a} {ua} ; {op} ; {b} {ub}")
    sa, da = UNITS[ua]; sb, db = UNITS[ub]
    fa, fb = Fraction(Decimal(a)) * sa, Fraction(Decimal(b)) * sb
    if op in ("add", "sub"):
        if da != db:
            want.append(("dim-mismatch",)); continue
        want.append(("val", fa + fb if op == "add" else fa - fb, da))
    elif op == "mul":
        want.append(("val", fa * fb, tuple(x + y for x, y in zip(da, db))))
    else:
        if fb == 0:
            want.append(("div-zero",)); continue
        want.append(("val", fa / fb, tuple(x - y for x, y in zip(da, db)), "approx"))

inp = "\n".join(lines) + "\n"
t0 = time.perf_counter()
out = subprocess.run([os.environ.get("QCALC", "./a.out")], input=inp.encode(), capture_output=True).stdout.decode().splitlines()
dt = time.perf_counter() - t0

bad = 0
for ln, w, got in zip(lines, want, out):
    ok = False
    if w[0] in ("dim-mismatch", "div-zero"):
        ok = got == w[0]
    else:
        parts = got.split("|")
        if len(parts) == 3:
            mag = Fraction(Decimal(parts[0]))
            dims = tuple(int(t.split("^")[1]) for t in parts[1].split())
            dims = tuple(dims[DIMS.index(n)] for n in DIMS)
            if len(w) == 4:  # div at 25 significant digits
                ok = dims == w[2] and (w[1] == 0 and mag == 0 or abs((mag - w[1]) / w[1]) < Fraction(1, 10**23))
            else:
                ok = dims == w[2] and mag == w[1]
    if not ok:
        bad += 1
        if bad <= 8:
            print("MISMATCH:", ln, "| got:", got, "| want:", w)
print(f"lines={N} outputs={len(out)} mismatches={bad} wall={dt:.3f}s per-line={dt / N * 1e6:.1f}us")
