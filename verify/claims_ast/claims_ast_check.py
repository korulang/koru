#!/usr/bin/env python3
"""claims_ast_check.py — artifact re-derivation oracle for the claims wire.

The claims pass commits `[claim-check]`/`[claim-term]`/`[claim-goal]`/
`[claim-head]`/`[claim-edge]`/`[claim-census]` lines under
`std/witness:enforce`. `verify/claims/ClaimsCheck.lean` re-decides the FM
entailment *given* the committed rows; this oracle re-decides the rows
themselves — it re-runs the claims extraction against `program.ast.json`
(the serialized frontend->backend AST) and requires the committed
pre-image to match the artifact's own derivation, line for line.

The port is faithful, not approximate: the same refusal reasons, the same
DNF clause order, the same candidate order, the same discharge loop, the
same verdict detail strings. The source boundary is split, not trusted:
`program.ast.json` precedes `run-pre-transforms` inside `elaborate` while
`pass-claims-check` reads `mutable_ctx.ast` after it. With
`--premises <program.pre-claims.ast.json>` (the boundary snapshot the
analysis chain writes under witness enforcement — the pass's real input),
premise rows derive from that tree. Claim SITES always come from
`program.ast.json`: the `std.spec:claim` flow is consumed before the
claims pass runs, so only the frontend artifact still carries it.

Usage:
    claims_ast_check.py <program.ast.json> <backend.err> [--premises snap.json]
    claims_ast_check.py --selfcheck <dir-with-fixture-pair> [...]

Exit 0 = every committed claim line re-derived from the artifact.
Exit 1 = at least one fidelity failure.
"""

import json
import re
import sys

# ============================================================================
# spec.linear — the shared integer-linear grammar (spec.linear.kz), ported.
# LinPart = (coef, name|None); LinRow = dict(terms=[(coef,name)], bound, strict)
# ============================================================================

INT64_MIN, INT64_MAX = -(2**63), 2**63 - 1
GUARD_CASE_CAP = 16


def _is_lin_ident(s):
    if not s:
        return False
    for c in s:
        if not (c.isalnum() or c == "_" or c == "."):
            return False
    return not s[0].isdigit()


def _i64(s):
    try:
        v = int(s, 10)
    except ValueError:
        return None
    return v if INT64_MIN <= v <= INT64_MAX else None


def parse_lin_expr(raw):
    s = [c for c in raw if c not in " \t"]
    if not s:
        return None
    parts = []
    i = 0
    sign = 1
    if s[0] == "-":
        sign = -1
        i = 1
    elif s[0] == "+":
        i = 1
    while i < len(s):
        j = i
        while j < len(s) and s[j] not in "+-":
            j += 1
        t = "".join(s[i:j])
        if not t:
            return None
        coef, name = 1, None
        if "*" in t:
            l, r = t.split("*", 1)
            if not r or "*" in r:
                return None
            if (c := _i64(l)) is not None:
                coef, name = c, r
            elif (c := _i64(r)) is not None:
                coef, name = c, l
            else:
                return None
        else:
            if (c := _i64(t)) is not None:
                coef = c
            else:
                name = t
        if name is not None and not _is_lin_ident(name):
            return None
        parts.append((coef * sign, name))
        if j >= len(s):
            break
        sign = -1 if s[j] == "-" else 1
        i = j + 1
    return parts


def lin_normalize(lhs, rhs, strict, src=""):
    terms = []
    bound = 0
    for coef, name in lhs:
        if name is not None:
            terms.append((coef, name))
        else:
            bound -= coef
    for coef, name in rhs:
        if name is not None:
            terms.append((-coef, name))
        else:
            bound += coef
    terms.sort(key=lambda t: t[1])
    merged = []
    for coef, name in terms:
        if merged and merged[-1][1] == name:
            merged[-1][0] += coef
        else:
            merged.append([coef, name])
    out = [(c, n) for c, n in merged if c != 0]
    return {"terms": out, "bound": bound, "strict": strict, "src": src}


def lin_parts_row(parts, strict, src=""):
    return lin_normalize(parts, [], strict, src)


def lin_spell(terms, bound, strict):
    out = []
    pos = [(c, n) for c, n in terms if c > 0]
    neg = [(c, n) for c, n in terms if c < 0]
    lhs = " + ".join((f"{c}*{n}" if c != 1 else n) for c, n in pos) or "0"
    out.append(lhs)
    out.append(" < " if strict else " <= ")
    rhs_terms = [f"{-c}*{n}" if c != -1 else n for c, n in neg]
    if rhs_terms or bound != 0:
        if rhs_terms:
            sp = " + ".join(rhs_terms)
            if bound > 0:
                sp += f" + {bound}"
            elif bound < 0:
                sp += f" - {-bound}"
        else:
            sp = str(bound)
        out.append(sp)
    return "".join(out)


def split_lin_cmp(atom):
    ops = ["<=", ">=", "==", "!=", "<", ">"]
    pos, op = None, ""
    i = 0
    while i < len(atom):
        c = atom[i]
        if c not in "<>=!":
            i += 1
            continue
        matched = False
        for o in ops:
            if atom.startswith(o, i):
                if pos is not None:
                    return ("multi",)
                pos, op = i, o
                i += len(o)
                matched = True
                break
        if not matched:
            return ("multi",)
    if pos is not None:
        return ("one", pos, op)
    return ("none",)


def lin_substitute(form, subs):
    out = []
    for coef, name in form:
        if name is None:
            out.append((coef, name))
            continue
        applied = False
        for sname, sexpr in subs:
            if sname != name:
                continue
            for ecoef, ename in sexpr:
                out.append((coef * ecoef, ename))
            applied = True
            break
        if not applied:
            out.append((coef, name))
    return out


def lin_feasible(orig):
    """Integer-exact Fourier-Motzkin — same fence as spec.linear.kz."""
    if not orig:
        return "feasible"
    if len(orig) > 64:
        return "outside"
    names = []
    for r in orig:
        for _, n in r["terms"]:
            if n not in names:
                names.append(n)
    if len(names) > 3:
        return "outside"
    w = []
    for i, r in enumerate(orig):
        w.append({
            "terms": [(c, n) for c, n in r["terms"]],
            "bound": r["bound"] - (1 if r["strict"] else 0),
            "strict": False,
            "mask": 1 << i,
        })
    for v in names:
        nxt = [r for r in w if all(n != v for _, n in r["terms"])]
        for n_row in w:
            nc = next((c for c, n in n_row["terms"] if n == v), 0)
            if nc >= 0:
                continue
            for p_row in w:
                pc = next((c for c, n in p_row["terms"] if n == v), 0)
                if pc <= 0:
                    continue
                a, b = -nc, pc
                terms = [(c * b, n) for c, n in n_row["terms"] if n != v]
                for c, n in p_row["terms"]:
                    if n == v:
                        continue
                    hit = next((t for t in terms if t[1] == n), None)
                    if hit is not None:
                        idx = terms.index(hit)
                        terms[idx] = (hit[0] + c * a, n)
                    else:
                        terms.append((c * a, n))
                kept = [(c, n) for c, n in terms if c != 0]
                nxt.append({
                    "terms": kept,
                    "bound": n_row["bound"] * b + p_row["bound"] * a,
                    "strict": n_row["strict"] or p_row["strict"],
                    "mask": n_row["mask"] | p_row["mask"],
                })
        if len(nxt) > 256:
            return "outside"
        w = nxt
    for r in w:
        if r["terms"]:
            continue
        dead = r["bound"] <= 0 if r["strict"] else r["bound"] < 0
        if dead:
            return "infeasible"
    return "feasible"


