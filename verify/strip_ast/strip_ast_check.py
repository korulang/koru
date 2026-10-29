#!/usr/bin/env python3
"""strip-ast oracle — re-derives the dead-strip pre-image from program.ast.json
and re-decides the committed [witness] site strip-* ledger against it.

The ledger (src/dead_strip.zig, under std/witness:enforce) commits what the
pass's membership test consulted: strip-use keys, strip-root seedings,
strip-rm (canonical, module-fallback) pairs, strip-cargo fnv1a digests, and a
census. This tool reads the serialized pre-transform AST — the artifact the
backend deserialized into `original_ast` — and independently walks it under
the same rules the pass documents:

  flow            -> body.node.invocation.path + continuations + inline_body
                     text scrape (names before `_event.handler`, bare and
                     <ctx>:<name>, plus hyphenated variants)
  event_tap       -> source/destination paths + continuations
  module_decl     -> recurse with ctx = logical_name
  proc_decl       -> body.text scrape + inline_flows (same as flow)
  immediate_impl  -> event_path
  event_decl      -> path marked when a `retain` annotation is present
  host_line       -> comment-cargo digest

Strict checks (violations):
  UNSPELLED        an artifact-derived use key is missing from the committed
                   strip-use ledger — the pass under-committed the set it
                   tested removals against.
  UNLAWFUL-RM      a committed strip-rm key is spelled in the artifact-derived
                   use set — removing it severs a reference the artifact proves
                   exists.
  ROOT-PROGRAM     a strip-root line in a non-library compile.
  ROOT-MISSING     a pub entry-module event_decl absent from committed roots
                   (--library only).
  ROOT-STRAY       a committed root that is not a pub entry-module decl.

Named boundary (reported, not failed): the pass filters the post-transform
tree, not the artifact. A strip-rm pair absent from the artifact's decl set
is a transform-introduced decl — uncheckable from this channel and reported
as `non-artifact removals: N`. Likewise artifact decls/cargo that transforms
dropped before the strip are outside this oracle's jurisdiction.

Usage: strip_ast_check.py <program.ast.json> <backend.err> [--library]
Exit 0 on conformance, 1 on any violation or missing ledger.
"""

import json
import sys
from collections import Counter


def fnv1a64(data: bytes) -> int:
    h = 0xCBF29CE484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return h


def path_key(p) -> str:
    segs = ".".join(p.get("segments") or [])
    mq = p.get("module_qualifier")
    return f"{mq}:{segs}" if mq else segs


class ArtifactWalk:
    """Mirror of DeadStripPass.collectUsedPaths over the raw JSON tree.

    scrape_ctx is the marking context for inline-body spellings
    (main_module_name at top, mod.logical_name inside modules) — matching
    collectUsedPaths' `main_module` parameter.
    """

    def __init__(self):
        self.used = set()
        self.decls = []        # (canonical, alt) pairs — the filterable decl set
        self.pubs = set()      # library-root candidates
        self.cargo = Counter() # host_line comment-cargo digests

    def mark_bare(self, name: str, ctx: str):
        self.used.add(name)
        if ctx:
            self.used.add(f"{ctx}:{name}")
        if "_" in name:
            hy = name.replace("_", "-")
            self.used.add(hy)
            if ctx:
                self.used.add(f"{ctx}:{hy}")

    def scrape(self, text: str, ctx: str):
        needle = "_event.handler"
        i = 0
        while True:
            idx = text.find(needle, i)
            if idx < 0:
                return
            start = idx
            while start > 0 and (text[start - 1].isalnum() or text[start - 1] == "_"):
                start -= 1
            name = text[start:idx]
            if name:
                self.mark_bare(name, ctx)
            i = idx + len(needle)

    def walk_node(self, node):
        if not isinstance(node, dict):
            return
        for tag, v in node.items():
            if tag == "invocation":
                self.used.add(path_key(v["path"]))
            elif tag == "label_with_invocation":
                self.used.add(path_key(v["invocation"]["path"]))
            elif tag == "conditional_block":
                for n in v.get("nodes") or []:
                    self.walk_node(n)
            elif tag in ("conditional", "foreach", "switch_result"):
                for br in v.get("branches") or []:
                    self.walk_conts(br.get("body") or [])

    def walk_conts(self, conts):
        for c in conts or []:
            self.walk_node(c.get("node"))
            self.walk_conts(c.get("continuations"))

    def walk_flow(self, flow, ctx: str):
        body = flow.get("body") or {}
        node = body.get("node")
        if isinstance(node, dict) and "invocation" in node:
            self.used.add(path_key(node["invocation"]["path"]))
        self.walk_conts(body.get("continuations"))
        ib = flow.get("inline_body")
        if isinstance(ib, dict) and ib.get("text"):
            self.scrape(ib["text"], ctx)

    def walk_items(self, items, scrape_ctx: str, decl_ctx, main_module: str, top: bool):
        for it in items or []:
            if not isinstance(it, dict) or not it:
                continue
            tag, v = next(iter(it.items()))
            if tag == "flow":
                self.walk_flow(v, scrape_ctx)
            elif tag == "event_tap":
                if v.get("source"):
                    self.used.add(path_key(v["source"]))
                if v.get("destination"):
                    self.used.add(path_key(v["destination"]))
                self.walk_conts(v.get("continuations"))
            elif tag == "module_decl":
                ln = v.get("logical_name") or scrape_ctx
                self.walk_items(v.get("items"), ln, ln, main_module, False)
            elif tag == "proc_decl":
                body = v.get("body") or {}
                if body.get("text"):
                    self.scrape(body["text"], scrape_ctx)
                for f in v.get("inline_flows") or []:
                    self.walk_flow(f, scrape_ctx)
            elif tag == "immediate_impl":
                if v.get("event_path"):
                    self.used.add(path_key(v["event_path"]))
            if tag == "event_decl":
                if "retain" in (v.get("annotations") or []):
                    self.used.add(path_key(v["path"]))
            if tag in ("event_decl", "proc_decl"):
                path = v.get("path") or {}
                canon = path_key(path)
                segs = ".".join(path.get("segments") or [])
                alt = f"{decl_ctx}:{segs}" if decl_ctx else "-"
                self.decls.append((canon, alt))
                if top and tag == "event_decl" and v.get("is_public"):
                    if main_module and path.get("module_qualifier") == main_module:
                        self.pubs.add(canon)
            if tag == "host_line":
                content = v.get("content")
                if isinstance(content, str) and self.is_comment_cargo(content):
                    self.cargo[fnv1a64(content.encode("utf-8"))] += 1

    @staticmethod
    def is_comment_cargo(content: str) -> bool:
        saw = False
        for line in content.split("\n"):
            t = line.strip(" \t\r")
            if not t:
                continue
            if t.startswith("//@koru:"):
                return False
            if not t.startswith("//"):
                return False
            saw = True
        return saw


