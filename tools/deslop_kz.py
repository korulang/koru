#!/usr/bin/env python3
"""deslop_kz — clone census for Koru sources over `koruc --ast-canon`.

Sibling of tools/deslop.zig: where that walks the Zig AST's token spans,
this walks the canon JSON the compiler emits per .kz/.k file. The canon
is already trivia-stripped; on top of it we apply the same Type-2
normalization — name and literal payloads fold to markers, structural
fields (dict keys, discriminants, order) stay. Equal normalized hashes
form a clone cluster; a member is shadowed when an ancestor is also
duplicated (the parent being equal IS the bigger clone), matching the
Zig census's maximal-member rule.

Usage:
  deslop_kz.py <koruc> <root>... [--min-nodes=N] [--top=N] [--jobs=N]
  deslop_kz.py <koruc> <root>... --host [--min-tokens=N] [--top=N] [--jobs=N]

--host runs the OTHER census: the Zig the .kz layer is made of. Canon
renders that layer opaque — bare Zig arrives as `host_line` content
strings and `~proc|zig` bodies as `body.text`, neither fingerprinted
above. This mode extracts every fragment verbatim (content scan gives
true source lines), reassembles each file as a synthetic .zig —
proc bodies wrapped in `fn __kz_host_N() void {}` — and hands the
set to tools/deslop.zig, so both censuses share ONE token-normalized
fingerprint. Member locations are remapped back through the per-file
line map, so clusters name `file.kz:line` ranges, not synthetic ones.
"""

import bisect
import concurrent.futures
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

# Fields whose values are names or literal payloads — folded to markers.
# Discriminant fields (kind, variant, booleans, counts) stay literal:
# they are the structure a clone comparison must keep.
NAME_KEYS = {
    "name", "local_name", "binding", "return_binding", "segments",
    "module_qualifier", "module", "pre_label", "content", "value",
    "text", "source_module", "label", "id", "alias", "path",
}

ID, STR = "\x00ID", "\x00STR"


def hash_tree(node, key, memo):
    """Bottom-up pass: (hash, size, label) per node, memoized by object
    identity so the top-down pass can resolve ancestor hashes."""
    i = id(node)
    if i in memo:
        return memo[i]
    if isinstance(node, dict):
        parts, size, label = [], 0, ""
        for k in sorted(node):
            h, s, lab = hash_tree(node[k], k, memo)
            if h is None:
                continue
            parts.append(k + "=" + h)
            size += s
            if not label and lab:
                label = lab
        if not parts:
            memo[i] = (None, 0, "")
            return memo[i]
        tag = next(iter(node)) if len(node) == 1 else ""
        res = (hashlib.blake2b(("{" + ",".join(parts) + "}").encode(),
                              digest_size=16).hexdigest(),
               size, tag or label)
    elif isinstance(node, list):
        parts, size, label = [], 0, ""
        for item in node:
            h, s, lab = hash_tree(item, key, memo)
            if h is None:
                continue
            parts.append(h)
            size += s
            if not label and lab:
                label = lab
        if not parts:
            memo[i] = (None, 0, "")
            return memo[i]
        res = (hashlib.blake2b(("[" + ",".join(parts) + "]").encode(),
                              digest_size=16).hexdigest(),
               size, label)
    else:
        if node is None or node == "":
            memo[i] = (None, 0, "")
            return memo[i]
        if isinstance(node, bool):
            res = (repr(node), 1, "")
        elif isinstance(node, (int, float)):
            res = ("NUM", 1, "")
        else:
            v = (ID if key in NAME_KEYS else
                 STR if "\n" in node or len(node) > 40
                 else json.dumps(node))
            res = (v, 1, node if key in ("name", "local_name", "path")
                   else "")
    memo[i] = res
    return res


def collect(node, memo, file_idx, parents, out, spellings):
    """Top-down pass: every node big enough is a member carrying its
    ancestor-hash set for the shadowing rule; invocation paths feed the
    corpus's spelling histogram."""
    h, size, label = memo.get(id(node), (None, 0, ""))
    if h is None:
        return
    if size >= MIN_NODES:
        out.append((h, file_idx, size, label, parents))
    mine = parents | {h}
    if isinstance(node, dict):
        inv = node.get("invocation")
        if isinstance(inv, dict) and isinstance(inv.get("path"), dict):
            seg = inv["path"]
            mq = seg.get("module_qualifier")
            spellings.add(((mq + ":") if mq else "")
                          + ".".join(seg.get("segments") or []))
        for k in node:
            collect(node[k], memo, file_idx, mine, out, spellings)
    elif isinstance(node, list):
        for item in node:
            collect(item, memo, file_idx, mine, out, spellings)


def collect_files(roots):
    out = []
    for root in roots:
        if os.path.isfile(root):
            if root.endswith((".kz", ".k")):
                out.append(root)
            continue
        for dirpath, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in
                       (".git", ".claude", ".zig-cache", "zig-out",
                        "node_modules")]
            out.extend(os.path.join(dirpath, f) for f in files
                       if f.endswith((".kz", ".k")))
    return sorted(out)