# ============================================================================
# AST access over the serialized artifact (program.ast.json)
# ============================================================================

def walk_items(items):
    """DFS over item dicts — the .kz pass order: list order, module_decl
    recursed inline."""
    for it in items:
        yield it
        if "module_decl" in it:
            yield from walk_items(it["module_decl"].get("items", []))


def _path_seg(path):
    segs = path.get("segments") or []
    return segs[-1] if segs else ""


def _path_qual(path):
    return path.get("module_qualifier") or ""


# ============================================================================
# claims.kz — subject resolution + field/type machinery
# ============================================================================

def claims_subject_match(ev, on, main_mod):
    path = ev.get("path", {})
    segs = path.get("segments") or []
    if not segs:
        return False
    if ":" in on:
        q = path.get("module_qualifier")
        if q is None:
            return False
        colon = on.index(":")
        return q == on[:colon] and segs[-1] == on[colon + 1:]
    if segs[-1] != on:
        return False
    q = path.get("module_qualifier")
    return True if q is None else q == main_mod


def claims_subject_fields(items, on, main_mod):
    """-> (nfound, fields, subject_ev)"""
    found, fields, subject = 0, [], None
    for it in walk_items(items):
        ev = it.get("event_decl")
        if ev is None or not claims_subject_match(ev, on, main_mod):
            continue
        found += 1
        if found == 1:
            fields = list((ev.get("input") or {}).get("fields") or [])
            subject = ev
    return found, fields, subject


def claims_field_listed(fields, name):
    return any(f.get("name") == name for f in fields)


def _field_of(fields, name):
    return next((f for f in fields if f.get("name") == name), None)


def _field_base(t):
    cut = t.find("&")
    return (t[:cut] if cut >= 0 else t).strip(" ")


def claims_int_field(fields, name):
    f = _field_of(fields, name)
    if f is None:
        return False
    t = _field_base(f.get("type") or "")
    if t in ("usize", "comptime_int"):
        return True
    if len(t) < 2 or t[0] not in "iu":
        return False
    return all(c.isdigit() for c in t[1:])


def claims_typed_atom_rows(atom, self_name, site, fields, subject):
    """-> ('rows', rows) | ('outside', msg)"""
    sp = split_lin_cmp(atom)
    if sp[0] != "one":
        return ("outside", f"the '&' atom '{atom}' on {site} of '{subject}' is not one linear comparison")
    _, pos, op = sp
    ltxt = atom[:pos].strip(" ")
    if not ltxt:
        lhs = [(1, self_name)]
    else:
        lhs = parse_lin_expr(ltxt)
        if lhs is None:
            return ("outside", f"the '&' atom '{atom}' on {site} of '{subject}' is not a linear form")
    rhs = parse_lin_expr(atom[pos + len(op):].strip(" "))
    if rhs is None:
        return ("outside", f"the '&' atom '{atom}' on {site} of '{subject}' is not a linear form")
    for coef, n in lhs + rhs:
        if n is not None and not claims_int_field(fields, n):
            return ("outside", f"the '&' atom '{atom}' names '{n}' — not an integer field of '{subject}'")
    return ("rows", claims_guard_rows(lhs, rhs, op, False, "field type"))


def claims_field_type_rows(decl_fields, fields, subject):
    """-> ('rows', rows) | ('outside', msg)"""
    rows = []
    for f in decl_fields:
        t = f.get("type") or ""
        cut = t.find("&")
        if cut < 0:
            continue
        for raw in t[cut + 1:].split("&"):
            atom = raw.strip(" ")
            if not atom:
                continue
            site = f"field '{f.get('name')}'"
            st, v = claims_typed_atom_rows(atom, f.get("name"), site, fields, subject)
            if st == "outside":
                return ("outside", v)
            rows.extend(v)
    return ("rows", rows)


def claims_sub_rows(rows, subs):
    out = []
    for r in rows:
        parts = [(c, n) for c, n in r["terms"]] + [(-r["bound"], None)]
        subbed = lin_substitute(parts, subs)
        const_part = 0
        named = []
        for c, n in subbed:
            if n is not None:
                named.append((c, n))
            else:
                const_part += c
        out.append({"terms": named, "bound": -const_part,
                    "strict": r["strict"], "src": r["src"]})
    return out


# ============================================================================
# claims-guard — guard parse + DNF
# ============================================================================
# GuardCmp = dict(lhs, rhs, op, src, neg); GuardExpr = ('atom',cmp)|('conj',subs)|('disj',subs)

def claims_strip_parens(s):
    cur = s.strip(" \t")
    while len(cur) >= 2 and cur[0] == "(" and cur[-1] == ")":
        depth, wraps = 0, True
        for i, c in enumerate(cur):
            if c == "(":
                depth += 1
            if c == ")":
                depth -= 1
                if depth == 0 and i != len(cur) - 1:
                    wraps = False
                    break
        if not wraps:
            break
        cur = cur[1:-1].strip(" \t")
    return cur


def _conn_at(src, i, word):
    if src[i:i + len(word)] != word:
        return False
    left_ok = i == 0 or not (src[i - 1].isalnum() or src[i - 1] == "_")
    e = i + len(word)
    right_ok = e == len(src) or not (src[e].isalnum() or src[e] == "_")
    return left_ok and right_ok


def _split_conn(text, word, symbol):
    pieces = []
    depth, start, i = 0, 0, 0
    while i < len(text):
        c = text[i]
        if c == "(":
            depth += 1
        if c == ")":
            if depth == 0:
                return None
            depth -= 1
        if depth == 0 and (_conn_at(text, i, word) or _conn_at(text, i, symbol)):
            pieces.append(text[start:i])
            conlen = len(symbol) if text[i] == symbol[0] else len(word)
            start = i + conlen
            i = start - 1
        i += 1
    if not pieces:
        return None
    pieces.append(text[start:])
    return pieces


