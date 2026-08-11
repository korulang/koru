#!/usr/bin/env python3
"""
Calibration probe: how analysable is Koru's call graph and state surface?

Reads the --ast-canon dumps produced by dump_asts.sh + dump_dirs.sh and answers
three questions over the whole tests/regression corpus:

  1. OPACITY            — how much implementation sits behind an opaque host proc
  2. RESOLVABILITY      — can each call site's callee be named statically
  3. STATE ATTRIBUTION  — can each state touch be attributed to a named store

Nothing here inserts a lock or changes the compiler. It only counts.

Run:  python3 analyse.py <dumpdir> [--selftest]
"""
import json, os, sys, re, collections

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STD = os.path.join(REPO, "koru_std")

STORE_MOD = "store"
STORE_VERBS = {"new", "insert", "stored", "query", "watch", "take", "rule",
               "stripe", "preorder", "taken", "sweep", "clear", "default"}

PURE_ANN = re.compile(r"(^|\|)pure($|\|)")
HOST_VAR = re.compile(r"^\s*(pub\s+)?(threadlocal\s+)?var\s+[A-Za-z_]")
IDENT_DOT = re.compile(r"(?<![A-Za-z0-9_.])([a-z_][A-Za-z0-9_-]*)\.([a-z_][A-Za-z0-9_-]*)")
INTERP = re.compile(r"\{\{\s*([^}]*?)\s*\}\}")
NAME_RX = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*$")
TOKEN_RX = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")


def verb_addresses_store(inv, stores):
    """Which declared store does this store verb address?

    The addressing spellings in the corpus are `insert(arena)`, `take(arena[e])`,
    `rule(arena)`, `query(arena)` and `stored { arena.hp: ... }` — a bare name, a
    name with a row subscript, or a dotted column. Matching only the first two
    shapes reported 134 store verbs as unattributable that plainly name a store;
    tokenise instead."""
    for _k, txt in gather_arg_texts(inv):
        for t in TOKEN_RX.findall(txt or ""):
            if t in stores:
                return t
    return None


# ------------------------------------------------------------------ ast basics

def items_of(ast):
    return (ast or {}).get("items", []) or []


def tag(item):
    if isinstance(item, str):
        return item, None
    if isinstance(item, dict) and len(item) == 1:
        k = next(iter(item))
        return k, item[k]
    return None, item


def dotted(path):
    """DottedPath -> (module_key, 'a.b'); module_key is the LAST segment of the
    qualifier, which is how EventDecl.module is spelled ('std.store' -> 'store')."""
    if not path:
        return None, None
    q = path.get("module_qualifier")
    segs = path.get("segments") or []
    mk = q.split(".")[-1].split("/")[-1] if q else None
    return mk, ".".join(segs)


def walk_nodes(o, invocations, exprtexts, conditions):
    if isinstance(o, dict):
        for k, v in o.items():
            if k == "invocation" and isinstance(v, dict) and "path" in v:
                invocations.append(v)
            elif k == "condition" and isinstance(v, str):
                conditions.append(v)
            elif k in ("expression", "iterable", "expression_str") and isinstance(v, str):
                exprtexts.append(v)
            walk_nodes(v, invocations, exprtexts, conditions)
    elif isinstance(o, list):
        for x in o:
            walk_nodes(x, invocations, exprtexts, conditions)


def gather_arg_texts(inv):
    """Distinct free-text fragments carried by an invocation's arguments.

    `value`, `source_value.text` and `expression_value.text` are three views of
    the SAME authored text for most arguments; counting all three inflated every
    state number by ~2x until sabotage case C3 caught it. Dedupe per argument,
    but keep `name` separate from `value` — for `std/store:stored { s.c: s.c+1 }`
    the name is the WRITE target and the value is the READ, two real touches."""
    ts = []
    for a in inv.get("args") or []:
        seen = set()
        cand = []
        if isinstance(a.get("name"), str):
            cand.append(("name", a["name"]))
        if isinstance(a.get("value"), str):
            cand.append(("value", a["value"]))
        for k in ("source_value", "expression_value"):
            sv = a.get(k)
            if isinstance(sv, dict) and isinstance(sv.get("text"), str):
                cand.append((k, sv["text"]))
        for k, txt in cand:
            if txt in seen:
                continue
            seen.add(txt)
            ts.append((k, txt))
    return ts


