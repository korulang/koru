#!/usr/bin/env python3
"""
Kebab codemod — snake_case Koru NAMES -> kebab-case.

Two-phase + GLOBAL so cross-file references convert too (an event declared in
one file and called in another):

  Phase 1 (collect, across ALL files): gather declared snake names —
    events/procs (`[~][anno][pub] event|proc NAME`), branch names (`| NAME`),
    and field/arg keys (`NAME:` in Koru regions). Only names containing `_`.

  Phase 2 (apply, per file): region-aware. Skip `~proc {...}` Zig bodies (host
    code — a field used there is the mangled snake form and must stay). In Koru
    regions, replace whole-word occurrences of any collected name with kebab.

NOT handled (left snake on purpose): `_` in numeric literals, host type refs,
and multi-word *bindings* used in arg-value position (those need expression
lowering — refactor the few sites to single-word bindings instead). The full
regression suite is the oracle: run it after applying and iterate.

Usage:
  kebab_codemod.py --dry-run <files...>
  kebab_codemod.py --apply   <files...>
"""
import re
import sys

DECL_RE = re.compile(r'^\s*~?(?:\[[^\]]*\])?\s*(?:pub\s+)?(?:event|proc)\s+([A-Za-z][\w.]*)')
PROC_RE = re.compile(r'^\s*~?(?:\[[^\]]*\])?\s*(?:pub\s+)?proc\b')
BRANCH_RE = re.compile(r'^\s*\|\s*([a-z][\w]*)')
# `name:` field/arg key — snake identifier immediately followed by `:` (not `::`).
KEY_RE = re.compile(r'(?<![\w.])([a-z][a-z0-9]*_[a-z0-9_]*)\s*:(?!:)')
# Host (Zig/JS) declarations inside a `.kz`/`.kjs` — NOT Koru. Their bodies and
# fields (e.g. `const X = struct { type_name: T }`) must NOT be kebab'd.
HOST_OPEN = re.compile(r'^\s*(?:pub\s+)?(?:const|var|comptime|inline\s+fn|export\s+fn|extern\s+fn|fn)\b')


def has_underscore(name):
    return '_' in name


def host_mask(lines):
    """list[bool]: True where the line is HOST code (not Koru), so the kebab
    rewrite must skip it. Covers two host regions in a mixed `.kz`:
      1. `~proc {...}` bodies — the decl line is NOT masked (proc name converts).
      2. host declarations `[pub] const|var|fn ... [{ ... }]` — fully masked,
         incl. `const X = struct { snake_field: T }` and `const x = @import(...)`.
    """
    mask = [False] * len(lines)
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if PROC_RE.match(line):
            j = i
            while j < n and '{' not in lines[j]:
                j += 1
            if j >= n:
                i += 1
                continue
            depth = lines[j].count('{') - lines[j].count('}')
            k = j + 1
            while k < n and depth > 0:
                mask[k] = True
                depth += lines[k].count('{') - lines[k].count('}')
                k += 1
            i = k
            continue
        if HOST_OPEN.match(line):
            # A host decl is either a STATEMENT (`const x = ...;`) or a BLOCK
            # (`fn f(...) T { ... }`, `const X = struct { ... };`). The opening
            # `{` — or the terminating `;` for a statement — can sit several
            # lines below the keyword when a function signature wraps across
            # lines. Mask the keyword line, then keep masking until the block
            # closes (depth back to 0 after the first `{`) or, for a braceless
            # statement, until the first `;`. Masking only the keyword line (the
            # old behavior) leaked wrapped signature params into the rewrite.
            mask[i] = True
            depth = line.count('{') - line.count('}')
            saw_brace = '{' in line
            if not saw_brace and ';' in line:
                i += 1
                continue
            j = i + 1
            while j < n:
                mask[j] = True
                if '{' in lines[j]:
                    saw_brace = True
                depth += lines[j].count('{') - lines[j].count('}')
                if saw_brace and depth <= 0:
                    j += 1
                    break
                if not saw_brace and ';' in lines[j]:
                    j += 1
                    break
                j += 1
            i = j
            continue
        i += 1
    return mask


# Back-compat alias used below.
proc_body_mask = host_mask


def collect_from(text, names, keys):
    """names = event/proc/branch names (converted bare — decl + call sites).
    keys  = field/arg keys (converted ONLY in key position `name:`, NEVER in
            value/binding position — a binding ref in a value is a host
            expression forwarded verbatim and must stay snake)."""
    lines = text.split('\n')
    mask = host_mask(lines)
    for i, line in enumerate(lines):
        if mask[i]:
            continue
        m = DECL_RE.match(line)
        if m and has_underscore(m.group(1)):
            names.add(m.group(1))
        b = BRANCH_RE.match(line)
        if b and has_underscore(b.group(1)):
            names.add(b.group(1))
        for k in KEY_RE.findall(line):
            if has_underscore(k):
                keys.add(k)


def kebab(name):
    return name.replace('_', '-')


def apply_to(text, name_patterns, key_patterns):
    lines = text.split('\n')
    mask = host_mask(lines)
    count = 0
    out = []
    for i, line in enumerate(lines):
        if mask[i]:
            out.append(line)
            continue
        new = line
        for n, pat in name_patterns:
            new, k = pat.subn(kebab(n), new)
            count += k
        for n, pat in key_patterns:
            new, k = pat.subn(kebab(n), new)  # pattern lookahead leaves `:` in place
            count += k
        out.append(new)
    return '\n'.join(out), count


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except (IsADirectoryError, UnicodeDecodeError, FileNotFoundError):
        return None


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('--dry-run', '--apply'):
        print(__doc__)
        sys.exit(2)
    mode, files = sys.argv[1], sys.argv[2:]

    # Phase 1: global collection.
    names, keys = set(), set()
    for p in files:
        t = read(p)
        if t is not None:
            collect_from(t, names, keys)
    print(f'collected {len(names)} names + {len(keys)} keys to kebab-ify')

    # Names (events/procs/branches): bare whole-word (decl + call sites).
    name_patterns = [(n, re.compile(r'(?<![\w-])' + re.escape(n) + r'(?![\w-])'))
                     for n in sorted(names, key=len, reverse=True)]
    # Keys (field/arg keys): ONLY in key position `name:` — never value/binding.
    key_patterns = [(n, re.compile(r'(?<![\w-])' + re.escape(n) + r'(?=\s*:(?!:))'))
                    for n in sorted(keys, key=len, reverse=True)]

    # Phase 2: apply.
    total_files = total_repl = 0
    for p in files:
        t = read(p)
        if t is None:
            continue
        new, c = apply_to(t, name_patterns, key_patterns)
        if c == 0:
            continue
        total_files += 1
        total_repl += c
        if mode == '--dry-run':
            print(f'{c:4d} repl  {p}')
        else:
            with open(p, 'w') as f:
                f.write(new)
    print(f'\n{"DRY-RUN" if mode == "--dry-run" else "APPLIED"}: '
          f'{total_repl} replacements across {total_files} files')


if __name__ == '__main__':
    main()
