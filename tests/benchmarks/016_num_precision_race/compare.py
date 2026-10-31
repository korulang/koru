#!/usr/bin/env python3
import re, sys, os

B = os.path.dirname(os.path.abspath(__file__))

def digits_of(s):
    return re.sub(r"[^0-9]", "", s).lstrip("0")

def load_koru():
    d = {}
    for line in open(f"{B}/koru.out"):
        m = re.match(r"(w\d+)=(.*)", line.strip())
        if m:
            d[m.group(1)] = digits_of(m.group(2))
    return d

def load_bc():
    d = {}
    for w in [f"w{i}" for i in range(1, 11)]:
        raw = open(f"{B}/{w}.bc.out").read().replace("\\\n", "")
        d[w] = digits_of(raw)
    return d

def load_py():
    d = {}
    for line in open(f"{B}/py.out"):
        m = re.match(r"(w\d+i?)=(.*)", line.strip())
        if m:
            d[m.group(1)] = digits_of(m.group(2))
    return d

def common(a, b):
    n = 0
    for x, y in zip(a, b):
        if x != y:
            break
        n += 1
    return n

K, C, P = load_koru(), load_bc(), load_py()
print(f"{'work':5} {'koru-d':>8} {'bc-d':>8} {'py-d':>8} {'k=bc':>8} {'k=py':>8} {'bc=py':>8}")
for w in ["w1","w2","w3","w4","w5","w6","w7","w8","w9","w10"]:
    k, c, p = K.get(w, ""), C.get(w, ""), P.get(w, "")
    print(f"{w:5} {len(k):>8} {len(c):>8} {len(p):>8} "
          f"{common(k,c):>8} {common(k,p):>8} {common(c,p):>8}")
# int cross-checks
for pair in [("w1","w1i"), ("w2","w2i"), ("w4","w4i")]:
    a, b = pair
    if a in K and b in P:
        print(f"{a} vs {b}(py-int): common={common(K[a], P[b])} koru={len(K[a])} py={len(P[b])}")
if "w9" in K and "w9" in P:
    print(f"w9 vs py-int: common={common(K['w9'], P['w9'])} koru={len(K['w9'])} py={len(P['w9'])}")