def claims_guard_atom(src, fields, subject):
    sp = split_lin_cmp(src)
    if sp[0] != "one":
        return ("outside", f"the impl's guard piece '{src}' is not a single linear comparison")
    _, pos, op = sp
    lhs = parse_lin_expr(src[:pos].strip(" \t"))
    if lhs is None:
        return ("outside", "the guard's left side is not a linear form")
    rhs = parse_lin_expr(src[pos + len(op):].strip(" \t"))
    if rhs is None:
        return ("outside", "the guard's right side is not a linear form")
    for coef, n in lhs + rhs:
        if n is None:
            continue
        if not claims_field_listed(fields, n):
            return ("outside", f"the guard names '{n}' — not an input field of '{subject}'")
        if not claims_int_field(fields, n):
            return ("outside", f"the guard names '{n}' — not an integer field, and the rank grammar is integer-only")
    return ("ok", ("atom", {"lhs": lhs, "rhs": rhs, "op": op, "src": src, "neg": False}))


def claims_parse_guard(src, fields, subject):
    text = claims_strip_parens(src)
    depth = 0
    for c in text:
        if c == "(":
            depth += 1
        if c == ")":
            depth -= 1
        if depth < 0:
            return ("outside", "the impl's guard has unbalanced parens")
    if depth != 0:
        return ("outside", "the impl's guard has unbalanced parens")
    pieces = _split_conn(text, "or", "||")
    if pieces is not None:
        subs = []
        for p in pieces:
            st, v = claims_parse_guard(p, fields, subject)
            if st == "outside":
                return (st, v)
            subs.append(v)
        return ("ok", ("disj", subs))
    pieces = _split_conn(text, "and", "&&")
    if pieces is not None:
        subs = []
        for p in pieces:
            st, v = claims_parse_guard(p, fields, subject)
            if st == "outside":
                return (st, v)
            subs.append(v)
        return ("ok", ("conj", subs))
    return claims_guard_atom(text, fields, subject)


def _guard_cases_walk(expr, negate, out):
    """-> None | err msg"""
    kind = expr[0]
    if kind == "atom":
        cmp_ = dict(expr[1])
        cmp_["neg"] = negate
        out.append([cmp_])
        return None
    subs = expr[1]
    if kind == "conj":
        if negate:
            for s in subs:
                m = _guard_cases_walk(s, True, out)
                if m:
                    return m
        else:
            acc = [[]]
            for s in subs:
                child = []
                m = _guard_cases_walk(s, False, child)
                if m:
                    return m
                nxt = [ca + cb for ca in acc for cb in child]
                if len(nxt) > GUARD_CASE_CAP:
                    return "the impl's guard case-splits past the fence's case budget"
                acc = nxt
            out.extend(acc)
    else:  # disj
        if negate:
            acc = [[]]
            for s in subs:
                child = []
                m = _guard_cases_walk(s, True, child)
                if m:
                    return m
                nxt = [ca + cb for ca in acc for cb in child]
                if len(nxt) > GUARD_CASE_CAP:
                    return "the impl's guard case-splits past the fence's case budget"
                acc = nxt
            out.extend(acc)
        else:
            for s in subs:
                m = _guard_cases_walk(s, False, out)
                if m:
                    return m
    return None


def claims_guard_cases(expr, negate):
    """-> ('ok', clauses) | ('outside', msg)"""
    clauses = []
    m = _guard_cases_walk(expr, negate, clauses)
    if m:
        return ("outside", m)
    if len(clauses) > GUARD_CASE_CAP:
        return ("outside", "the impl's guard case-splits past the fence's case budget")
    return ("ok", clauses)


# ============================================================================
# claims-dispatch — rename, clause product, arm produce
# ============================================================================

def claims_rename_ident(text, frm, to):
    if not frm or frm == "_" or frm == to:
        return text
    ok = lambda c: c.isalnum() or c == "_"
    out = []
    i = 0
    while i < len(text):
        c = text[i]
        if c in "'\"":
            j = text.find(c, i + 1)
            end = j if j >= 0 else len(text) - 1
            out.append(text[i:end + 1])
            i = end + 1
            continue
        if i == 0 or not ok(text[i - 1]):
            j = i
            while j < len(text) and ok(text[j]):
                j += 1
            if text[i:j] == frm:
                out.append(to)
                i = j
                continue
        out.append(c)
        i += 1
    return "".join(out)


def claims_clause_product(a, b):
    """-> ('ok', clauses) | ('outside', msg)"""
    out = [ca + cb for ca in a for cb in b]
    if len(out) > GUARD_CASE_CAP:
        return ("outside", "the impl's dispatch case-splits past the fence's case budget")
    return ("ok", out)


def claims_arm_produce(cont, fields, subject):
    """-> ('ok', (branch_name, scalar_field)) | ('outside', msg)"""
    node = cont.get("node")
    if node is None:
        return ("outside", f"arm '{cont.get('branch')}' produces nothing the fence reads")
    if "branch_constructor" not in node:
        return ("outside", f"arm '{cont.get('branch')}' is not produced by a branch constructor")
    bc = node["branch_constructor"]
    scalar_field = None
    pv = bc.get("plain_value")
    if pv is not None:
        pv_t = pv.strip(" \t")
        if claims_field_listed(fields, pv_t):
            scalar_field = pv_t
        else:
            return ("outside", f"arm '{bc.get('branch_name')}' produces '{pv_t}' — not a field of '{subject}'")
    else:
        for f in bc.get("fields") or []:
            es = f.get("expression_str")
            if es is None:
                return ("outside", f"arm '{bc.get('branch_name')}' field '{f.get('name')}' carries no produce expression")
            if not claims_field_listed(fields, f.get("name")) or es != f.get("name"):
                return ("outside", f"arm '{bc.get('branch_name')}' produces '{f.get('name')}': '{es}' — the fence reads pun produces only")
    if cont.get("continuations"):
        return ("outside", f"arm '{cont.get('branch')}' continues past its produce — the fence reads terminal arms")
    return ("ok", (bc.get("branch_name"), scalar_field))


# ============================================================================
# claims-prover — arm meets, jumps, folds, discharge
# ============================================================================
# ArmMeet = dict(arm, rows, scalar_field)

def claims_guard_rows(lhs, rhs, op, negate, src):
    rows = []
    lt, le = op == "<", op == "<="
    gt, ge = op == ">", op == ">="
    eq, ne = op == "==", op == "!="
    if not negate:
        if lt:
            rows.append(lin_normalize(lhs, rhs, True, src))
        if le:
            rows.append(lin_normalize(lhs, rhs, False, src))
        if gt:
            rows.append(lin_normalize(rhs, lhs, True, src))
        if ge:
            rows.append(lin_normalize(rhs, lhs, False, src))
        if eq:
            rows.append(lin_normalize(lhs, rhs, False, src))
            rows.append(lin_normalize(rhs, lhs, False, src))
    else:
        if lt:
            rows.append(lin_normalize(rhs, lhs, False, src))
        if le:
            rows.append(lin_normalize(rhs, lhs, True, src))
        if gt:
            rows.append(lin_normalize(lhs, rhs, False, src))
        if ge:
            rows.append(lin_normalize(lhs, rhs, True, src))
        if ne:
            rows.append(lin_normalize(lhs, rhs, False, src))
            rows.append(lin_normalize(rhs, lhs, False, src))
    return rows


