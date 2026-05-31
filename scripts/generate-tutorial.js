#!/usr/bin/env node

/**
 * Generate koru-tutorial.md — a 2-3 page teaching artifact.
 *
 * Structure:
 *   1. Title + intro paragraph (what Koru is)
 *   2. Rules section (5-8 things you need to know, each title + body)
 *   3. Examples — picked tests verbatim, in order
 *
 * Driven by koru-by-example.json's `tutorial: { title, intro, rules, tests }`
 * field. Reads tests directly from tests/regression/; does NOT parse
 * koru-by-example.md.
 *
 * Per-test prose is intentionally NOT pulled. The rules section IS the
 * framing prose; the tests are receipts that demonstrate the rules.
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const TESTS_DIR = path.join(ROOT, 'tests', 'regression');
const OUTPUT = path.join(ROOT, 'koru-tutorial.md');
const CONFIG = path.join(ROOT, 'koru-by-example.json');

function collectPassing(dir, breadcrumbs = []) {
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const hasSuccess = entries.some((e) => e.isFile() && e.name === 'SUCCESS');

  if (hasSuccess) {
    // Tests split into the `.k` + host form keep the host bindings (e.g. Zig
    // consts) in input.kz and the portable Koru in input.k. Show them as a
    // single block — host consts first, then the Koru — reproducing the
    // pre-split example. Tests not yet split keep all Koru in input.kz, so the
    // kz-only path is unchanged.
    const inputKzPath = path.join(dir, 'input.kz');
    const inputKPath = path.join(dir, 'input.k');
    const parts = [];
    if (fs.existsSync(inputKzPath))
      parts.push(fs.readFileSync(inputKzPath, 'utf-8').replace(/\n+$/, ''));
    if (fs.existsSync(inputKPath))
      parts.push(fs.readFileSync(inputKPath, 'utf-8').replace(/\n+$/, ''));
    if (parts.length === 0) return [];
    const expectedPath = path.join(dir, 'expected.txt');
    return [
      {
        name: path.basename(dir),
        input: parts.join('\n\n') + '\n',
        expected: fs.existsSync(expectedPath)
          ? fs.readFileSync(expectedPath, 'utf-8')
          : null,
      },
    ];
  }

  const out = [];
  for (const e of entries) {
    if (e.isDirectory()) {
      out.push(
        ...collectPassing(path.join(dir, e.name), [...breadcrumbs, e.name])
      );
    }
  }
  return out;
}

function emitTest(t, lines) {
  lines.push(`### ${t.name}`);
  lines.push('');
  lines.push('```koru');
  for (const line of t.input.replace(/\n+$/, '').split('\n')) {
    lines.push(line);
  }
  lines.push('```');
  lines.push('');
  if (t.expected !== null && t.expected.trim() !== '') {
    lines.push('**Output:**');
    lines.push('');
    lines.push('```');
    for (const line of t.expected.replace(/\n+$/, '').split('\n')) {
      lines.push(line);
    }
    lines.push('```');
    lines.push('');
  }
}

// ----------------------------------------------------------------------

const config = JSON.parse(fs.readFileSync(CONFIG, 'utf-8'));
const tutorial = config.tutorial ?? {};
const title = tutorial.title ?? '';
const disclaimer = tutorial.disclaimer ?? '';
const intro = tutorial.intro ?? '';
const rules = tutorial.rules ?? [];
const testNames = tutorial.tests ?? [];

if (!title && !intro && rules.length === 0 && testNames.length === 0) {
  console.warn(
    '[warn] tutorial config is empty — koru-tutorial.md will be a stub.\n' +
      '       Fill in tutorial.title, tutorial.intro, tutorial.rules, tutorial.tests\n' +
      '       in koru-by-example.json.'
  );
}

const allTests = collectPassing(TESTS_DIR);
const byName = new Map(allTests.map((t) => [t.name, t]));

const picked = [];
const missing = [];
for (const name of testNames) {
  if (byName.has(name)) {
    picked.push(byName.get(name));
  } else {
    missing.push(name);
  }
}
if (missing.length > 0) {
  console.warn('[warn] tutorial.tests not found (or not passing):');
  for (const name of missing) console.warn(`         ${name}`);
}

// ----------------------------------------------------------------------
// Build the document
// ----------------------------------------------------------------------

const lines = [];

lines.push(`# ${title || 'Koru Tutorial'}`);
lines.push('');
lines.push(
  `> Generated ${new Date().toISOString()} by \`scripts/generate-tutorial.js\` from \`koru-by-example.json\`.`
);
lines.push('');

if (disclaimer) {
  // Emit as a multi-paragraph blockquote callout. Only the first line gets
  // the **Note:** label; blank lines become `>` so paragraph breaks render.
  const ds = disclaimer.split('\n');
  for (let i = 0; i < ds.length; i++) {
    const line = ds[i];
    if (line === '') {
      lines.push('>');
    } else if (i === 0) {
      lines.push(`> **Note:** ${line}`);
    } else {
      lines.push(`> ${line}`);
    }
  }
  lines.push('');
}

if (intro) {
  lines.push(intro);
  lines.push('');
}

if (rules.length > 0) {
  lines.push('## The rules');
  lines.push('');
  for (const rule of rules) {
    // Two supported rule shapes:
    //   { title: "...", body: "..." }
    //   "**title.** body..."   (flat string)
    if (typeof rule === 'string') {
      lines.push(rule);
      lines.push('');
    } else {
      lines.push(`### ${rule.title ?? '(untitled rule)'}`);
      lines.push('');
      if (rule.body) {
        lines.push(rule.body);
        lines.push('');
      }
    }
  }
  lines.push('---');
  lines.push('');
}

if (picked.length > 0) {
  lines.push('## Examples');
  lines.push('');
  for (const t of picked) emitTest(t, lines);
}

const body = lines.join('\n') + '\n';
fs.writeFileSync(OUTPUT, body);

const stats = fs.statSync(OUTPUT);
const sizeKB = (stats.size / 1024).toFixed(1);
const totalLines = body.split('\n').length;

console.log(`Wrote ${path.relative(ROOT, OUTPUT)}`);
console.log(
  `  ${picked.length} examples, ${rules.length} rules, ${intro ? 'intro present' : 'no intro'}`
);
console.log(`  ${sizeKB} KB, ${totalLines} lines`);
if (missing.length > 0) {
  console.log(`  ${missing.length} tutorial entries missing (see warnings)`);
}
