#!/usr/bin/env node
import { open, stat, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";

function identity(info) {
  return info ? `${info.dev}:${info.ino}` : null;
}

function infoFromStats(info) {
  return {
    dev: info.dev.toString(),
    ino: info.ino.toString(),
    size: Number(info.size),
    mtime: info.mtimeNs.toString(),
  };
}

async function fileInfo(path) {
  try {
    const info = await stat(path, { bigint: true });
    return infoFromStats(info);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function readRange(path, start, end, expectedInfo = null) {
  if (end <= start) return "";
  const handle = await open(path, "r");
  try {
    const openedInfo = infoFromStats(await handle.stat({ bigint: true }));
    if (expectedInfo && identity(openedInfo) !== identity(expectedInfo)) {
      throw new Error(`${path} changed before its expected bytes could be read`);
    }
    if (openedInfo.size < end) {
      throw new Error(`${path} shrank before its expected bytes could be read`);
    }
    const length = end - start;
    const buffer = Buffer.alloc(length);
    const { bytesRead } = await handle.read(buffer, 0, length, start);
    if (bytesRead !== length) {
      throw new Error(`${path} changed while its expected bytes were read`);
    }
    return buffer.subarray(0, bytesRead).toString("utf8");
  } finally {
    await handle.close();
  }
}

/**
 * Follows one active log and its `.1` archive. Existing bytes are ignored.
 * When the active file rotates or shrinks, unseen bytes are recovered from
 * the archive before the new active file is read.
 */
export class RotatingLogCursor {
  constructor(path) {
    this.path = path;
    this.archivePath = `${path}.1`;
    this.started = false;
    this.activeIdentity = null;
    this.offset = 0;
    this.archiveSignature = null;
    this.pending = "";
    this.checkpointStart = 0;
    this.checkpoint = "";
  }

  async start() {
    const [active, archive] = await Promise.all([
      fileInfo(this.path),
      fileInfo(this.archivePath),
    ]);
    this.started = true;
    this.activeIdentity = identity(active);
    this.offset = active?.size ?? 0;
    if (active) await this.updateCheckpoint(active.size, active);
    this.archiveSignature = archive
      ? `${identity(archive)}:${archive.size}:${archive.mtime}`
      : null;
  }

  async poll() {
    if (!this.started) await this.start();
    const active = await fileInfo(this.path);
    if (!active) return [];

    const activeIdentity = identity(active);
    let text = "";
    const changed = this.activeIdentity !== null && activeIdentity !== this.activeIdentity;
    const shrank = activeIdentity === this.activeIdentity && active.size < this.offset;
    const rewritten = !changed && !shrank && this.activeIdentity !== null &&
      await this.checkpointChanged();

    if (changed || shrank || rewritten) {
      const archive = await this.unseenArchiveTail();
      if (!archive.continuous) {
        throw new Error("the active log changed before its unread tail appeared in shelf.log.1");
      }
      text += archive.text;
      text += await readRange(this.path, 0, active.size, active);
    } else if (this.activeIdentity === null) {
      text += await readRange(this.path, 0, active.size, active);
    } else {
      text += await readRange(this.path, this.offset, active.size, active);
    }

    this.activeIdentity = activeIdentity;
    this.offset = active.size;
    await this.updateCheckpoint(active.size, active);
    return this.lines(text);
  }

  async checkpointChanged() {
    if (!this.checkpoint) return false;
    const expected = await fileInfo(this.path);
    if (!expected || identity(expected) !== this.activeIdentity) return true;
    const current = await readRange(this.path, this.checkpointStart, this.offset, expected);
    return current !== this.checkpoint;
  }

  async updateCheckpoint(size, expectedInfo) {
    this.checkpointStart = Math.max(0, size - 64);
    this.checkpoint = await readRange(this.path, this.checkpointStart, size, expectedInfo);
  }

  async unseenArchiveTail() {
    const archive = await fileInfo(this.archivePath);
    if (!archive) return { text: "", continuous: false };
    const signature = `${identity(archive)}:${archive.size}:${archive.mtime}`;
    if (signature === this.archiveSignature) return { text: "", continuous: false };
    this.archiveSignature = signature;
    if (archive.size < this.offset) return { text: "", continuous: false };
    return {
      text: await readRange(this.archivePath, this.offset, archive.size, archive),
      continuous: true,
    };
  }

  lines(text) {
    const combined = this.pending + text;
    const parts = combined.split("\n");
    this.pending = parts.pop() ?? "";
    return parts;
  }
}

export class MoveLimit {
  constructor(maxMoves, windowSeconds = 0) {
    this.maxMoves = maxMoves;
    this.windowMs = windowSeconds > 0 ? windowSeconds * 1000 : 0;
    this.moves = [];
    this.total = 0;
  }

  record(lines, observedAt = Date.now()) {
    for (const line of lines) {
      if (!line.includes(" move ")) continue;
      this.total += 1;
      const loggedAt = Date.parse(line.split(" ", 1)[0]);
      this.moves.push(Number.isFinite(loggedAt) ? loggedAt : observedAt);
    }
    if (this.windowMs > 0) {
      const cutoff = observedAt - this.windowMs;
      this.moves = this.moves.filter((time) => time >= cutoff);
    }
    return this.count > this.maxMoves;
  }

  get count() {
    return this.windowMs > 0 ? this.moves.length : this.total;
  }
}

function positiveNumber(value, fallback, name, allowZero = false) {
  if (value === undefined) return fallback;
  const number = Number(value);
  if (!Number.isFinite(number) || (allowZero ? number < 0 : number <= 0)) {
    throw new Error(`${name} must be ${allowZero ? "zero or greater" : "greater than zero"}`);
  }
  return number;
}

async function main() {
  const seconds = positiveNumber(process.argv[2], 180, "seconds");
  const maxMoves = positiveNumber(process.argv[3], 15, "max moves");
  const windowSeconds = positiveNumber(process.argv[4], 0, "window seconds", true);
  const logPath = process.env.SHELF_WATCH_LOG ?? `${homedir()}/.shelf/shelf.log`;
  const cursor = new RotatingLogCursor(logPath);
  const limit = new MoveLimit(maxMoves, windowSeconds);
  await cursor.start();
  if (process.env.SHELF_WATCH_READY) {
    await writeFile(process.env.SHELF_WATCH_READY, `${process.pid}\n`, { flag: "wx" });
  }

  let stopping = false;
  let stopSignal = null;
  for (const signal of ["SIGINT", "SIGTERM"]) {
    process.once(signal, () => { stopping = true; stopSignal = signal; });
  }
  const deadline = Date.now() + seconds * 1000;
  const mode = windowSeconds > 0 ? `${maxMoves} moves in ${windowSeconds}s` : `${maxMoves} cumulative moves`;
  console.log(`watching ${logPath} for ${seconds}s; brake above ${mode}`);

  while (!stopping && Date.now() < deadline) {
    let lines;
    try {
      lines = await cursor.poll();
    } catch (error) {
      console.error(`BRAKE: log continuity failed: ${error.message}`);
      stopShelf();
      process.exitCode = 2;
      return;
    }
    if (limit.record(lines)) {
      console.error(`BRAKE: ${limit.count} moves exceeded the limit of ${maxMoves}. Shelf is stopped.`);
      stopShelf();
      process.exitCode = 1;
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  console.log(`moves observed: ${limit.total}${stopping ? " (watch stopped by signal)" : ""}`);
  if (stopSignal) process.exitCode = stopSignal === "SIGINT" ? 130 : 143;
}

function stopShelf() {
  const result = spawnSync("/bin/launchctl", [
    "bootout",
    `gui/${process.getuid()}/com.aaqifz.shelf`,
  ], { stdio: "inherit" });
  if (result.error) console.error(`launchctl failed: ${result.error.message}`);
  else if (result.status !== 0) console.error(`launchctl exited ${result.status}`);
}

const invoked = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (invoked) {
  main().catch((error) => {
    console.error(`BRAKE: ${error.message}`);
    stopShelf();
    process.exitCode = 2;
  });
}
