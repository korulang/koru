#!/usr/bin/env python3
"""
Kebab codemod — pass 1: event/proc NAMES (snake -> kebab).

Region-aware: skips `~proc NAME|var { ... }` Zig bodies entirely (a proc body
is host code; an event name appearing in a Zig string there must NOT change,
and proc bodies never reference event names as identifiers anyway).

Scope deliberately narrow for pass 1:
  - Collect names declared by `~[anno] [pub] event NAME` and `~[anno] [pub] proc NAME`.
  - Only multi-word (contains `_`) names are candidates.
  - Replace whole-word occurrences of those names with their kebab form
    (`_`->`-`) in NON-proc-body lines only (decl sites + call sites + branch
    dispatch + comments).

Field names, bindings, and `_` in numeric literals / Zig bodies are left for
later passes. The full regression suite is the oracle: run it after applying.

Usage:
  kebab_codemod.py --dry-run <files...>   # show per-file replacement counts + sample
  kebab_codemod.py --apply   <files...>   # rewrite in place
"""
import re
import sys

# `~[anno] [pub] (event|proc) NAME` — NAME up to whitespace, `{`, `|`, `(`.
DECL_RE = re.compile(r'^\s*~(?:\[[^\]]*\])?\s*(?:pub\s+)?(?:event|proc)\s+([A-Za-z][\w.]*)')
# A line that starts (after indent) a proc — its `{` opens a Zig body.
PROC_RE = re.compile(r'^\s*~(?:\[[^\]]*\])?\s*(?:pub\s+)?proc\b')


def collect_names(lines):
    names = set()
    for line in lines:
        m = DECL_RE.match(line)
        if not m:
            continue
        name = m.group(1)
        # event/proc names may be dotted (read.ln); take the last segment? No —
        # we convert the whole path's snake segments. Only act if it has `_`.
        if '_' in name:
            names.add(name)
    return names


def kebab(name):
    return name.replace('_', '-')


def proc_body_mask(lines):
    """Return a list[bool]: True where the line is inside a ~proc {...} Zig body."""
    mask = [False] * len(lines)
    depth = 0
    in_body = False
    pending_proc = False  # saw a ~proc line, waiting for its first `{`
    for i, line in enumerate(lines):
        if not in_body and not pending_proc and PROC_RE.match(line):
            pending_proc = True
        if pending_proc or in_body:
            opens = line.count('{')
            closes = line.count('}')
            if pending_proc and opens > 0:
                pending_proc = False
                in_body = True
                depth = 0
            if in_body:
                mask[i] = True  # the `{` line and body lines are Zig
                depth += opens - closes
                if depth <= 0 and (opens > 0 or closes > 0):
                    in_body = False
    return mask


def transform(text):
    lines = text.split('\n')
    names = collect_names(lines)
    if not names:
        return text, 0
    mask = proc_body_mask(lines)
    # Longest-first so `a_b_c` is tried before `a_b`.
    patterns = [(n, re.compile(r'(?<![\w-])' + re.escape(n) + r'(?![\w-])'))
                for n in sorted(names, key=len, reverse=True)]
    count = 0
    out = []
    for i, line in enumerate(lines):
        if mask[i]:
            out.append(line)
            continue
        new = line
        for n, pat in patterns:
            new, k = pat.subn(kebab(n), new)
            count += k
        out.append(new)
    return '\n'.join(out), count


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ('--dry-run', '--apply'):
        print(__doc__)
        sys.exit(2)
    mode = sys.argv[1]
    files = sys.argv[2:]
    total_files = 0
    total_repl = 0
    for path in files:
        try:
            with open(path, 'r') as f:
                text = f.read()
        except (IsADirectoryError, UnicodeDecodeError):
            continue
        new, count = transform(text)
        if count == 0:
            continue
        total_files += 1
        total_repl += count
        if mode == '--dry-run':
            print(f'{count:3d} repl  {path}')
        else:
            with open(path, 'w') as f:
                f.write(new)
    print(f'\n{"DRY-RUN" if mode == "--dry-run" else "APPLIED"}: '
          f'{total_repl} replacements across {total_files} files')


if __name__ == '__main__':
    main()