def ast_of(path):
    # Windows host: parallel subprocess pipes flake on win32 — a
    # CompletedProcess can come back rc=0 with stdout=None (pipe reader
    # lost the capture under handle-inheritance contention). That is a
    # transport failure, not a canon verdict: bounded retry, and if the
    # pipe never delivers the file lands in skipped like any unparseable.
    proc = None
    for _ in range(4):
        proc = subprocess.run([KORUC, "--ast-canon", path],
                              capture_output=True, text=True)
        if proc.stdout is not None:
            break
    if proc is None or proc.returncode != 0 or proc.stdout is None:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


# --- --host: the Zig layer -------------------------------------------------

def find_line(src, content, pos):
    """Byte offset of `content` occurring as a WHOLE line at or after
    `pos`, or -1. host_line content is verbatim source text; the
    whole-line test keeps short lines from matching inside longer ones."""
    p = src.find(content, pos)
    while p >= 0:
        bol = p == 0 or src[p - 1] == "\n"
        eol = p + len(content) == len(src) or src[p + len(content)] == "\n"
        if bol and eol:
            return p
        p = src.find(content, p + 1)
    return -1


def synth_file(path, tree):
    """Extract a .kz file's Zig layer into a synthetic .zig.

    Returns (text, smap, unmatched): smap[i] is the 1-based source line of
    synthetic line i (0 = glue we injected); unmatched lists fragments the
    content scan could not place, so misses are loud rather than silent."""
    src = open(path, encoding="utf-8").read()
    starts = [0]
    for i, ch in enumerate(src):
        if ch == "\n":
            starts.append(i + 1)
    line_of = lambda p: bisect.bisect_right(starts, p)

    out, smap, unmatched = [], [], []
    pos, seq = 0, 0
    for it in tree.get("items", []):
        if not isinstance(it, dict) or len(it) != 1:
            continue
        kind, v = next(iter(it.items()))
        if kind == "host_line" and isinstance(v, dict):
            c = v.get("content")
            if not isinstance(c, str) or not c.strip():
                continue
            p = find_line(src, c, pos)
            if p < 0:  # tolerate trailing-whitespace divergence
                stripped = c.strip()
                q = pos
                while True:
                    q = src.find(stripped, q)
                    if q < 0:
                        break
                    ls = src.rfind("\n", 0, q) + 1
                    tail = src[q + len(stripped):].split("\n", 1)[0]
                    if src[ls:q].strip() == "" and tail.strip() == "":
                        p = q
                        break
                    q += 1
            if p < 0:
                unmatched.append(("host_line", c[:60]))
                continue
            nl = src.find("\n", p)
            pos = nl + 1 if nl >= 0 else len(src)
            out.append(c)
            smap.append(line_of(p))
            continue
        if not isinstance(v, dict):
            continue
        b = v.get("body")
        if not (isinstance(b, dict) and isinstance(b.get("text"), str)
                and "scope" in b and v.get("target", "zig") == "zig"):
            continue
        t = b["text"]
        if not t.strip():
            continue
        p = src.find(t, pos)
        tt = t
        if p < 0:
            tt = t.strip()
            p = src.find(tt, pos)
        if p < 0:
            unmatched.append(("body", str(v.get("path", "?"))[:60]))
            continue
        l0 = line_of(p)
        out.append(f"fn __kz_host_{seq}() void {{")
        smap.append(l0)
        for j, bl in enumerate(tt.split("\n")):
            out.append(bl)
            smap.append(l0 + j)
        out.append("}")
        smap.append(l0 + tt.count("\n"))
        seq += 1
        pos = p + len(tt)
    return "\n".join(out) + "\n", smap, unmatched