def _emit_meets(cases, prod, out):
    for clause in cases:
        rows = []
        for cmp_ in clause:
            rows.extend(claims_guard_rows(cmp_["lhs"], cmp_["rhs"], cmp_["op"], cmp_["neg"], cmp_["src"]))
        out.append({"arm": prod[0], "rows": rows, "scalar_field": prod[1]})


def claims_dispatch_arms(inv, conts, prefix, fields, subject, out):
    """-> None | outside reason"""
    segs = (inv.get("path") or {}).get("segments") or []
    dispatch = segs[-1] if segs else ""
    is_if = dispatch == "if"
    if not is_if and dispatch != "cond":
        return f"a dispatch on '{dispatch}' is not an if/cond — the fence reads those"
    q = (inv.get("path") or {}).get("module_qualifier")
    if q is not None and q != "std.control":
        return f"the impl dispatches on '{q}:{dispatch}' — the fence reads std.control's if/cond"
    args = inv.get("args") or []
    if not args:
        return "the dispatch carries no guard or scrutinee"
    if not conts:
        return "the dispatch carries no arms"

    if_guard, scrutinee = None, ""
    if is_if:
        st, v = claims_parse_guard(args[0].get("value") or "", fields, subject)
        if st == "outside":
            return v
        if_guard = v
    else:
        scrutinee = (args[0].get("value") or "").strip(" \t")
        if not claims_field_listed(fields, scrutinee):
            return f"the cond scrutinee '{scrutinee}' is not a field of '{subject}' — the fence reads field scrutinees"
        if not claims_int_field(fields, scrutinee):
            return f"the cond scrutinee '{scrutinee}' is not an integer field — the rank grammar is integer-only"

    catchall = [[]]
    priors = []
    for cont in conts:
        own = catchall
        if is_if:
            negate = cont.get("branch") == "else"
            if not negate and cont.get("branch") != "then":
                return f"the impl dispatches on '{cont.get('branch')}' — the fence reads then/else"
            st, v = claims_guard_cases(if_guard, negate)
            if st == "outside":
                return v
            own = v
            ctext = cont.get("condition")
            if ctext:
                st, e = claims_parse_guard(ctext, fields, subject)
                if st == "outside":
                    return e
                st, xc = claims_guard_cases(e, False)
                if st == "outside":
                    return xc
                st, v2 = claims_clause_product(own, xc)
                if st == "outside":
                    return v2
                own = v2
        else:
            guard = None
            ctext = cont.get("condition")
            if ctext:
                b = cont.get("binding")
                renamed = claims_rename_ident(ctext, b, scrutinee) if b else ctext
                st, v = claims_parse_guard(renamed, fields, subject)
                if st == "outside":
                    return v
                guard = v
            if guard is not None:
                st, v = claims_guard_cases(guard, False)
                if st == "outside":
                    return v
                own = v
            for pg in priors:
                if pg is not None:
                    st, neg = claims_guard_cases(pg, True)
                    if st == "outside":
                        return neg
                    st, v2 = claims_clause_product(own, neg)
                    if st == "outside":
                        return v2
                    own = v2
                else:
                    own = []
                    break
            priors.append(guard)
        st, arm_cases = claims_clause_product(prefix, own)
        if st == "outside":
            return arm_cases
        node = cont.get("node")
        if node is None:
            return f"arm '{cont.get('branch')}' produces nothing the fence reads"
        if "branch_constructor" in node:
            st, prod = claims_arm_produce(cont, fields, subject)
            if st == "outside":
                return prod
            _emit_meets(arm_cases, prod, out)
        elif "invocation" in node:
            if not cont.get("continuations"):
                return f"arm '{cont.get('branch')}' chains into a dispatch with no arms"
            m = claims_dispatch_arms(node["invocation"], cont["continuations"], arm_cases, fields, subject, out)
            if m:
                return m
        else:
            return f"arm '{cont.get('branch')}' is not produced by a branch constructor"
    return None


def claims_arm_meets(impl, fields, subject, out):
    body = impl.get("body") or {}
    node = body.get("node")
    if node is None:
        return "the subject's impl flow has no body"
    if "invocation" not in node:
        return "the subject's impl is not an if/cond-dispatch"
    inv = node["invocation"]
    segs = (inv.get("path") or {}).get("segments") or []
    dispatch = segs[0] if len(segs) == 1 else ""
    if dispatch not in ("if", "cond"):
        return "the subject's impl is not an if/cond-dispatch"
    return claims_dispatch_arms(inv, body.get("continuations") or [], [[]], fields, subject, out)


def claims_collect_jumps(conts, label, depth, out, nested):
    for cont in conts:
        node = cont.get("node")
        if node and "label_jump" in node and node["label_jump"].get("label") == label:
            if depth == 0:
                loc = cont.get("location") or {}
                out.append({
                    "arm": cont.get("branch"),
                    "binding": cont.get("binding"),
                    "args": node["label_jump"].get("args") or [],
                    "line": loc.get("line", 0),
                    "column": loc.get("column", 0),
                })
            else:
                nested[0] = True
        claims_collect_jumps(cont.get("continuations") or [], label, depth + 1, out, nested)


def claims_fold_heads(items, ev):
    seg = _path_seg(ev.get("path", {}))
    qe = _path_qual(ev.get("path", {}))
    out = []
    for it in walk_items(items):
        fl = it.get("flow")
        if fl is None or fl.get("pre_label") is None:
            continue
        node = (fl.get("body") or {}).get("node")
        if node is None or "invocation" not in node:
            continue
        ip = node["invocation"].get("path") or {}
        segs = ip.get("segments") or []
        if not segs or segs[-1] != seg:
            continue
        if _path_qual(ip) != qe:
            continue
        out.append(fl)
    return out


def claims_impl_flow(items, ev):
    seg = _path_seg(ev.get("path", {}))
    qe = _path_qual(ev.get("path", {}))
    for it in walk_items(items):
        fl = it.get("flow")
        if fl is None:
            continue
        io = fl.get("impl_of")
        if not io or not io.get("segments"):
            continue
        if io["segments"][-1] != seg:
            continue
        if (io.get("module_qualifier") or "") != qe:
            continue
        return fl
    return None


def claims_any_impl(items, ev):
    seg = _path_seg(ev.get("path", {}))
    qe = _path_qual(ev.get("path", {}))
    for it in walk_items(items):
        fl = it.get("flow")
        if fl is not None:
            io = fl.get("impl_of")
            if io and io.get("segments") and io["segments"][-1] == seg and \
               (io.get("module_qualifier") or "") == qe:
                return True
        ii = it.get("immediate_impl")
        if ii is not None:
            ep = ii.get("event_path") or {}
            es = ep.get("segments") or []
            if es and es[-1] == seg and (ep.get("module_qualifier") or "") == qe:
                return True
    return False