# ------------------------------------------------------------------ per file

class FileFacts:
    __slots__ = ("module", "procs", "proc_pure", "proc_targets", "subflow_impls",
                 "host_lines", "host_var_globals", "events", "parse_errors",
                 "syms", "keywords", "invs", "exprs", "conds", "field_kinds",
                 "comptime_events", "body_stmts", "body_probe")


# HEURISTIC, and labelled as one wherever it is reported. The compiler does
# none of this: a proc body is an opaque string forwarded to the host. These
# probes only answer "if we DID write a host-language analyser, how much of
# what is in there would be state-touching?"
BODY_PROBES = (
    ("allocator/heap", re.compile(r"\ballocator\b|Allocator|page_allocator|\.alloc\(|\.create\(|\.dupe\(|\.destroy\(|\.free\(")),
    ("pointer deref/cast", re.compile(r"\.\*|@ptrCast|@ptrFromInt|@alignCast|\banyopaque\b")),
    ("io / syscall", re.compile(r"posix\.|std\.fs|std\.io|std\.debug\.print|std\.process|fputs|write\(")),
    ("thread / atomic", re.compile(r"@atomic|std\.Thread|Mutex|std\.atomic|cmpxchg")),
    ("extern / C", re.compile(r"\bextern\b|@cImport|@extern")),
    ("assignment to a non-local", re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z0-9_.\[\]]*\s*(\+|-|\*|/|\|)?=[^=]", re.M)),
)
STMT_RX = re.compile(r";")


# A parameter's type decides whether the callee's reach is nameable.
# A value parameter is a copy: the callee can touch nothing the caller owns.
# A pointer parameter hands over an address; `*anyopaque` hands over an address
# with the type erased, which is the maximal case -- nothing downstream can be
# attributed to anything.
COMPTIME_TYPES = {"Source", "Expression", "*const Invocation", "*const Item",
                  "*const Program", "*ErrorReporter", "std.mem.Allocator",
                  "*const EventDecl", "Program"}


def classify_field_type(t):
    t = (t or "").strip()
    if not t:
        return "untyped"
    if t in COMPTIME_TYPES:
        return "comptime-only handle"
    if "anyopaque" in t:
        return "*anyopaque (type erased)"
    if t.startswith("*") or t.startswith("?*") or t.startswith("[]") or t.startswith("?[]"):
        return "pointer/slice"
    if t.startswith("[") and "]" in t:
        return "array"
    return "value"


def facts_of(ast):
    f = FileFacts()
    f.module = (ast or {}).get("main_module_name") or ""
    f.procs = 0; f.proc_pure = 0; f.proc_targets = collections.Counter()
    f.subflow_impls = 0; f.host_lines = 0; f.host_var_globals = 0
    f.events = 0; f.parse_errors = 0
    f.syms = {}          # (module_key, dotted) -> True
    f.keywords = set()   # dotted names callable unqualified from any importer
    f.field_kinds = collections.Counter()
    f.comptime_events = 0
    f.body_stmts = 0
    f.body_probe = collections.Counter()

    for it in items_of(ast):
        t, v = tag(it)
        if t == "proc_decl":
            f.procs += 1
            anns = v.get("annotations") or []
            if v.get("is_pure") or any(PURE_ANN.search(a) for a in anns):
                f.proc_pure += 1
            f.proc_targets[v.get("target") or "zig(default)"] += 1
            body = ((v.get("body") or {}).get("text")) or ""
            f.body_stmts += len(STMT_RX.findall(body))
            hit = False
            for nm, rx in BODY_PROBES:
                if rx.search(body):
                    f.body_probe[nm] += 1
                    hit = True
            f.body_probe["ANY state-shaped construct" if hit else "no state-shaped construct"] += 1
        elif t == "flow":
            if v.get("impl_of"):
                f.subflow_impls += 1
        elif t == "host_line":
            f.host_lines += 1
            if HOST_VAR.match(v.get("content") or ""):
                f.host_var_globals += 1
        elif t == "parse_error":
            f.parse_errors += 1
        elif t == "event_decl":
            f.events += 1
            mk, d = dotted(v.get("path"))
            home = v.get("module") or f.module
            f.syms[(mk or home, d)] = True
            f.syms[(home, d)] = True
            anns = v.get("annotations") or []
            if any(re.search(r"(^|\|)keyword($|\|)", a) for a in anns):
                f.keywords.add(d)
            if any(re.search(r"(^|\|)comptime($|\|)", a) for a in anns):
                f.comptime_events += 1
            for fld in ((v.get("input") or {}).get("fields") or []):
                f.field_kinds[classify_field_type(fld.get("type"))] += 1
            if v.get("return_type"):
                f.field_kinds["RET:" + classify_field_type(v.get("return_type"))] += 1

    invs, exprs, conds = [], [], []
    walk_nodes(items_of(ast), invs, exprs, conds)
    f.invs, f.exprs, f.conds = invs, exprs, conds
    return f