def parse_ledger(err_path):
    uses, roots, rms, cargo = set(), set(), [], Counter()
    census = None
    with open(err_path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("[witness] site strip-"):
                continue
            parts = line.split()
            # [witness] site <kind> <a> <b> <c> [extra]
            if len(parts) < 6:
                continue
            kind, a = parts[2], parts[3]
            if kind == "strip-use":
                uses.add(a)
            elif kind == "strip-root":
                roots.add(a)
            elif kind == "strip-rm":
                rms.append((a, parts[4]))
            elif kind == "strip-cargo":
                # Packed payload: comma-joined digests, up to 64 per line.
                for h in a.split(","):
                    cargo[int(h, 16)] += 1
            elif kind == "strip-census":
                kv = dict(kv.split("=", 1) for kv in parts[5].split(";"))
                census = {k: int(v) for k, v in kv.items()}
    return uses, roots, rms, cargo, census


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ast_path, err_path = sys.argv[1], sys.argv[2]
    library = "--library" in sys.argv[3:]

    with open(ast_path, encoding="utf-8") as f:
        prog = json.load(f)
    main_module = prog.get("main_module_name") or ""

    w = ArtifactWalk()
    w.walk_items(prog.get("items"), main_module, None, main_module, True)

    uses, roots, rms, cargo, census = parse_ledger(err_path)
    if census is None:
        print("BAD: no [witness] site strip-census line — ledger absent", file=sys.stderr)
        return 1

    violations = []

    # Under-commitment: every key the artifact spells must be committed.
    for k in sorted(w.used - uses):
        violations.append(f"UNSPELLED {k} — artifact spells it, ledger never committed it")

    # The removal law, re-decided against the artifact's own reachability.
    for canon, alt in rms:
        if canon in w.used:
            violations.append(f"UNLAWFUL-RM {canon} — artifact-derived use set spells it")
        if alt != "-" and alt in w.used:
            violations.append(f"UNLAWFUL-RM {alt} — artifact-derived use set spells it")

    # Removal identity: which rms name an artifact decl (strict) vs a
    # transform-introduced one (named boundary — reported, not failed).
    # Multiplicity is strict either way: a decl pair can't be removed more
    # times than the artifact declares it.
    decl_count = Counter(w.decls)
    rm_count = Counter(rms)
    non_artifact_rms = [p for p in rms if p not in decl_count]
    for pair, n in rm_count.items():
        if pair in decl_count and n > decl_count[pair]:
            violations.append(f"RM-OVERCOUNT {pair[0]} — removed {n}x, artifact declares {decl_count[pair]}x")

    # Roots.
    if library:
        for p in sorted(w.pubs - roots):
            violations.append(f"ROOT-MISSING {p} — pub entry-module decl never seeded")
        for r in sorted(roots - w.pubs):
            violations.append(f"ROOT-STRAY {r} — committed root is not a pub entry-module decl")
    else:
        for r in sorted(roots):
            violations.append(f"ROOT-PROGRAM {r} — root line in a non-library compile")

    # Cargo: artifact-derived digest multiset must be covered by the ledger.
    for digest, count in (w.cargo - cargo).items():
        violations.append(f"CARGO-MISS {digest:016x} x{count} — artifact cargo the ledger never committed")

    # Census honesty against the committed ledger itself.
    if census.get("uses") != len(uses):
        violations.append(f"CENSUS uses={census.get('uses')} committed {len(uses)}")
    if census.get("roots") != len(roots):
        violations.append(f"CENSUS roots={census.get('roots')} committed {len(roots)}")
    if census.get("removed") != len(rms):
        violations.append(f"CENSUS removed={census.get('removed')} committed {len(rms)}")
    if census.get("cargo") != sum(cargo.values()):
        violations.append(f"CENSUS cargo={census.get('cargo')} committed {sum(cargo.values())}")

    for v in violations:
        print(f"BAD {v}", file=sys.stderr)

    print(f"strip-ast: uses={len(w.used)}/{len(uses)} committed "
          f"rms={len(rms)} decls={len(w.decls)} "
          f"non-artifact-rms={len(non_artifact_rms)} "
          f"cargo={sum(w.cargo.values())}/{sum(cargo.values())} "
          f"{'LIBRARY ' if library else ''}"
          f"{'— ' + str(len(violations)) + ' violations' if violations else '— clean'}",
          file=sys.stderr if violations else sys.stdout)
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