def claims_map_arg_parts(parts, binding, scalar_field, fields):
    out = []
    for coef, n in parts:
        if n is None:
            out.append((coef, n))
            continue
        if scalar_field is not None and n == binding:
            out.append((coef, scalar_field))
            continue
        if len(n) > len(binding) + 1 and n.startswith(binding) and n[len(binding)] == ".":
            f = n[len(binding) + 1:]
            if not claims_field_listed(fields, f):
                return None
            out.append((coef, f))
            continue
        return None
    return out


def claims_entail(meet, lhs, rhs, op):
    """-> 'entailed' | 'open' | 'outside'"""
    dirs = ["<=", ">="] if op == "==" else [op]
    for d in dirs:
        neg = claims_guard_rows(lhs, rhs, d, True, "goal refuted")
        if not neg:
            return "outside"
        v = lin_feasible(meet + neg)
        if v == "feasible":
            return "open"
        if v == "outside":
            return "outside"
    return "entailed"


class EvSink:
    """The ClaimEvidence buffer — terms/goal/heads/edges/type_rows +
    cur_cand/cur_fold, mirroring compiler.claims-evidence.kz."""

    def __init__(self):
        self.terms = []          # [(cand, rank_parts)]
        self.goal = None         # (lhs, op, rhs)
        self.heads = []          # [(fold, rows)]
        self.edges = []          # [EdgeEv dict]
        self.type_rows = []
        self.cur_cand = 0
        self.cur_fold = 0

    def edge(self, fold, ei, arm, case, rows, subs):
        self.edges.append({"cand": self.cur_cand, "fold": fold, "edge": ei,
                           "arm": arm, "case": case, "rows": rows, "subs": subs})


def _rank_prelude(items, ev, fields, subject, eb):
    """claimsRankPrelude —> ('ok', pre) | ('verdict', (word, detail))"""
    impl = claims_impl_flow(items, ev)
    if impl is None:
        if claims_any_impl(items, ev):
            return ("verdict", ("outside-P", "the subject's impl is not an if/cond-dispatch"))
        return ("verdict", ("outside-P", "the subject has no impl flow"))
    arm_meets = []
    reason = claims_arm_meets(impl, fields, subject, arm_meets)
    if reason:
        return ("verdict", ("outside-P", reason))
    st, type_rows = claims_field_type_rows(fields, fields, subject)
    if st == "outside":
        return ("verdict", ("outside-P", type_rows))
    eb.type_rows = type_rows
    folds = claims_fold_heads(items, ev)
    if not folds:
        return ("verdict", ("unproven", f"no #-fold invokes '{subject}'"))
    return ("ok", {"arm_meets": arm_meets, "folds": folds, "type_rows": type_rows})


def _edge_subs(e, fields, label, subject, scalar_field):
    """Jump args -> LinSubs; -> ('ok', subs) | ('outside', msg)"""
    subs = []
    for a in e["args"]:
        aname = a.get("name")
        if not claims_field_listed(fields, aname):
            return ("outside", f"@{label} arg '{aname}' is not a field of '{subject}'")
        if not claims_int_field(fields, aname):
            return ("outside", f"@{label} arg '{aname}' is not an integer field")
        parts = parse_lin_expr(a.get("value") or "")
        if parts is None:
            return ("outside", f"@{label} arg '{aname}: {a.get('value')}' is not a linear form")
        mapped = claims_map_arg_parts(parts, e["binding"], scalar_field, fields)
        if mapped is None:
            return ("outside", f"@{label} arg '{aname}: {a.get('value')}' names something outside the payload")
        subs.append((aname, mapped))
    for f in fields:
        if not any(s[0] == f.get("name") for s in subs):
            return ("outside", f"@{label} does not rebind field '{f.get('name')}'")
    return ("ok", subs)


def claims_rank_try(arm_meets, folds, fields, type_rows, rank_parts, subject, eb):
    """-> ('proven', nedges) | ('unproven', msg) | ('outside', msg)"""
    nedges = 0
    for fi, fl in enumerate(folds):
        label = fl["pre_label"]
        edges, nested = [], [False]
        claims_collect_jumps((fl.get("body") or {}).get("continuations") or [], label, 0, edges, nested)
        if nested[0]:
            return ("outside", "a back-edge sits inside a nested dispatch — the inner call's contract is not modeled")
        eb.cur_fold = fi
        for ei, e in enumerate(edges):
            nedges += 1
            if e["binding"] is None:
                return ("outside", f"the '{e['arm']}' back-edge binds no payload")
            arm_cases = 0
            scalar_field = None
            for am in arm_meets:
                if am["arm"] == e["arm"]:
                    arm_cases += 1
                    scalar_field = am["scalar_field"]
            if arm_cases == 0:
                return ("outside", f"arm '{e['arm']}' is not produced by the subject's impl")
            st, subs = _edge_subs(e, fields, label, subject, scalar_field)
            if st == "outside":
                return (st, subs)
            next_rank = lin_substitute(rank_parts, subs)
            diff = list(rank_parts) + [(-c, n) for c, n in next_rank]
            sub_type = claims_sub_rows(type_rows, subs)
            case_n = 0
            for am in arm_meets:
                if am["arm"] != e["arm"]:
                    continue
                eb.edge(fi, ei, e["arm"], case_n, am["rows"], subs)
                case_n += 1
                meet = list(am["rows"]) + list(type_rows) + list(sub_type)
                base_n = len(meet)
                meet.append(lin_parts_row(diff, False, "rank does not decrease"))
                v = lin_feasible(meet)
                if v == "feasible":
                    return ("unproven", f"at the '{e['arm']}' back-edge, the rank may not strictly decrease")
                if v == "outside":
                    return ("outside", "the rank-decrease meet exceeds the decidable fence")
                meet = meet[:base_n]
                meet.append(lin_parts_row(next_rank, True, "rank below zero"))
                v = lin_feasible(meet)
                if v == "feasible":
                    return ("unproven", f"at the '{e['arm']}' back-edge, the rank can fall below zero")
                if v == "outside":
                    return ("outside", "the rank-bound meet exceeds the decidable fence")
    return ("proven", nedges)


def _spell_parts(parts):
    """claimsSpellParts — `limit - i` canonical order."""
    out = []
    first = True
    for sign in (1, -1):
        for c, n in parts:
            if n is None or (c >= 0) != (sign > 0):
                continue
            ac = -c if c < 0 else c
            if not first:
                out.append(" - " if c < 0 else " + ")
            elif c < 0:
                out.append("-")
            if ac != 1:
                out.append(f"{ac}*")
            out.append(n)
            first = False
    for c, n in parts:
        if n is not None:
            continue
        if first:
            out.append(str(c))
        elif c > 0:
            out.append(f" + {c}")
        elif c < 0:
            out.append(f" - {-c}")
        first = False
    return "".join(out)


