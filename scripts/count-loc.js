#!/usr/bin/env node
/**
 * Koru LOC Counter
 *
 * Counts lines per language across files tracked by git. Using `git ls-files`
 * as the source of truth means we automatically skip build artifacts, scratch
 * binaries, and anything else .gitignored — no exclusion list to maintain.
 *
 * Emits one bucket per extension we explicitly care about. Tracked files of
 * other extensions (marker files, test snapshots, .txt fixtures, etc.) are
 * ignored — they would distort a "languages in this codebase" view.
 */

import { readFile } from 'fs/promises';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { spawn } from 'child_process';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const KORU_ROOT = join(__dirname, '..');

// Extension → display name. Files with extensions outside this map are skipped.
// Languages share buckets if they should: e.g. .kz files all bucket into "Koru".
const EXTENSION_LANGUAGES = {
	kz: 'Koru',
	zig: 'Zig',
	md: 'Markdown',
	sh: 'Shell',
	js: 'JavaScript',
	py: 'Python'
};

function listTrackedFiles(repoRoot) {
	return new Promise((resolve, reject) => {
		const proc = spawn('git', ['-C', repoRoot, 'ls-files', '-z'], {
			stdio: ['ignore', 'pipe', 'pipe']
		});
		let stdout = '';
		let stderr = '';
		proc.stdout.on('data', (chunk) => {
			stdout += chunk.toString('utf-8');
		});
		proc.stderr.on('data', (chunk) => {
			stderr += chunk.toString('utf-8');
		});
		proc.on('error', reject);
		proc.on('close', (code) => {
			if (code !== 0) {
				reject(new Error(`git ls-files exited ${code}: ${stderr.trim()}`));
				return;
			}
			const files = stdout.split('\0').filter(Boolean);
			resolve(files);
		});
	});
}

function extensionOf(path) {
	const slash = path.lastIndexOf('/');
	const base = slash >= 0 ? path.slice(slash + 1) : path;
	const dot = base.lastIndexOf('.');
	if (dot <= 0) return null;
	return base.slice(dot + 1).toLowerCase();
}

async function countLinesInFile(absPath) {
	const content = await readFile(absPath, 'utf-8');
	if (content.length === 0) return 0;
	// Lines = newline count + 1 if last char isn't a newline.
	let nl = 0;
	for (let i = 0; i < content.length; i++) {
		if (content.charCodeAt(i) === 10) nl++;
	}
	return content.endsWith('\n') ? nl : nl + 1;
}

export async function countLOC(repoRoot = KORU_ROOT) {
	const files = await listTrackedFiles(repoRoot);
	const buckets = {};

	for (const rel of files) {
		const ext = extensionOf(rel);
		if (!ext) continue;
		const language = EXTENSION_LANGUAGES[ext];
		if (!language) continue;

		let lines;
		try {
			lines = await countLinesInFile(join(repoRoot, rel));
		} catch {
			// Symlinks, deleted-but-tracked, or unreadable files: skip.
			continue;
		}

		if (!buckets[language]) buckets[language] = { files: 0, lines: 0 };
		buckets[language].files += 1;
		buckets[language].lines += lines;
	}

	return buckets;
}

// Allow running as a CLI for debugging / one-off inspection.
if (import.meta.url === `file://${process.argv[1]}`) {
	countLOC()
		.then((loc) => {
			console.log(JSON.stringify(loc, null, 2));
		})
		.catch((err) => {
			console.error('count-loc failed:', err);
			process.exit(1);
		});
}
