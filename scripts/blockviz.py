#!/usr/bin/env python3
"""blockviz — render a .k/.kz file's flow layer as an indented block tree.

Reads `koruc --ast-json` output and prints the continuation structure the
way a block editor would nest it: invocations as call blocks, `| branch`
arms as sub-stacks, `!` effect arms marked, `when` guards shown, `=>`/
`->` constructors as reporters, `_` as cap.

Usage: blockviz.py <file.k> [--json path]
Spike for BLOCK_EDITOR.md §13 — read-direction only, zero compiler changes.
"""
import json, subprocess, sys, os

KORUC = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "koruc")

def load(path):
    if path.endswith(".json"):
        return json.load(open(path))
    out = subprocess.run([KORUC, "--ast-json", path], capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        sys.exit(1)
    return json.loads(out.stdout)

def fmt_args(args):
    parts = []
    for a in args or []:
        v = a.get("value", "")
        n = a.get("name") or ""
        if n and n != "expr" and n != v:
            parts.append(f"{n}: {v}")
        else:
            parts.append(v)
    return ", ".join(parts)

def fmt_invocation(inv):
    if not inv: return "<?>"
    path = ".".join(inv.get("event", [])) or "<?>"
    args = fmt_args(inv.get("args"))
    var = inv.get("variant")
    s = f"{path}({args})"
    if var: s += f" |{var}"
    rb = inv.get("return_binding")
    if rb: s += f" : {rb}"
    return s

def fmt_step(step):
    if step is None: return "∅"
    t = step.get("type")
    if t == "invocation": return fmt_invocation(step.get("invocation"))
    if t == "terminal": return "_"
    if t == "branch_constructor":
        bc = step["branch_constructor"]
        name = bc.get("branch_name", "")
        pv = bc.get("plain_value")
        if pv is not None: return f"=> {name} {pv}"
        return f"=> {name}"
    if t == "label_apply": return f"#{step.get('label', step.get('label_apply','?'))}"
    if t == "label_jump": return f"@{step.get('label', step.get('label_jump','?'))}"
    if t == "label_with_invocation":
        lwi = step.get("label_with_invocation", {})
        return f"#{lwi.get('label','?')} {fmt_invocation(lwi.get('invocation'))}"
    if t == "expression": return step.get("expression", "<expr>")
    return f"<{t}>"

def render_continuation(c, depth, out):
    branch = c.get("branch", "")
    kind = c.get("kind", "terminal")
    bang = "!" if kind == "effect" else "|"
    binding = c.get("binding") or ""
    cond = c.get("condition")
    destr = c.get("destructure")
    catchall = "*" if c.get("is_catchall") else ""
    if branch == "" and not binding:
        head = f"{bang}> "  # chain step — no arm label
    else:
        head = f"{bang} {branch}{catchall}"
        if binding: head += f" {binding}"
        if destr: head += f" {{{destr}}}"
        if cond: head += f" when {cond}"
        head += " "
    step = c.get("step")
    label = fmt_step(step) if step else ""
    out.append("  " * depth + head + label)
    for sub in c.get("continuations") or []:
        render_continuation(sub, depth + 1, out)

def render_flow(item, out):
    inv = item.get("invocation")
    out.append(fmt_invocation(inv))
    rb = inv.get("return_binding") if inv else None
    for c in item.get("continuations") or []:
        render_continuation(c, 1, out)

def main():
    path = sys.argv[1]
    ast = load(path)
    for item in ast.get("items", []):
        t = item.get("type")
        if t == "import_decl":
            print(f"import {item.get('path')}")
        elif t == "comment":
            print(f"// {item.get('content','').rstrip()}")
        elif t == "event_decl":
            ins = ", ".join(f"{f['name']}: {f.get('type','?')}" for f in (item.get("input") or {}).get("fields", []))
            arms = " ".join(f"| {b['name']}" for b in item.get("branches", []))
            print(f"tor {item.get('name')} {{{ins}}} {arms}")
        elif t == "flow":
            if item.get("pre_label"): print(f"#{item['pre_label']}", end=" ")
            impl = item.get("impl_of")
            if impl: print(f"impl {'/'.join(impl)} ", end="")
            out = []
            out.append(fmt_invocation(item.get("invocation")))
            for c in item.get("continuations") or []:
                render_continuation(c, 1, out)
            print("\n".join(out))
            print()
        elif t == "proc_decl":
            print(f"proc {item.get('name')}|{item.get('target','?')} {{ ... }}")
        elif t == "host_line":
            print(f"~ {item.get('content','')[:60]}")
        elif t == "label_decl":
            print(f"label {item.get('name')}")
        elif t == "event_tap":
            print("tap ...")
        else:
            print(f"<{t}>")

if __name__ == "__main__":
    main()