def prove_terminates(items, ev, fields, rank_parts, subject, eb):
    """-> (word, detail)"""
    for c, n in rank_parts:
        if n is not None and not claims_int_field(fields, n):
            return ("outside-P", f"rank names '{n}' — not an integer field, and the rank grammar is integer-only")
    st, pre = _rank_prelude(items, ev, fields, subject, eb)
    if st == "verdict":
        return pre
    eb.cur_cand = 0
    eb.terms.append((0, rank_parts))
    v = claims_rank_try(pre["arm_meets"], pre["folds"], fields, pre["type_rows"], rank_parts, subject, eb)
    if v[0] == "proven":
        n = v[1]
        return ("proven", f"rank decreases and stays bounded at {n} back-edge{'' if n == 1 else 's'}")
    return (("unproven" if v[0] == "unproven" else "outside-P"), v[1])


def prove_terminates_inferred(items, ev, fields, subject, eb):
    st, pre = _rank_prelude(items, ev, fields, subject, eb)
    if st == "verdict":
        return pre
    cands, spells = [], []
    def _add(r):
        cand = [(-t[0], t[1]) for t in r["terms"]] + [(r["bound"], None)]
        key = lin_spell(r["terms"], r["bound"], r["strict"])
        if key not in spells:
            spells.append(key)
            cands.append(cand)
    for r in pre["type_rows"]:
        _add(r)
    for am in pre["arm_meets"]:
        for r in am["rows"]:
            _add(r)
    if not cands:
        return ("outside-P", "the arm guards and declared types hold no linear bound to infer a rank from")
    first_fail = None
    for ci, cand in enumerate(cands):
        eb.cur_cand = ci
        eb.terms.append((ci, cand))
        v = claims_rank_try(pre["arm_meets"], pre["folds"], fields, pre["type_rows"], cand, subject, eb)
        if v[0] == "proven":
            n = v[1]
            return ("proven", f"inferred rank '{_spell_parts(cand)}' decreases and stays bounded at {n} back-edge{'' if n == 1 else 's'}")
        if v[0] == "unproven":
            if first_fail is None:
                first_fail = v[1]
        else:
            return ("outside-P", v[1])
    return ("unproven", f"no inferred rank discharged the back-edges ({first_fail or 'no candidates'})")


def prove_honors(items, ev, fields, glhs, grhs, gop, subject, eb):
    """-> (word, detail)"""
    for c, n in glhs + grhs:
        if n is not None and not claims_int_field(fields, n):
            return ("outside-P", f"goal names '{n}' — not an integer field, and the goal grammar is integer-only")
    impl = claims_impl_flow(items, ev)
    if impl is None:
        if claims_any_impl(items, ev):
            return ("outside-P", "the subject's impl is not an if/cond-dispatch")
        return ("outside-P", "the subject has no impl flow")
    arm_meets = []
    reason = claims_arm_meets(impl, fields, subject, arm_meets)
    if reason:
        return ("outside-P", reason)
    st, type_rows = claims_field_type_rows(fields, fields, subject)
    if st == "outside":
        return ("outside-P", type_rows)
    folds = claims_fold_heads(items, ev)
    if not folds:
        return ("unproven", f"no #-fold invokes '{subject}'")
    ih_rows = claims_guard_rows(glhs, grhs, gop, False, "goal")
    eb.goal = (glhs, gop, grhs)
    nedges = 0
    for fi, fl in enumerate(folds):
        label = fl["pre_label"]
        eb.cur_fold = fi
        hnode = (fl.get("body") or {}).get("node")
        if hnode is None:
            return ("outside-P", "the #-fold head has no body")
        if "invocation" not in hnode:
            return ("outside-P", "the #-fold head is not an invocation")
        base = []
        for a in hnode["invocation"].get("args") or []:
            aname = a.get("name")
            if not claims_field_listed(fields, aname):
                return ("outside-P", f"#{label} arg '{aname}' is not a field of '{subject}'")
            eparts = parse_lin_expr(a.get("value") or "")
            if eparts is None:
                return ("outside-P", f"#{label} arg '{aname}: {a.get('value')}' is not a linear form")
            renamed = [(c, f"~entry.{n}") if n else (c, n) for c, n in eparts]
            fpart = [(1, aname)]
            base.append(lin_normalize(fpart, renamed, False, "entry binding"))
            base.append(lin_normalize(renamed, fpart, False, "entry binding"))
        eb.heads.append((fi, list(base)))
        base.extend(type_rows)
        v = claims_entail(base, glhs, grhs, gop)
        if v == "open":
            return ("unproven", f"the #{label} entry bindings do not establish the goal")
        if v == "outside":
            return ("outside-P", "the fold-entry meet exceeds the decidable fence")
        edges, nested = [], [False]
        claims_collect_jumps((fl.get("body") or {}).get("continuations") or [], label, 0, edges, nested)
        if nested[0]:
            return ("outside-P", "a back-edge sits inside a nested dispatch — the inner call's contract is not modeled")
        for ei, e in enumerate(edges):
            nedges += 1
            if e["binding"] is None:
                return ("outside-P", f"the '{e['arm']}' back-edge binds no payload")
            arm_cases = 0
            scalar_field = None
            for am in arm_meets:
                if am["arm"] == e["arm"]:
                    arm_cases += 1
                    scalar_field = am["scalar_field"]
            if arm_cases == 0:
                return ("outside-P", f"arm '{e['arm']}' is not produced by the subject's impl")
            st, subs = _edge_subs(e, fields, label, subject, scalar_field)
            if st == "outside":
                return ("outside-P", subs)
            slhs = lin_substitute(glhs, subs)
            srhs = lin_substitute(grhs, subs)
            sub_type = claims_sub_rows(type_rows, subs)
            case_n = 0
            for am in arm_meets:
                if am["arm"] != e["arm"]:
                    continue
                eb.edge(fi, ei, e["arm"], case_n, am["rows"], subs)
                case_n += 1
                meet = list(ih_rows) + list(am["rows"]) + list(type_rows) + list(sub_type)
                v = claims_entail(meet, slhs, srhs, gop)
                if v == "open":
                    return ("unproven", f"at the '{e['arm']}' back-edge, the goal may not survive the step")
                if v == "outside":
                    return ("outside-P", "the step meet exceeds the decidable fence")
    return ("proven", f"goal holds at {len(folds)} fold head{'' if len(folds) == 1 else 's'}, preserved by {nedges} back-edge{'' if nedges == 1 else 's'}")


# ============================================================================
# claims-evidence — wire spelling (claims-evidence.kz)
# ============================================================================

def _wire_parts(parts):
    if not parts:
        return "-"
    out = []
    for c, n in parts:
        if n is not None:
            out.append(f"{c}*{n[1:] if n.startswith('~') else n}")
        else:
            out.append(str(c))
    return ",".join(out)


def _wire_row(r):
    lhs = _wire_parts([(c, n) for c, n in r["terms"]])
    return f"{lhs}~{'<' if r['strict'] else '<='}~{r['bound']}"


