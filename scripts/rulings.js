#!/usr/bin/env node
// rulings.js — the queue of tests whose verdict is waiting on a DECISION.
//
// A `NEEDS_RULING` file in a test directory means: this test cannot be made right
// until someone decides what the language SHOULD do. It is the one blocker the
// suite cannot clear by working harder, so it gets its own surface instead of
// sitting inside the failure list looking like debt.
//
// What it is NOT:
//   - not a STATUS. A NEEDS_RULING test keeps whatever verdict it had; a red one stays
//     in the failure count. Parking a question can never flatter the pass rate,
//     and that is the property that makes the marker safe to reach for.
//   - not a replacement for TODO. The two answer different questions and compose:
//     TODO says "this does not run", NEEDS_RULING says "a decision is what unblocks it".
//     A test can carry both — commonly the ruling IS what the spelling waits on,
//     so there is nothing to run yet. Those are listed here as parked, and their
//     behaviour is only re-observed under `--todo-sweep`.
//
// The file's first line is the question. Everything after it is context: the
// options, what each would cost, what already depends on the answer.
//
// `prose-check:E` (scripts/prose_check.sh) fails the run when a NEEDS_RULING marker
// stops describing its test — the moment the test passes, the marker is stale.
//
// Usage:
//   node scripts/rulings.js            the queue, newest board status attached
//   node scripts/rulings.js --json     same, machine-readable
//   node scripts/rulings.js --full     include each marker's full body

import { readdir, readFile, stat } from 'node:fs/promises';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const TESTS = join(ROOT, 'tests/regression');
const SNAPSHOT = join(ROOT, 'test-results/latest.json');

const args = process.argv.slice(2);
const asJson = args.includes('--json');
const showFull = args.includes('--full');

async function exists(p) {
	try {
		await stat(p);
		return true;
	} catch {
		return false;
	}
}

async function findMarkers(dir, out = []) {
	let entries;
	try {
		entries = await readdir(dir, { withFileTypes: true });
	} catch {
		return out;
	}
	for (const e of entries) {
		if (e.name === '_archive') continue;
		const full = join(dir, e.name);
		if (e.isDirectory()) await findMarkers(full, out);
		else if (e.name === 'NEEDS_RULING') out.push(full);
	}
	return out;
}

// The board is the authority on what a test currently does. Without a snapshot
// we say so rather than guessing from SUCCESS/FAILURE markers, which a filtered
// run leaves in whatever state it touched.
async function loadBoard() {
	if (!(await exists(SNAPSHOT))) return null;
	const snap = JSON.parse(await readFile(SNAPSHOT, 'utf8'));
	const byDir = new Map();
	for (const c of snap.categories ?? [])
		for (const t of c.tests ?? []) byDir.set(t.directory, t);
	return { snap, byDir };
}

const board = await loadBoard();
const markers = (await findMarkers(TESTS)).sort();

const rows = [];
for (const marker of markers) {
	const dir = dirname(marker);
	const body = await readFile(marker, 'utf8');
	const lines = body.split('\n');
	const question = (lines[0] ?? '').trim();
	const directory = dir.split('/').pop();
	const entry = board?.byDir.get(directory);
	rows.push({
		id: directory.match(/^\d+[a-z]?_\d+/)?.[0] ?? directory,
		directory,
		path: relative(ROOT, dir),
		question,
		status: entry?.status ?? 'unmeasured',
		failureReason: entry?.failureReason ?? '',
		body: body.trim(),
		alsoTodo: await exists(join(dir, 'TODO'))
	});
}

if (asJson) {
	console.log(
		JSON.stringify(
			{
				board: board ? { gitCommit: board.snap.gitCommit, timestamp: board.snap.timestamp } : null,
				count: rows.length,
				rulings: rows.map(({ body, ...r }) => (showFull ? { ...r, body } : r))
			},
			null,
			2
		)
	);
	process.exit(0);
}

if (rows.length === 0) {
	console.log('No NEEDS_RULING markers — nothing in the corpus is waiting on a decision.');
	console.log('Mark one: write the question as the first line of tests/regression/<…>/<test>/NEEDS_RULING');
	process.exit(0);
}

const boardLabel = board
	? `board ${board.snap.gitCommit} (${board.snap.timestamp.slice(0, 16).replace('T', ' ')})`
	: 'no snapshot — statuses unmeasured';
console.log(`${rows.length} test(s) waiting on a ruling — ${boardLabel}\n`);

for (const r of rows) {
	const mark = r.status === 'failure' ? 'red' : r.status === 'success' ? 'GREEN' : r.status;
	// A parked test's failureReason is a fossil: TODO short-circuits before koruc
	// runs, and run_regression.sh exempts TODO dirs from marker cleanup, so the
	// FAILURE file sitting there dates from whenever it last actually ran.
	const why = r.status === 'failure' && r.failureReason ? ` (${r.failureReason})` : '';
	console.log(`  ${r.id}  [${mark}${why}]  ${r.path}`);
	console.log(`      ${r.question}`);
	if (r.status === 'success')
		console.log(`      ⚠ this test PASSES — the question is settled or the pin rotted. prose-check:E fails on it.`);
	if (r.alsoTodo) {
		console.log(`      · parked (TODO): it does not run on a normal board, so its current`);
		console.log(`        behaviour is only re-observed under --todo-sweep.`);
	}
	if (showFull) {
		console.log('');
		for (const line of r.body.split('\n').slice(1)) console.log(`      ${line}`);
	}
	console.log('');
}

console.log('Answer one by deleting its NEEDS_RULING file and writing the decision into the test');
console.log('header — plus a concept under concepts/ if a belief moved.');
