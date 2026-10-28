import fs from "node:fs";
import path from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import type { SerializedOutline } from "./outline.ts";

// A desktop outline runs to hundreds of KB. Keeping one in every tool result's details made a long
// session file grow by tens of MB, all of it read back on resume, though only the newest outline per
// window is ever restored. Session entries now keep the stateId and the outline lives here instead.
// stateIds are UUIDs, so one flat folder serves every session, fork and branch.
const OUTLINE_STORE_LIMIT = 64;

function storeDir(): string {
	return process.env.PI_COMPUTER_USE_OUTLINE_DIR || path.join(getAgentDir(), "cache", "pi-computer-use", "outlines");
}

function outlineFile(stateId: string): string | undefined {
	return /^[\w-]+$/.test(stateId) ? path.join(storeDir(), `${stateId}.json`) : undefined;
}

/** Saves an outline for later restore. Failures only cost a fresh observation after resume. */
export function saveOutline(stateId: string, outline: SerializedOutline): void {
	const file = outlineFile(stateId);
	if (!file) return;
	try {
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, JSON.stringify(outline));
		pruneOutlines();
	} catch {}
}

export function loadOutline(stateId: string): SerializedOutline | undefined {
	const file = outlineFile(stateId);
	if (!file) return undefined;
	try {
		return JSON.parse(fs.readFileSync(file, "utf8")) as SerializedOutline;
	} catch {
		return undefined;
	}
}

function pruneOutlines(): void {
	const dir = storeDir();
	const names = fs.readdirSync(dir).filter((name) => name.endsWith(".json"));
	if (names.length <= OUTLINE_STORE_LIMIT) return;
	const files = names
		.map((name) => {
			const file = path.join(dir, name);
			try {
				return { file, mtime: fs.statSync(file).mtimeMs };
			} catch {
				return undefined;
			}
		})
		.filter((entry): entry is { file: string; mtime: number } => entry !== undefined)
		.sort((a, b) => b.mtime - a.mtime);
	for (const { file } of files.slice(OUTLINE_STORE_LIMIT)) fs.rmSync(file, { force: true });
}