def _wire_rows(rows):
    return "|".join(_wire_row(r) for r in rows) if rows else "-"


def _wire_subs(subs):
    return ";".join(f"{n}={_wire_parts(e)}" for n, e in subs) if subs else "-"


def evidence_lines(file_, line, eb):
    """claimsEvEmit — the claim-* lines in prover order."""
    out = []
    type_sp = _wire_rows(eb.type_rows)
    for cand, rank in eb.terms:
        out.append(f"[claim-term] site {file_}:{line} cand={cand} rank={_wire_parts(rank)} type={type_sp}")
    if eb.goal is not None:
        glhs, gop, grhs = eb.goal
        out.append(f"[claim-goal] site {file_}:{line} goal={_wire_parts(glhs)}~{gop}~{_wire_parts(grhs)} type={type_sp}")
    for fold, rows in eb.heads:
        out.append(f"[claim-head] site {file_}:{line} fold={fold} rows={_wire_rows(rows)}")
    for e in eb.edges:
        out.append(f"[claim-edge] site {file_}:{line} cand={e['cand']} fold={e['fold']} "
                   f"edge={e['edge']} arm={e['arm']} case={e['case']} "
                   f"rows={_wire_rows(e['rows'])} sub={_wire_subs(e['subs'])}")
    return out


# ============================================================================
# Claim-site harvest — the artifact's std.spec:claim flow items, in the
# pass's registry order (source order, deduped on file:line:col).
# ============================================================================

CLAIM_ATOMS = {"terminates": [], "honors": ["goal"]}


def harvest_claims(program):
    """-> [dict(atom,on,rank,goal,malformed,file,line,col)]"""
    claims = []
    seen = set()
    for it in walk_items(program.get("items") or []):
        fl = it.get("flow")
        if fl is None:
            continue
        node = (fl.get("body") or {}).get("node")
        if node is None or "invocation" not in node:
            continue
        inv = node["invocation"]
        path = inv.get("path") or {}
        segs = path.get("segments") or []
        if segs != ["claim"] or (path.get("module_qualifier") or "") != "std.spec":
            continue
        args = {a.get("name"): (a.get("value") or "") for a in inv.get("args") or []}
        loc = fl.get("location") or {}
        file_ = loc.get("file") or ""
        line = loc.get("line") or 0
        col = loc.get("column") or 0
        if (file_, line, col) in seen:
            continue
        seen.add((file_, line, col))
        rank, goal, malformed = "", "", False
        src = args.get("source")
        if src is not None:
            try:
                decl = json.loads("{" + src + "}")
                rank, goal = decl.get("rank", ""), decl.get("goal", "")
            except (json.JSONDecodeError, TypeError):
                malformed = True
        claims.append({
            "atom": args.get("atom", ""), "on": args.get("on", ""),
            "rank": rank, "goal": goal, "malformed": malformed,
            "file": file_, "line": line, "col": col,
        })
    return claims


# ============================================================================
# The pass — derive (word, detail, evidence lines) per claim, or the
# refusal the pass would have issued (KORU213-class → no claim-check line).
# ============================================================================

def derive_claim(program, c):
    """-> ('refused', reason) | ('judged', word, detail, eb) | ('declared',)
    Mirrors pass-claims-check's per-claim pipeline."""
    atom, on = c["atom"], c["on"]
    if c["malformed"]:
        return ("refused", "unparseable Source block")
    catom = CLAIM_ATOMS.get(atom)
    if catom is None:
        return ("refused", "unregistered atom")
    items = program.get("items") or []
    main_mod = program.get("main_module_name") or ""
    nfound, fields, subject_ev = claims_subject_fields(items, on, main_mod)
    if nfound != 1:
        return ("refused", f"subject resolves to {nfound} tors")
    for req in catom:
        val = c["rank"] if req == "rank" else c["goal"] if req == "goal" else ""
        if not val:
            return ("refused", f"missing required '{req}'")
    rank_parts, glhs, grhs, gop = [], [], [], ""
    needs_goal = "goal" in catom
    if c["rank"]:
        rank_parts = parse_lin_expr(c["rank"])
        if rank_parts is None:
            return ("refused", "rank is not a linear form")
    if needs_goal:
        sp = split_lin_cmp(c["goal"])
        if sp[0] != "one":
            return ("refused", "goal is not a single linear comparison")
        _, pos, gop = sp
        glhs = parse_lin_expr(c["goal"][:pos].strip(" \t"))
        grhs = parse_lin_expr(c["goal"][pos + len(gop):].strip(" \t"))
        if glhs is None or grhs is None:
            return ("refused", "goal side is not a linear form")
    for c_, n in rank_parts + glhs + grhs:
        if n is not None and not claims_field_listed(fields, n):
            return ("refused", "parameter names a non-field")
    # Produce-contract check is not part of the claims wire — skipped.
    eb = EvSink()
    if atom == "terminates":
        if c["rank"]:
            word, detail = prove_terminates(items, subject_ev, fields, rank_parts, on, eb)
        else:
            word, detail = prove_terminates_inferred(items, subject_ev, fields, on, eb)
    elif atom == "honors":
        word, detail = prove_honors(items, subject_ev, fields, glhs, grhs, gop, on, eb)
    else:
        return ("declared",)
    return ("judged", word, detail, eb)


# ============================================================================
# Ledger parse + conformance
# ============================================================================

CHECK_RE = re.compile(r"^\[claim-check\] site (.+):(\d+) (\S+) on (\S+) (\S+)(?: — (.*))?$")
EVIDENCE_RE = re.compile(r"^\[claim-(term|goal|head|edge)\] site (.+):(\d+) (.*)$")
CENSUS_RE = re.compile(r"^\[claim-census\] claims=(\d+) declared=(\d+) proven=(\d+) unproven=(\d+) outside=(\d+) edges=(\d+)$")


def parse_ledger(text):
    """-> (checks, evidences, census) — checks: [(file,line,atom,on,word,detail,raw)];
    evidences: [(kind,sitekey,raw)] in order; census: tuple|None"""
    checks, evidences, census = [], [], None
    for raw in text.splitlines():
        m = CHECK_RE.match(raw)
        if m:
            checks.append({"file": m.group(1), "line": int(m.group(2)),
                           "atom": m.group(3), "on": m.group(4),
                           "word": m.group(5), "detail": m.group(6) or "", "raw": raw})
            continue
        m = EVIDENCE_RE.match(raw)
        if m:
            evidences.append((m.group(1), f"{m.group(2)}:{m.group(3)}", raw))
            continue
        m = CENSUS_RE.match(raw)
        if m:
            census = tuple(int(g) for g in m.groups())
    return checks, evidences, census


