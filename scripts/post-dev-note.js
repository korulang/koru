#!/usr/bin/env node
/**
 * Post a short dev note to the #koru-dev-notes Discord channel.
 *
 * Reads DISCORD_DEV_NOTES_WEBHOOK from koru/.env.local (or the environment).
 * Refuses to truncate — Discord's 2000-char limit is the enforced ceiling so
 * notes stay short by construction.
 */

import { readFile } from 'fs/promises';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const ROOT = join(__dirname, '..');

const USAGE = `Usage: node scripts/post-dev-note.js --title <title> [--body <body>] [--emoji <emoji>] [--dry-run]

Posts a short dev note to the #koru-dev-notes Discord channel.

  --title    Title line. Rendered bold, with optional emoji prefix.
  --body     Body markdown. If omitted, reads body from stdin.
  --emoji    Optional emoji prefix for the title (e.g. 🐛, 💡, ✅, 🔥).
  --dry-run  Print the payload instead of posting.

Discord limit per message is 2000 chars; this script refuses to truncate.
Keep notes short. Long write-ups belong in a status update or a blog post.
`;

function parseArgs(argv) {
	const args = { title: null, body: null, emoji: null, dryRun: false };
	for (let i = 0; i < argv.length; i++) {
		const a = argv[i];
		if (a === '--title') args.title = argv[++i];
		else if (a === '--body') args.body = argv[++i];
		else if (a === '--emoji') args.emoji = argv[++i];
		else if (a === '--dry-run') args.dryRun = true;
		else if (a === '--help' || a === '-h') {
			console.log(USAGE);
			process.exit(0);
		} else {
			console.error(`Unknown arg: ${a}\n\n${USAGE}`);
			process.exit(2);
		}
	}
	return args;
}

async function loadEnvFile() {
	const envPath = join(ROOT, '.env.local');
	try {
		const content = await readFile(envPath, 'utf-8');
		for (const line of content.split('\n')) {
			const trimmed = line.trim();
			if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
			const [key, ...rest] = trimmed.split('=');
			if (!process.env[key]) process.env[key] = rest.join('=').trim();
		}
	} catch {
		// missing .env.local is fine — fall back to environment
	}
}

async function readStdin() {
	if (process.stdin.isTTY) return '';
	let data = '';
	for await (const chunk of process.stdin) data += chunk;
	return data;
}

function buildContent(args) {
	const emoji = args.emoji ? `${args.emoji} ` : '';
	const header = `**${emoji}${args.title.trim()}**`;
	const body = (args.body ?? '').trim();
	return body ? `${header}\n${body}` : header;
}

async function main() {
	const args = parseArgs(process.argv.slice(2));
	if (!args.title) {
		console.error(`--title is required\n\n${USAGE}`);
		process.exit(2);
	}
	if (args.body == null) {
		const stdin = await readStdin();
		if (stdin.trim()) args.body = stdin;
	}

	await loadEnvFile();
	const webhook = process.env.DISCORD_DEV_NOTES_WEBHOOK;
	if (!webhook && !args.dryRun) {
		console.error('DISCORD_DEV_NOTES_WEBHOOK is not set (check koru/.env.local).');
		process.exit(1);
	}

	const content = buildContent(args);
	if (content.length > 2000) {
		console.error(
			`Message is ${content.length} chars; Discord limit is 2000. Refusing to truncate — shorten the note.`
		);
		process.exit(1);
	}

	if (args.dryRun) {
		console.log('[DRY RUN] Would post the following to Discord:');
		console.log('---');
		console.log(content);
		console.log('---');
		console.log(`(${content.length} chars)`);
		return;
	}

	const url = new URL(webhook);
	url.searchParams.set('wait', 'true');
	const res = await fetch(url.toString(), {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ content })
	});
	if (!res.ok) {
		const text = await res.text();
		throw new Error(`Discord webhook failed: ${res.status} ${text}`);
	}
	const json = await res.json();
	console.log(`✓ Posted dev note (message id ${json.id}, channel ${json.channel_id}).`);
}

main().catch((err) => {
	console.error('post-dev-note failed:', err.message ?? err);
	process.exitCode = 1;
});