def host_census(paths):
    """Extract every file's Zig layer, run tools/deslop.zig over the
    synthetics, and remap member locations back to .kz coordinates."""
    import re
    asts = {}
    with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
        for path, tree in zip(paths, ex.map(ast_of, paths)):
            if tree is not None:
                asts[path] = tree

    tmpdir = tempfile.mkdtemp(prefix="deslop_host_") + os.sep
    smaps, unmatched = {}, []
    for path in sorted(asts):
        text, smap, un = synth_file(path, asts[path])
        unmatched.extend((path, k, s) for k, s in un)
        if not text.strip():
            continue
        # `path` may be `../koru_std/x.kz` — sanitize before joining or the
        # synthetic lands outside tmpdir
        safe = os.sep.join(p for p in os.path.normpath(path).split(os.sep)
                           if p not in ("..", ""))
        rel = safe + ".zig"
        sp = os.path.join(tmpdir, rel)
        os.makedirs(os.path.dirname(sp), exist_ok=True)
        with open(sp, "w", encoding="utf-8") as f:
            f.write(text)
        smaps[rel] = smap
    skipped = len(paths) - len(asts)

    deslop_zig = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              "deslop.zig")
    cmd = ["zig", "run", "-O", "ReleaseFast", deslop_zig,
           "--", tmpdir, f"--min-tokens={MIN_TOKENS}", f"--top={TOP}"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        shutil.rmtree(tmpdir, ignore_errors=True)
        print("BROKEN deslop-host: fingerprint run failed\n"
              + (proc.stdout + proc.stderr).strip()[-2000:])
        sys.exit(2)

    member_re = re.compile(
        r"^(\s+)" + re.escape(tmpdir) + r"(.+?):(\d+)-(\d+)\s*$")

    def remap(line):
        m = member_re.match(line)
        if not m:
            return line
        indent, rel, l0, l1 = m.groups()
        smap = smaps.get(rel)
        if smap is None:
            return line
        a = smap[int(l0) - 1] if 0 < int(l0) <= len(smap) else 0
        z = smap[int(l1) - 1] if 0 < int(l1) <= len(smap) else 0
        lo, hi = (a or z), (z or a)
        return f"{indent}{rel[:-4]}:{lo}-{hi}"

    print(f"host layer: {len(smaps)} synthetics from {len(asts)} parsed "
          f"files ({skipped} skipped canon, {len(unmatched)} unmatched "
          f"fragments)")
    for pth, k, frag in unmatched[:10]:
        print(f"      UNMAPPED {k} {pth}: {frag}")
    for line in proc.stdout.splitlines():
        print(remap(line))

    # loud parse check: deslop names skipped synthetics on stderr
    for line in proc.stderr.splitlines():
        m = re.match(r"deslop: skipped " + re.escape(tmpdir) + r"(.*?) "
                     r"\((\d+) parse errors\)", line)
        if m:
            print(f"  UNPARSEABLE synthetic {m.group(1)[:-4]}: "
                  f"{m.group(2)} parse errors")
        elif line.startswith("deslop: skipped"):
            print(" ", line)
    shutil.rmtree(tmpdir, ignore_errors=True)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    global KORUC, MIN_NODES, MIN_TOKENS, TOP, JOBS
    KORUC = os.path.abspath(args[0])
    if not os.path.exists(KORUC) and os.path.exists(KORUC + ".exe"):
        KORUC += ".exe"  # Windows host: the binary carries an extension
    roots = args[1:]
    MIN_NODES, MIN_TOKENS, TOP, JOBS = 32, 48, 20, 8
    host = "--host" in sys.argv[1:]
    for a in sys.argv[1:]:
        if a.startswith("--min-nodes="):
            MIN_NODES = int(a[12:])
        elif a.startswith("--min-tokens="):
            MIN_TOKENS = int(a[13:])
        elif a.startswith("--top="):
            TOP = int(a[6:])
        elif a.startswith("--jobs="):
            JOBS = int(a[7:])

    paths = collect_files(roots)
    if host:
        host_census(paths)
        return
    asts = {}
    with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
        for path, tree in zip(paths, ex.map(ast_of, paths)):
            if tree is not None:
                asts[path] = tree

    files = sorted(asts)
    members = []
    spellings = set()
    for fidx, path in enumerate(files):
        memo = {}
        hash_tree(asts[path], None, memo)
        collect(asts[path], memo, fidx, frozenset(), members, spellings)

    clusters = {}
    for m in members:
        clusters.setdefault(m[0], []).append(m)
    clustered = {h for h, ms in clusters.items() if len(ms) >= 2}

    # shadowed ⇔ an ancestor's hash is itself clustered (the containing
    # clone is the bigger one; nested copies don't double-count)
    rows, n_clusters, dup_members = [], 0, 0
    for h, ms in clusters.items():
        if len(ms) < 2:
            continue
        n_clusters += 1
        maximal = [m for m in ms if not m[4] & clustered]
        if len(maximal) < 2:
            continue
        dup_members += len(maximal)
        size = maximal[0][2]
        weight = size * (len(maximal) - 1)
        rows.append((weight, size, maximal[0][3], maximal,
                     len({m[1] for m in maximal}) > 1))
    rows.sort(key=lambda r: -r[0])

    skipped = len(paths) - len(asts)
    print(f"files: {len(asts)} parsed, {skipped} skipped   "
          f"nodes hashed >= {MIN_NODES}: {len(members)}")
    print(f"clusters: {n_clusters}   maximal members: {dup_members}")
    print(f"skipped: {skipped}   spellings: {len(spellings)}\n")
    for i, (w, size, tag, ms, cross) in enumerate(rows[:TOP]):
        print(f"#{i + 1:2} w={w:7.0f}  {len(ms)}x {tag or '?'}  "
              f"{size} leaves{'  [cross-file]' if cross else ''}")
        for m in ms[:8]:
            print(f"      {files[m[1]]}")
        if len(ms) > 8:
            print(f"      ... +{len(ms) - 8} more")


if __name__ == "__main__":
    main()