def check(ast_path, corpus_path, verbose=False, premises_path=None):
    with open(ast_path, "r", encoding="utf-8") as fh:
        program = json.load(fh)
    # Premise boundary: when the pipeline wrote a snapshot of the tree the
    # claims pass actually read (program.pre-claims.ast.json), derive the
    # premise rows from THAT tree — the pass's real input, not the
    # pre-transform artifact. Claim sites always come from program.ast.json:
    # the std.spec:claim flow is consumed by the pipeline, so only the
    # frontend artifact still carries the site spellings.
    premises = program
    if premises_path:
        with open(premises_path, "r", encoding="utf-8") as fh:
            premises = json.load(fh)
    with open(corpus_path, "r", encoding="utf-8") as fh:
        corpus = fh.read()

    claims = harvest_claims(program)
    checks, evidences, census = parse_ledger(corpus)
    failures, notes = [], []

    # --- Site coverage: artifact claim sites ↔ committed claim-check lines.
    art_sites = [(c["file"], c["line"]) for c in claims]
    led_sites = [(c["file"], c["line"]) for c in checks]
    if art_sites != led_sites:
        for s in art_sites:
            if s not in led_sites:
                failures.append(f"SITE-MISS {s[0]}:{s[1]} — an artifact std.spec:claim committed no [claim-check] line")
        for s in led_sites:
            if s not in art_sites:
                failures.append(f"SITE-STRAY {s[0]}:{s[1]} — a committed [claim-check] names no artifact claim")
        if art_sites == led_sites:
            pass
        elif len(art_sites) == len(led_sites) and art_sites != led_sites:
            failures.append("SITE-ORDER — artifact claim order and ledger order diverge")

    # --- Per-claim derivation, paired by position (registry order).
    derived = []      # per claim: list of derived claim-* lines
    verdict_counts = {"declared": 0, "proven": 0, "unproven": 0, "outside-P": 0}
    derived_edges = 0
    for i, c in enumerate(claims):
        site_key = f"{c['file']}:{c['line']}"
        check_line = checks[i] if i < len(checks) else None
        res = derive_claim(premises, c)
        if res[0] == "refused":
            # A claim the pass would have refused emits no [claim-check];
            # an armed (successful) compile cannot carry one.
            failures.append(f"SITE-REFUSE {site_key} — the artifact's claim would refuse ({res[1]}); "
                            "a committed verdict over it cannot be artifact-derived")
            continue
        if res[0] == "declared":
            word, detail, eb = "declared", "", EvSink()
        else:
            _, word, detail, eb = res
        verdict_counts[word] += 1
        derived_edges += len(eb.edges)
        lines = evidence_lines(c["file"], c["line"], eb)
        derived.append((site_key, lines))
        if check_line is None:
            continue
        # Exact fidelity: atom, subject, verdict word, and the detail prose —
        # all reproduced from the artifact, none trusted.
        expected = (f"[claim-check] site {site_key} {c['atom']} on {c['on']} {word}"
                    + (f" — {detail}" if detail else ""))
        if check_line["raw"] != expected:
            failures.append(f"VERDICT {site_key} — committed '{check_line['raw']}'\n"
                            f"           derived  '{expected}'")

    # --- Evidence rows, attributed by site (each site's block follows its
    # claim-check line in the corpus — the pass emits them adjacent).
    committed_blocks = {}
    for kind, site_key, raw in evidences:
        committed_blocks.setdefault(site_key, []).append(raw)
    claim_site_keys = {f"{c['file']}:{c['line']}" for c in claims}
    for site_key in committed_blocks:
        if site_key not in claim_site_keys:
            failures.append(f"EVID-STRAY {site_key} — premise lines name no artifact claim site")
    for site_key, lines in derived:
        got = committed_blocks.get(site_key, [])
        if got != lines:
            if not got:
                failures.append(f"EVID-MISS {site_key} — {len(lines)} derived premise line(s) committed none")
                continue
            n = max(len(got), len(lines))
            for k in range(n):
                g = got[k] if k < len(got) else "<none>"
                d = lines[k] if k < len(lines) else "<none>"
                if g != d:
                    failures.append(f"EVID-DIFF {site_key} line {k}:\n"
                                    f"           committed '{g}'\n"
                                    f"           derived   '{d}'")
                    break
    # Committed blocks that name no derived site are caught by SITE-STRAY.

    # --- Census re-decision.
    if census is not None:
        n_claims = len(checks)
        declared = sum(1 for c in checks if c["word"] == "declared")
        proven = sum(1 for c in checks if c["word"] == "proven")
        unproven = sum(1 for c in checks if c["word"] == "unproven")
        outside = sum(1 for c in checks if c["word"] == "outside-P")
        n_edges = sum(1 for k, _, _ in evidences if k == "edge")
        expected = (n_claims, declared, proven, unproven, outside, n_edges)
        if census != expected:
            failures.append(f"CENSUS — committed {census} vs ledger-derived {expected}")
        # The artifact's own verdict census — cross-leg check: the committed
        # word counts must equal the artifact-derived counts.
        art_counts = (verdict_counts["declared"], verdict_counts["proven"],
                      verdict_counts["unproven"], verdict_counts["outside-P"])
        if (declared, proven, unproven, outside) != art_counts:
            failures.append(f"CENSUS-ART — committed verdicts ({declared},{proven},{unproven},{outside}) "
                            f"vs artifact-derived {art_counts}")
    else:
        if checks or claims:
            failures.append("CENSUS-MISS — claim lines exist but no [claim-census] committed")

    # --- Report.
    print(f"claims-ast conformance: {len(claims)} artifact claim site(s), "
          f"{len(checks)} committed site line(s), "
          f"{len(evidences)} premise line(s), "
          f"derived edges={derived_edges}")
    if notes:
        for n in notes:
            print(f"  note {n}")
    if failures:
        for f in failures[:20]:
            print(f"  FAIL {f}")
        if len(failures) > 20:
            print(f"  ... and {len(failures) - 20} more")
        return 1
    print("claims-ast: every committed claim premise re-derived from program.ast.json")
    return 0


def selfcheck(dirs):
    fail = 0
    for d in dirs:
        import os
        ast_p = os.path.join(d, "program.ast.json")
        err_p = os.path.join(d, "backend.err")
        expect = "PASS"
        marker = os.path.join(d, "EXPECT_FAIL")
        if os.path.exists(marker):
            expect = "FAIL"
        print(f"selfcheck {d} (expect {expect}):")
        rc = check(ast_p, err_p)
        if (rc != 0) != (expect == "FAIL"):
            print(f"  SELFCHECK-MISMATCH: expected {expect}, got {'FAIL' if rc else 'PASS'}")
            fail = 1
    return fail


def main():
    args = sys.argv[1:]
    if args and args[0] == "--selfcheck":
        return selfcheck(args[1:])
    premises_path = None
    if "--premises" in args:
        i = args.index("--premises")
        premises_path = args[i + 1]
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__)
        return 2
    return check(args[0], args[1], premises_path=premises_path)


if __name__ == "__main__":
    sys.exit(main())
