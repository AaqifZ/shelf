import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { appendFile, copyFile, mkdtemp, rename, rm, stat, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { MoveLimit, RotatingLogCursor } from "./watch.mjs";

async function fixture(t, active = "historical move ignored\n") {
  const directory = await mkdtemp(join(tmpdir(), "shelf-watch-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const log = join(directory, "shelf.log");
  await writeFile(log, active);
  return { log, cursor: new RotatingLogCursor(log) };
}

test("ignores history and reads appended complete lines", async (t) => {
  const { log, cursor } = await fixture(t);
  await cursor.start();
  assert.deepEqual(await cursor.poll(), []);
  await appendFile(log, "2026-10-26T00:00:01Z move a placed\npartial");
  assert.deepEqual(await cursor.poll(), ["2026-10-26T00:00:01Z move a placed"]);
  await appendFile(log, " line\n");
  assert.deepEqual(await cursor.poll(), ["partial line"]);
});

test("recovers unseen tail through archive rotation", async (t) => {
  const { log, cursor } = await fixture(t, "old\n");
  await cursor.start();
  await appendFile(log, "2026-10-26T00:00:01Z move before rotation\n");
  await copyFile(log, `${log}.1`);
  const replacement = `${log}.new`;
  await writeFile(replacement, "2026-10-26T00:00:02Z move after rotation\n");
  await rename(replacement, log);
  assert.deepEqual(await cursor.poll(), [
    "2026-10-26T00:00:01Z move before rotation",
    "2026-10-26T00:00:02Z move after rotation",
  ]);
});

test("fails closed when the active path rotates between stat and open", async (t) => {
  const { log, cursor } = await fixture(t, "old\n");
  await cursor.start();
  await appendFile(log, "2026-10-26T00:00:01Z move before race\n");
  const oldInfo = await stat(log, { bigint: true });
  const expected = {
    dev: oldInfo.dev.toString(),
    ino: oldInfo.ino.toString(),
    size: Number(oldInfo.size),
    mtime: oldInfo.mtimeNs.toString(),
  };

  const replacement = `${log}.new`;
  await writeFile(replacement, "heartbeat\n");
  await rename(log, `${log}.1`);
  await rename(replacement, log);

  await assert.rejects(
    cursor.updateCheckpoint(expected.size, expected),
    /changed before its expected bytes/,
  );
});

test("recovers unseen tail when the active inode is truncated", async (t) => {
  const { log, cursor } = await fixture(t, "old\n");
  await cursor.start();
  await appendFile(log, "2026-10-26T00:00:01Z move before truncate\n");
  await copyFile(log, `${log}.1`);
  await truncate(log, 0);
  await appendFile(log, "2026-10-26T00:00:02Z move after truncate\n");
  assert.deepEqual(await cursor.poll(), [
    "2026-10-26T00:00:01Z move before truncate",
    "2026-10-26T00:00:02Z move after truncate",
  ]);
});

test("fails closed when truncation has no archive", async (t) => {
  const { log, cursor } = await fixture(t, "old\n");
  await cursor.start();
  await truncate(log, 0);
  await appendFile(log, "replacement content longer than old\n");
  await assert.rejects(cursor.poll(), /unread tail/);
});

test("ignores an archive that existed before the watch", async (t) => {
  const { log, cursor } = await fixture(t, "active history\n");
  await writeFile(`${log}.1`, "archived move history\n");
  await cursor.start();
  assert.deepEqual(await cursor.poll(), []);
});

test("cumulative brake trips only above its limit", () => {
  const limit = new MoveLimit(2);
  assert.equal(limit.record(["t move a", "t move b"], 10), false);
  assert.equal(limit.count, 2);
  assert.equal(limit.record(["t move c"], 20), true);
  assert.equal(limit.total, 3);
});

test("sliding brake drops old moves and keeps total evidence", () => {
  const limit = new MoveLimit(2, 10);
  assert.equal(limit.record(["bad-time move a", "bad-time move b"], 1_000), false);
  assert.equal(limit.record([], 12_000), false);
  assert.equal(limit.count, 0);
  assert.equal(limit.record(["bad-time move c", "bad-time move d", "bad-time move e"], 12_001), true);
  assert.equal(limit.count, 3);
  assert.equal(limit.total, 5);
});

test("a terminated watcher exits nonzero instead of passing early", async (t) => {
  const { log } = await fixture(t, "history\n");
  const child = spawn(process.execPath, [fileURLToPath(new URL("./watch.mjs", import.meta.url)), "30", "15"], {
    env: { ...process.env, SHELF_WATCH_LOG: log },
    stdio: ["ignore", "pipe", "pipe"],
  });
  t.after(() => { if (child.exitCode === null) child.kill("SIGKILL"); });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  let stdout = "";
  let stderr = "";
  let sentSignal = false;
  child.stdout.on("data", (text) => { stdout += text; });
  child.stderr.on("data", (text) => { stderr += text; });
  const exited = once(child, "exit");
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("watcher did not become ready")), 3_000);
    const prematureExit = (code, signal) => {
      clearTimeout(timeout);
      reject(new Error(`watcher exited before ready: code=${code} signal=${signal}\n${stderr}`));
    };
    child.once("exit", prematureExit);
    child.stdout.on("data", () => {
      if (sentSignal || !stdout.includes("watching ")) return;
      sentSignal = true;
      clearTimeout(timeout);
      child.off("exit", prematureExit);
      setTimeout(() => {
        child.kill("SIGTERM");
        resolve();
      }, 50);
    });
  });
  const [code, signal] = await exited;
  assert.equal(signal, null, stderr);
  assert.equal(code, 143, stderr);
  assert.match(stdout, /watch stopped by signal/);
});