# ------------------------------------------------------------------ resolution

def resolve(inv, caller_module, symtab, keywords):
    """Can this call site's callee be named statically? -> (ok, module_key, dotted)"""
    mk, d = dotted(inv.get("path"))
    if mk:
        ok = (mk, d) in symtab
    else:
        ok = ((caller_module, d) in symtab) or (d in keywords) or ((None, d) in symtab)
    return ok, mk, d


def classify_unresolved(mk, d, inv, known_modules):
    if mk == STORE_MOD and d in STORE_VERBS:
        return "store keyword (comptime transform)"
    if inv.get("variant"):
        return "variant selector on the call site (~e|variant)"
    if inv.get("inserted_by_tap"):
        return "inserted by a tap"
    if inv.get("inline_body") is not None:
        return "already transform-replaced (inline_body set)"
    if d and d.startswith("__"):
        return "compiler-synthesised name"
    if mk and mk not in known_modules:
        return "qualified into a module with no parsed source"
    if mk:
        return "qualified, module parsed, name absent"
    return "unqualified, no declaration in the program"


# ------------------------------------------------------------------ state

def store_decls(invocations):
    names = set()
    for inv in invocations:
        mk, d = dotted(inv.get("path"))
        if mk == STORE_MOD and d == "new":
            for a in inv.get("args") or []:
                if a.get("had_explicit_label"):
                    continue
                v = (a.get("value") or "").strip()
                if v and NAME_RX.fullmatch(v):
                    names.add(v)
                    break
    return names


def scan_text(txt, stores, sites, kinds):
    """count store column touches reachable from a free-text fragment"""
    if not txt:
        return
    for m in INTERP.finditer(txt):
        for mm in IDENT_DOT.finditer(m.group(1)):
            if mm.group(1) in stores:
                sites["column_ref"] += 1
                kinds["column_ref_via_string_template"] += 1
    for mm in IDENT_DOT.finditer(INTERP.sub("  ", txt)):
        if mm.group(1) in stores:
            sites["column_ref"] += 1
            kinds["column_ref_structured_text"] += 1


# ------------------------------------------------------------------ driver

def load_index(dumpdir, sub):
    d = os.path.join(dumpdir, sub)
    out, failed = {}, []
    for fn in os.listdir(d):
        if not fn.endswith(".path"):
            continue
        src = open(os.path.join(d, fn)).read().strip()
        try:
            out[src] = json.load(open(os.path.join(d, fn[:-5] + ".json")))
        except Exception:
            failed.append(src)
    return out, failed


def is_std(p):
    return p.startswith(STD + os.sep)


