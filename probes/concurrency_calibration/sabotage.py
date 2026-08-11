#!/usr/bin/env python3
"""
SABOTAGE HARNESS for the calibration counters in analyse.py.

Every case below feeds the counters an input they are OBLIGED to classify a
particular way, including inputs designed to make a plausible implementation
be WRONG. A counter that has only ever been watched agreeing is not a counter.

Each fixture is real Koru, spelled after a passing regression test (never
invented), written to a temp dir, parsed with `koruc --ast-canon`, and fed
through the exact functions analyse.py uses.

Run:  python3 sabotage.py
Exit 0 iff every case holds.
"""
import os, sys, json, subprocess, tempfile, shutil

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import analyse as A

TMP = tempfile.mkdtemp(prefix="koru-sabotage-")
CWD = os.path.join(TMP, "_cwd")
os.makedirs(CWD, exist_ok=True)

results = []


def canon(name, text):
    p = os.path.join(TMP, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write(text)
    r = subprocess.run(["koruc", "--ast-canon", p], cwd=CWD,
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return None, (r.stderr or "")[:400]
    try:
        return json.loads(r.stdout), None
    except Exception as e:
        return None, f"json: {e}"


def check(label, cond, detail=""):
    results.append((label, bool(cond), detail))
    print(("  PASS  " if cond else "  FAIL  ") + label + (("   " + detail) if detail else ""))


def facts(name, text):
    ast, err = canon(name, text)
    if ast is None:
        check(f"[fixture parses] {name}", False, err)
        return None
    return A.facts_of(ast)


# =====================================================================
print("=" * 70)
print("A. OPACITY COUNTER")
print("=" * 70)

PROC_ONE = """const std = @import("std");

~tor touch { n: i32 } -> i32
~proc touch|zig {
    return n + 1;
}

~touch(n: 1)
"""
f = facts("a1.kz", PROC_ONE)
if f:
    check("A1 one host proc is counted opaque", f.procs == 1, f"procs={f.procs}")
    check("A1 it is NOT counted pure", f.proc_pure == 0, f"pure={f.proc_pure}")
    check("A1 no subflow implementation invented", f.subflow_impls == 0,
          f"subflow={f.subflow_impls}")

PROC_PURE = PROC_ONE.replace("~proc touch|zig", "~[pure]proc touch|zig")
f = facts("a2.kz", PROC_PURE)
if f:
    check("A2 [pure] on the proc IS read", f.procs == 1 and f.proc_pure == 1,
          f"procs={f.procs} pure={f.proc_pure}")

# SABOTAGE: an annotation that merely CONTAINS the substring 'pure'.
PROC_IMPURE = PROC_ONE.replace("~proc touch|zig", "~[impure]proc touch|zig")
f = facts("a3.kz", PROC_IMPURE)
if f:
    check("A3 SABOTAGE [impure] must NOT count as pure", f.proc_pure == 0,
          f"pure={f.proc_pure}")

# SABOTAGE: 'pure' as one alternative inside a multi-annotation must still count,
# and a DIFFERENT annotation list must not.
PROC_MULTI = PROC_ONE.replace("~proc touch|zig", "~[norun|pure]proc touch|zig")
f = facts("a4.kz", PROC_MULTI)
if f:
    check("A4 pure inside a |-list IS read", f.proc_pure == 1, f"pure={f.proc_pure}")

PROC_NEAR = PROC_ONE.replace("~proc touch|zig", "~[purely]proc touch|zig")
f = facts("a5.kz", PROC_NEAR)
if f:
    check("A5 SABOTAGE [purely] must NOT count as pure", f.proc_pure == 0,
          f"pure={f.proc_pure}")

SUBFLOW = """import std/io

tor greet { name: string }
greet = std/io:print.ln("hi {{ name:s }}")

greet(name: "x")
"""
f = facts("a6.k", SUBFLOW)
if f:
    check("A6 a subflow implementation is TRANSPARENT, not a proc",
          f.procs == 0 and f.subflow_impls == 1,
          f"procs={f.procs} subflow={f.subflow_impls}")

TWO_PROCS = """const std = @import("std");

~tor a { n: i32 } -> i32
~proc a|zig { return n; }

~tor b { n: i32 } -> i32
~[pure]proc b|zig { return n; }

~a(n: 1)
"""
f = facts("a7.kz", TWO_PROCS)
if f:
    check("A7 two procs, one pure — no off-by-one",
          f.procs == 2 and f.proc_pure == 1, f"procs={f.procs} pure={f.proc_pure}")

HOSTVAR = """const std = @import("std");
var counter: i32 = 0;
const limit: i32 = 5;

~tor bump {} -> i32
~proc bump|zig {
    counter += 1;
    return counter;
}

~bump()
"""
f = facts("a8.kz", HOSTVAR)
if f:
    check("A8 module-level mutable host `var` is seen",
          f.host_var_globals == 1, f"var_globals={f.host_var_globals}")
    check("A8 SABOTAGE a `const` is NOT counted as mutable state",
          f.host_var_globals == 1, f"var_globals={f.host_var_globals}")

# =====================================================================
print()
print("=" * 70)
print("B. CALL-GRAPH RESOLVER")
print("=" * 70)

def resolve_all(f, extra_files=()):
    symtab, kw, mods = dict(f.syms), set(f.keywords), {f.module}
    for g in extra_files:
        symtab.update(g.syms); kw |= g.keywords; mods.add(g.module)
    out = []
    for inv in f.invs:
        ok, mk, d = A.resolve(inv, f.module, symtab, kw)
        out.append((f"{(mk + ':') if mk else ''}{d}", ok))
    return out

B1 = """import std/io

tor greet { name: string }
greet = std/io:print.ln("hi")

greet(name: "x")
"""
f = facts("b1.k", B1)
if f:
    r = dict(resolve_all(f))
    check("B1 a locally declared callee resolves", r.get("greet") is True, str(r))

# SABOTAGE: call a name nothing declares. MUST be unresolved.
B2 = """import std/io

std/io:print.ln("start")
totally-undeclared-event(x: 1)
"""
f = facts("b2.k", B2)
if f:
    r = dict(resolve_all(f))
    check("B2 SABOTAGE undeclared unqualified callee must NOT resolve",
          r.get("totally-undeclared-event") is False, str(r))

# SABOTAGE: qualified into a real module but a name that module does not declare.
# A resolver that falls back to the unqualified table would wrongly say yes.
B3 = """import std/io

tor nonexistent-thing { x: i32 }
nonexistent-thing = std/io:print.ln("local")

std/io:nonexistent-thing(x: 1)
"""
f = facts("b3.k", B3)
if f:
    r = dict(resolve_all(f))
    check("B3 SABOTAGE std/io:X must NOT resolve via a LOCAL X of the same name",
          r.get("io:nonexistent-thing") is False, str(r))

# SABOTAGE: a callee declared in a DIFFERENT program must not leak in.
B4a = """import std/io
tor only-in-a { x: i32 }
only-in-a = std/io:print.ln("a")
only-in-a(x: 1)
"""
B4b = """import std/io
std/io:print.ln("b")
only-in-a(x: 1)
"""
fa = facts("b4a.k", B4a)
fb = facts("b4b.k", B4b)
if fa and fb:
    r = dict(resolve_all(fb))
    check("B4 SABOTAGE a callee declared in ANOTHER program must not resolve",
          r.get("only-in-a") is False, str(r))

# B5: the resolver must not be so strict that a REAL sibling module fails.
# This is the shape --list-imports reports as a bare directory, which the first
# version of the dumper silently dropped (making 21 real edges look unresolvable).
B5LIB = """pub tor helper.run { x: i32 }
helper.run = std/io:print.ln("ran")
"""
B5ROOT = """import std/io
import app/lib/util

app/lib/util:helper.run(x: 1)
"""
flib = facts("lib/util.k", "import std/io\n" + B5LIB)
froot = facts("b5.k", B5ROOT)
if flib and froot:
    r_alone = dict(resolve_all(froot))
    check("B5 without the sibling module in the set, the edge is unresolved",
          r_alone.get("util:helper.run") is False, str(r_alone))
    r_with = dict(resolve_all(froot, extra_files=[flib]))
    check("B5b with the sibling module present, the edge resolves",
          r_with.get("util:helper.run") is True,
          str(r_with) + " libsyms=" + str(sorted(flib.syms)))

# B6: the single most load-bearing edge in the corpus. If `std/io:print.ln`
# did not resolve against the real koru_std/io.kz, the unresolved fraction
# would be dominated by one bug rather than by the language.
IO_KZ = os.path.join(A.STD, "io.kz")
if os.path.exists(IO_KZ):
    r = subprocess.run(["koruc", "--ast-canon", IO_KZ], cwd=CWD,
                       capture_output=True, text=True)
    fio = A.facts_of(json.loads(r.stdout)) if r.stdout.strip() else None
    fcall = facts("b6.k", "import std/io\nstd/io:print.ln(\"x\")\n")
    if fio and fcall:
        rr = dict(resolve_all(fcall, extra_files=[fio]))
        check("B6 std/io:print.ln resolves against the real koru_std/io.kz",
              rr.get("io:print.ln") is True, str(rr))
        rr2 = dict(resolve_all(facts("b7.k", "import std/io\nstd/io:print.no-such-verb(\"x\")\n"),
                               extra_files=[fio]))
        check("B7 SABOTAGE std/io:print.no-such-verb does NOT resolve",
              rr2.get("io:print.no-such-verb") is False, str(rr2))

# =====================================================================
print()
print("=" * 70)
print("C. STATE ATTRIBUTION")
print("=" * 70)

C1 = """import std/io
import std/store

std/store:new(own, capacity: 1) { epoch: 0[i64], etag: 0[i64] }

std/store:stored { own.etag: own.etag + 1 }
std/io:print.ln("etag is {{ own.etag:d }}")
"""
ast, err = canon("c1.k", C1)
if ast is None:
    check("[fixture parses] c1.k", False, err)
else:
    f = A.facts_of(ast)
    stores = A.store_decls(f.invs)
    check("C1 the store NAME is recovered from std/store:new",
          stores == {"own"}, str(stores))
    sites, kinds = __import__("collections").Counter(), __import__("collections").Counter()
    for inv in f.invs:
        for _k, txt in A.gather_arg_texts(inv):
            A.scan_text(txt, stores, sites, kinds)
    check("C1 a column read inside a {{ }} template is seen",
          kinds["column_ref_via_string_template"] >= 1, str(dict(kinds)))
    check("C1 a structured column touch is seen",
          kinds["column_ref_structured_text"] >= 1, str(dict(kinds)))

# SABOTAGE: identical shape but the store declaration is REMOVED.
# If the counters still report store touches, they are matching any dotted
# identifier and the attribution number is meaningless.
C2 = """import std/io

std/io:print.ln("etag is {{ own.etag:d }}")
std/io:print.ln("plain own.etag")
"""
ast, err = canon("c2.k", C2)
if ast is None:
    check("[fixture parses] c2.k", False, err)
else:
    f = A.facts_of(ast)
    stores = A.store_decls(f.invs)
    check("C2 SABOTAGE no std/store:new -> no store names", stores == set(), str(stores))
    sites, kinds = __import__("collections").Counter(), __import__("collections").Counter()
    for inv in f.invs:
        for _k, txt in A.gather_arg_texts(inv):
            A.scan_text(txt, stores, sites, kinds)
    check("C2 SABOTAGE undeclared `own.etag` must count as ZERO store touches",
          sum(sites.values()) == 0, str(dict(sites)))

# SABOTAGE: a dotted identifier that is NOT a store, in a program that HAS a store.
C3 = """import std/io
import std/store

std/store:new(own, capacity: 1) { epoch: 0[i64], etag: 0[i64] }

std/io:print.ln("other {{ notastore.etag:d }} and {{ own.epoch:d }}")
"""
ast, err = canon("c3.k", C3)
if ast is None:
    check("[fixture parses] c3.k", False, err)
else:
    f = A.facts_of(ast)
    stores = A.store_decls(f.invs)
    sites, kinds = __import__("collections").Counter(), __import__("collections").Counter()
    for inv in f.invs:
        for _k, txt in A.gather_arg_texts(inv):
            A.scan_text(txt, stores, sites, kinds)
    check("C3 SABOTAGE only the DECLARED store name counts (1, not 2)",
          sites["column_ref"] == 1, str(dict(sites)))

# C5: an exactly-known count. One write target, one read expression, one
# template read -> three touches, no more. Guards against the duplicate-view
# double count that C3 exposed.
C5 = """import std/io
import std/store

std/store:new(own, capacity: 1) { etag: 0[i64] }

std/store:stored { own.etag: own.etag + 1 }
std/io:print.ln("etag {{ own.etag:d }}")
"""
ast, err = canon("c5.k", C5)
if ast is None:
    check("[fixture parses] c5.k", False, err)
else:
    f = A.facts_of(ast)
    stores = A.store_decls(f.invs)
    sites, kinds = __import__("collections").Counter(), __import__("collections").Counter()
    for inv in f.invs:
        for _k, txt in A.gather_arg_texts(inv):
            A.scan_text(txt, stores, sites, kinds)
    check("C5 exact count: write target + read expr + template read = 3",
          sites["column_ref"] == 3, str(dict(kinds)))

# C6: the addressing spellings. `take(arena[e])` and `insert(arena)` both NAME
# a store; a matcher that only accepts `arena` or `arena.col` calls them
# unattributable, which is how 134 sites were miscounted.
C6 = """import std/io
import std/store

std/store:new(arena, capacity: 64) { hp: i64 }

std/store:insert(arena) { hp: 5 }
| row _ |> _
| full |> _

std/store:rule(arena)
! row e when e.hp <= 10 |> std/store:take(arena[e])
    | item i |> std/io:print.ln("took {{ i.hp:d }}")
"""
ast, err = canon("c6.k", C6)
if ast is None:
    check("[fixture parses] c6.k", False, err)
else:
    f = A.facts_of(ast)
    stores = A.store_decls(f.invs)
    check("C6 the store name is recovered", stores == {"arena"}, str(stores))
    verbs = {}
    for inv in f.invs:
        mk, d = A.dotted(inv["path"])
        if mk == "store" and d in A.STORE_VERBS:
            verbs[d] = A.verb_addresses_store(inv, stores)
    check("C6 insert(arena) is attributed", verbs.get("insert") == "arena", str(verbs))
    check("C6 rule(arena) is attributed", verbs.get("rule") == "arena", str(verbs))
    check("C6 take(arena[e]) is attributed through the subscript",
          verbs.get("take") == "arena", str(verbs))

# SABOTAGE: an identically-shaped program whose verbs address a store that was
# never declared must come back unattributed, not silently attributed to
# whatever store happens to exist.
C7 = """import std/store

std/store:new(arena, capacity: 64) { hp: i64 }
std/store:insert(other) { hp: 5 }
| row _ |> _
| full |> _
"""
ast, err = canon("c7.k", C7)
if ast is None:
    check("[fixture parses] c7.k", False, err)
else:
    f = A.facts_of(ast)
    stores = A.store_decls(f.invs)
    got = {}
    for inv in f.invs:
        mk, d = A.dotted(inv["path"])
        if mk == "store" and d in A.STORE_VERBS and d != "new":
            got[d] = A.verb_addresses_store(inv, stores)
    check("C7 SABOTAGE a verb naming an UNDECLARED store stays unattributed",
          got.get("insert") is None, str(got) + " stores=" + str(stores))

# SABOTAGE: `capacity:` is a keyword arg, never a store name.
C4 = """import std/store

std/store:new(reg, capacity: 4) { n: 0[i64] }
"""
ast, err = canon("c4.k", C4)
if ast is None:
    check("[fixture parses] c4.k", False, err)
else:
    f = A.facts_of(ast)
    stores = A.store_decls(f.invs)
    check("C4 SABOTAGE the `capacity` label is not mistaken for a store name",
          stores == {"reg"}, str(stores))

# =====================================================================
print()
print("=" * 70)
print("D. WALKER COVERAGE — invocations nested deep in a flow")
print("=" * 70)

D1 = """import std/io

tor pick { n: i64 }
| hi
| lo

pick = ~if(n > 5)
| then => hi
| else => lo

pick(n: 9)
| hi |> std/io:print.ln("hi")
| lo |> std/io:print.ln("lo")
"""
ast, err = canon("d1.k", D1)
if ast is None:
    check("[fixture parses] d1.k", False, err)
else:
    f = A.facts_of(ast)
    names = [A.dotted(i["path"])[1] for i in f.invs]
    check("D1 invocations in branch continuations are reached",
          names.count("print.ln") == 2, str(names))
    check("D1 the head invocation is reached", "pick" in names, str(names))

# =====================================================================
print()
ok = all(c for _l, c, _d in results)
bad = [l for l, c, _d in results if not c]
print("=" * 70)
print(f"{sum(1 for _l, c, _d in results if c)}/{len(results)} cases hold")
if bad:
    print("FAILING:")
    for b in bad:
        print("   -", b)
print(f"(fixtures under {TMP})")
sys.exit(0 if ok else 1)