def run(dumpdir):
    asts, ast_failed = load_index(dumpdir, "ast")
    imports, _ = load_index(dumpdir, "imports")
    # One entry per test directory, chosen the way the harness itself chooses
    # it (scripts/regression_lib.sh:77 test_entry): input.kz if present, else
    # input.k. A directory holding both holds ONE module in two facets, not two
    # programs -- counting both double-counts every call site in it.
    raw_roots = [l.strip() for l in open(os.path.join(dumpdir, "roots.txt")) if l.strip()]
    by_dir = collections.defaultdict(list)
    for r in raw_roots:
        by_dir[os.path.dirname(r)].append(r)
    roots = []
    for d, rs in by_dir.items():
        kz = os.path.join(d, "input.kz")
        roots.append(kz if kz in rs else sorted(rs)[0])
    roots.sort()

    def load_tsv(name):
        m = collections.defaultdict(list)
        p = os.path.join(dumpdir, name)
        if os.path.exists(p):
            for line in open(p):
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 2:
                    m[parts[0]].append(parts[1])
        return m

    dirmembers = load_tsv("dirmembers.tsv")   # directory import -> its files
    siblings = load_tsv("siblings.tsv")       # file -> same-stem sibling files

    FACTS = {p: facts_of(a) for p, a in asts.items()}

    R = {}
    R["files_parsed"] = len(FACTS)
    R["files_refused"] = len(set(ast_failed))
    R["roots"] = roots
    R["roots_parsed"] = [r for r in roots if r in FACTS]
    R["roots_refused"] = [r for r in roots if r not in FACTS]

    # ---------------- 1. opacity (per distinct file, dedup) ----------------
    def agg(paths):
        a = collections.Counter()
        t = collections.Counter()
        k = collections.Counter()
        b = collections.Counter()
        for p in paths:
            f = FACTS[p]
            a["procs"] += f.procs; a["proc_pure"] += f.proc_pure
            a["subflow_impls"] += f.subflow_impls
            a["host_lines"] += f.host_lines
            a["host_var_globals"] += f.host_var_globals
            a["events"] += f.events
            a["comptime_events"] += f.comptime_events
            a["body_stmts"] += f.body_stmts
            t.update(f.proc_targets)
            b.update(f.body_probe)
            k.update(f.field_kinds)
        a["field_kinds"] = 0
        return a, t, k, b

    app_files = [p for p in FACTS if not is_std(p)]
    std_files = [p for p in FACTS if is_std(p)]
    R["opacity"] = {
        "app": agg(app_files),
        "std": agg(std_files),
        "all": agg(list(FACTS)),
    }
    R["targets"] = agg(list(FACTS))[1]
    R["body_probe"] = agg(list(FACTS))[3]
    R["field_kinds_app"] = agg(app_files)[2]
    R["field_kinds_std"] = agg(std_files)[2]

    # ---------------- 2. resolvability (per program, app files) ------------
    call_total = call_unres = 0
    reasons = collections.Counter()
    unres_names = collections.Counter()
    examples = collections.defaultdict(list)
    per_prog = []
    state_sites = collections.Counter()
    state_kinds = collections.Counter()
    unnamed_verbs = collections.Counter()
    store_decl_count = 0
    progs_with_stores = 0

    for root in R["roots_parsed"]:
        imps = imports.get(root) or []
        if not isinstance(imps, list):
            imps = []
        files = [root]
        for m in imps:
            if m in FACTS:
                files.append(m)
            elif m in dirmembers:
                files.extend([x for x in dirmembers[m] if x in FACTS])
        # A module can span several same-stem files -- helper.kz declares the
        # event, helper.kjs carries the |js proc body, and the import merges
        # them (110_001_file_import_basic). `--list-imports` names only one of
        # them, so a symbol table built from its output is missing the very
        # declaration the call site needs. Same rule applies to the root.
        for f in list(files):
            files.extend([x for x in siblings.get(f, []) if x in FACTS])
        files = list(dict.fromkeys(files))

        symtab, keywords, known_modules = {}, set(), set()
        for f in files:
            ff = FACTS[f]
            symtab.update(ff.syms)
            keywords |= ff.keywords
            if ff.module:
                known_modules.add(ff.module)
            for (mk, _d) in ff.syms:
                if mk:
                    known_modules.add(mk)

        all_invs = []
        for f in files:
            all_invs.extend(FACTS[f].invs)
        stores = store_decls(all_invs)
        store_decl_count += len(stores)
        if stores:
            progs_with_stores += 1

        prog_files = [f for f in files if not is_std(f)]
        pc = pu = 0
        for f in prog_files:
            ff = FACTS[f]
            for inv in ff.invs:
                pc += 1
                ok, mk, d = resolve(inv, ff.module, symtab, keywords)
                if not ok:
                    pu += 1
                    r = classify_unresolved(mk, d, inv, known_modules)
                    reasons[r] += 1
                    unres_names[(r, f"{(mk + ':') if mk else ''}{d}")] += 1
                    if len(examples[r]) < 6:
                        examples[r].append(
                            f"{(mk + ':') if mk else ''}{d}   [{os.path.relpath(f, REPO)}]")
                # state attribution
                if mk == STORE_MOD and d in STORE_VERBS:
                    state_sites["store_verb"] += 1
                    named = (d == "new") or (verb_addresses_store(inv, stores) is not None)
                    state_kinds["store_verb_named" if named else "store_verb_UNNAMED"] += 1
                    if not named:
                        unnamed_verbs[d] += 1
                for _k, txt in gather_arg_texts(inv):
                    scan_text(txt, stores, state_sites, state_kinds)
            for txt in ff.exprs + ff.conds:
                scan_text(txt, stores, state_sites, state_kinds)
        call_total += pc
        call_unres += pu
        per_prog.append((root, pc, pu, len(stores)))

    R["calls"] = (call_total, call_unres)
    R["reasons"] = reasons
    R["unres_names"] = unres_names
    R["examples"] = examples
    R["per_prog"] = per_prog
    R["state_sites"] = state_sites
    R["state_kinds"] = state_kinds
    R["unnamed_verbs"] = unnamed_verbs
    R["stores_declared"] = store_decl_count
    R["progs_with_stores"] = progs_with_stores

    # ---------------- std internals, counted once --------------------------
    ssym, skw, smod = {}, set(), set()
    for f in std_files:
        ssym.update(FACTS[f].syms); skw |= FACTS[f].keywords
        if FACTS[f].module:
            smod.add(FACTS[f].module)
    sc = su = 0
    sreasons = collections.Counter()
    for f in std_files:
        ff = FACTS[f]
        for inv in ff.invs:
            sc += 1
            ok, mk, d = resolve(inv, ff.module, ssym, skw)
            if not ok:
                su += 1
                sreasons[classify_unresolved(mk, d, inv, smod)] += 1
    R["std_calls"] = (sc, su)
    R["std_reasons"] = sreasons
    return R, FACTS


def pct(a, b):
    return f"{100.0 * a / b:.1f}%" if b else "n/a"


def report(R):
    o = R["opacity"]
    print("=" * 78)
    print("CORPUS")
    print("=" * 78)
    print(f"  test roots enumerated            : {len(R['roots'])}")
    print(f"  ... parsed                       : {len(R['roots_parsed'])}")
    print(f"  ... REFUSED by the parser        : {len(R['roots_refused'])}"
          "   (MUST_ERROR programs; excluded from every count below)")
    print(f"  distinct source files parsed     : {R['files_parsed']}")
    print(f"  distinct source files refused    : {R['files_refused']}")
    print()

    print("=" * 78)
    print("1. OPACITY — implementation behind a host body the compiler cannot read")
    print("=" * 78)
    for label, key in (("APP (tests/regression)", "app"), ("KORU_STD", "std"), ("BOTH", "all")):
        a, _t, _k, _b = o[key]
        impl = a["procs"] + a["subflow_impls"]
        print(f"  {label}")
        print(f"    event declarations                          : {a['events']}")
        print(f"    subflow implementations (transparent Koru)  : {a['subflow_impls']}")
        print(f"    proc implementations   (opaque host body)   : {a['procs']}")
        print(f"      of those declaring themselves pure        : {a['proc_pure']}")
        print(f"    OPACITY  opaque / all implementations       : {a['procs']}/{impl} = {pct(a['procs'], impl)}")
        print(f"    opaque AND not pure                         : {a['procs'] - a['proc_pure']}/{impl} = {pct(a['procs'] - a['proc_pure'], impl)}")
        print(f"    raw host_line items                         : {a['host_lines']}")
        print(f"      of those module-level mutable `var`       : {a['host_var_globals']}")
        print()
    print(f"  proc bodies by host target: {dict(R['targets'])}")
    a_all = o["all"][0]
    print(f"  `;`-terminated statements inside those opaque bodies: {a_all['body_stmts']}")
    print("  HEURISTIC host-body scan (the compiler does NONE of this — a proc")
    print("  body is an opaque string; this only asks what WOULD be in there):")
    for k2, c2 in R["body_probe"].most_common():
        print(f"    {k2:32s} {c2:6d} procs  ({pct(c2, a_all['procs'])})")
    print()

    print("=" * 78)
    print("2. CALL-GRAPH RESOLVABILITY")
    print("=" * 78)
    ct, cu = R["calls"]
    print(f"  APP call sites (each program resolved against its own import set)")
    print(f"    total      : {ct}")
    print(f"    unresolved : {cu} = {pct(cu, ct)}")
    for r, c in R["reasons"].most_common():
        print(f"      {c:7d}  {pct(c, ct):>6}  {r}")
        top = [(n, c2) for (rr, n), c2 in R["unres_names"].most_common() if rr == r][:12]
        for n, c2 in top:
            print(f"                          {c2:5d} x  {n}")
    sc, su = R["std_calls"]
    print(f"  KORU_STD internal call sites (counted once, not per program)")
    print(f"    total      : {sc}")
    print(f"    unresolved : {su} = {pct(su, sc)}")
    for r, c in R["std_reasons"].most_common():
        print(f"      {c:7d}  {pct(c, sc):>6}  {r}")
    print()

    print("=" * 78)
    print("3. STATE ATTRIBUTION")
    print("=" * 78)
    tot = sum(R["state_sites"].values())
    print(f"  programs declaring at least one store : {R['progs_with_stores']}")
    print(f"  store declarations (summed)           : {R['stores_declared']}")
    print(f"  Koru-visible state touches            : {tot}")
    for k, c in R["state_sites"].most_common():
        print(f"    {k:16s} {c}")
    print("  breakdown:")
    for k, c in R["state_kinds"].most_common():
        print(f"    {k:32s} {c:6d}  ({pct(c, tot)})")
    if R["unnamed_verbs"]:
        print(f"    unattributable verbs by name: {dict(R['unnamed_verbs'])}")
    print()
    print("  3b. PARAMETER REACH — what a callee can touch that the caller owns")
    for lbl, kk in (("APP", "field_kinds_app"), ("KORU_STD", "field_kinds_std")):
        fk = R[kk]
        n = sum(c for k, c in fk.items() if not k.startswith("RET:"))
        print(f"    {lbl}: {n} event input fields")
        for k, c in sorted(fk.items()):
            if k.startswith("RET:"):
                continue
            print(f"      {k:26s} {c:6d}  ({pct(c, n)})")
        ptr = sum(c for k, c in fk.items()
                  if not k.startswith("RET:") and k in ("pointer/slice", "*anyopaque (type erased)"))
        print(f"      -> ADDRESS-CARRYING (unattributable): {ptr}/{n} = {pct(ptr, n)}")
    print()

    a, _t2, _k2, _b2 = o["all"]
    opaque = a["procs"] - a["proc_pure"]
    denom = opaque + tot
    print("=" * 78)
    print("HEADLINE — the CAN'T-TELL fraction")
    print("=" * 78)
    print("  Population: every effectful leaf a concurrent-region colouring must")
    print("  assign a lockset to.")
    print(f"    opaque host proc bodies not declared pure : {opaque}")
    print(f"    Koru-visible named-store touches          : {tot}")
    print(f"    TOTAL                                     : {denom}")
    print(f"  CAN'T-TELL = the opaque bodies              : {opaque} = {pct(opaque, denom)}")
    print()


if __name__ == "__main__":
    R, _F = run(sys.argv[1])
    report(R)
