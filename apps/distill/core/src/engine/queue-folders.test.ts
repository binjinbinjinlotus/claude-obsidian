/**
 * v5 queue: folder items, .gdoc pointers, the queue scan (Refresh / window / periodic check).
 * Spec: docs/specs/queue-and-batching.md → "Folders, Google Docs and syncing".
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreEvent, QueueEntry, QueueScanResult, RunRequest, RunResult, RunnerCapability } from '../contracts.js';
import { createRunnerRegistry } from '../runners/registry.js';
import type { ProcessOutput, RunProcessOptions } from '../runners/process.js';
import { statePaths } from '../store/paths.js';
import { decodeSettings, encodeSettings } from '../store/settings.js';
import { createEngine, type Engine } from './index.js';
import { parseGoogleDoc, pendingFiles } from './queue.js';

/** Stub runner: records every request and ends each turn with nothing to do. */
class StubRunner implements AgentRunner {
  readonly id = 'claude-code';
  readonly displayName = 'Stub';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput']);
  readonly requests: RunRequest[] = [];
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    await new Promise((r) => setImmediate(r));
    return { resultText: '', isError: false, costUSD: 0, denials: [], raw: '{}', structured: { status: 'nothing_to_do', summary: 'ok' } };
  }
}

interface Harness {
  vault: string;
  queue: string;
  engine: Engine;
  runner: StubRunner;
  events: CoreEvent[];
  clock: { now: Date };
}

let tmp: string;
let h: Harness | undefined;

function setup(o: { settings?: Record<string, unknown>; tickMs?: number } = {}): Harness {
  const vault = path.join(tmp, 'vault');
  const product = path.join(tmp, 'product');
  const state = path.join(tmp, 'state');
  const queue = path.join(tmp, 'queue');
  for (const d of [path.join(vault, 'inbox'), path.join(product, 'scripts'), queue, state]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '# fake core\n');
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({
      vaults: [{ path: vault, queueDirectory: queue }],
      activeVaultPath: vault,
      productRoot: product,
      settleSeconds: 600,
      autoProcessEnabled: false,
      labeling: { autoLabelQueueFolder: false },
      ...o.settings,
    }),
  );
  const runner = new StubRunner();
  const clock = { now: new Date() };
  const launch = async (_: RunProcessOptions): Promise<ProcessOutput> => ({ status: 1, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0) });
  const engine = createEngine({
    paths: statePaths(state),
    runners: createRunnerRegistry([runner]),
    launch,
    tickMs: o.tickMs ?? 60_000,
    now: () => clock.now,
    trashDir: path.join(tmp, 'Trash'),
  });
  const events: CoreEvent[] = [];
  engine.subscribe((e) => events.push(e));
  h = { vault, queue, engine, runner, events, clock };
  return h;
}

/** Writes a file with an mtime `ageSeconds` ago (default: long settled). */
function put(dir: string, rel: string, content: string, ageSeconds = 3600): string {
  const p = path.join(dir, ...rel.split('/'));
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
  const t = new Date(Date.now() - ageSeconds * 1000);
  fs.utimesSync(p, t, t);
  return p;
}

const byName = (entries: QueueEntry[], name: string) => entries.find((e) => e.name === name);

beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-qfolders-')));
});
afterEach(async () => {
  await h?.engine.stop();
  h = undefined;
  fs.rmSync(tmp, { recursive: true, force: true });
});

describe('the bug: a folder moved into the queue folder by hand', () => {
  test('was invisible (the scanner kept regular files only), and is now one queue item', () => {
    const { queue, engine } = setup();
    // Made elsewhere, then moved in with `mv` (what Finder does): no watcher is involved either way.
    const elsewhere = path.join(tmp, 'Tea tasting trip');
    put(elsewhere, 'notes/day1-uji.md', '# Uji');
    fs.renameSync(elsewhere, path.join(queue, 'Tea tasting trip'));
    // Root cause, kept as a regression marker: the file-only scanner skips directories.
    assert.deepEqual(pendingFiles(queue), []);
    const entries = engine.listQueue();
    assert.equal(entries.length, 1);
    assert.deepEqual([entries[0]!.name, entries[0]!.kind], ['Tea tasting trip', 'folder']);
  });
});

describe('folder items', () => {
  test('counts, size and a read-only tree; hidden files, .DS_Store and symlinks are left out', () => {
    const { queue, engine } = setup();
    const trip = path.join(queue, 'Trip');
    put(trip, 'plan.md', '12345');
    put(trip, 'notes/day1.md', 'abc');
    put(trip, 'notes/photos/a.jpg', 'JPEGDATA');
    put(trip, '.DS_Store', 'finder');
    put(trip, 'notes/.hidden.md', 'x');
    put(trip, 'Shared.gdoc', '{"url":"https://docs.google.com/document/d/abcdefghij12345/edit"}');
    fs.mkdirSync(path.join(trip, 'empty'));
    fs.symlinkSync(path.join(trip, 'plan.md'), path.join(trip, 'link.md'));
    const e = byName(engine.listQueue(), 'Trip')!;
    assert.equal(e.kind, 'folder');
    assert.equal(e.fileCount, 4);
    assert.equal(e.folderCount, 3);
    const gdocSize = fs.statSync(path.join(trip, 'Shared.gdoc')).size;
    assert.equal(e.size, 5 + 3 + 8 + gdocSize);
    assert.deepEqual(e.tree, [
      { path: 'Shared.gdoc', size: gdocSize, kind: 'gdoc' },
      { path: 'empty', size: 0, kind: 'dir' },
      { path: 'notes', size: 11, kind: 'dir' },
      { path: 'notes/day1.md', size: 3, kind: 'file' },
      { path: 'notes/photos', size: 8, kind: 'dir' },
      { path: 'notes/photos/a.jpg', size: 8, kind: 'file' },
      { path: 'plan.md', size: 5, kind: 'file' },
    ]);
    assert.equal(e.treeTruncated, undefined);
    assert.equal(e.problem, undefined);
  });

  test('the wait follows the newest change inside; a batch walks folders again, never from the cache', async () => {
    const { queue, engine, clock } = setup();
    const trip = path.join(queue, 'Trip');
    put(trip, 'old.md', 'old', 3600);
    put(trip, 'deep/newer.md', 'newer', 120); // two minutes ago, settle is 10 minutes
    let e = byName(engine.listQueue(), 'Trip')!;
    assert.equal(e.settled, false);
    const newest = fs.statSync(path.join(trip, 'deep', 'newer.md')).mtimeMs;
    assert.equal(e.modified, new Date(newest).toISOString().replace(/\.\d{3}Z$/, 'Z'));
    assert.equal(e.readyAt, new Date(Math.ceil((newest + 600_000) / 1000) * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z'));
    assert.equal(await engine.processQueue(), null, 'not settled: no batch');

    // Time passes: settled.
    clock.now = new Date(Date.now() + 15 * 60_000);
    e = byName(engine.listQueue(), 'Trip')!;
    assert.equal(e.settled, true);
    // A deep file changes now. The 5-second rescan reuses the cached walk (the top folder's mtime
    // didn't move), so the list still says settled...
    const touched = path.join(trip, 'deep', 'newer.md');
    fs.writeFileSync(touched, 'changed');
    const t = new Date(clock.now.getTime() - 5_000);
    fs.utimesSync(touched, t, t);
    assert.equal(byName(engine.listQueue(), 'Trip')!.settled, true);
    // ...but a batch walks again and sees the change: the folder is not taken.
    assert.equal(await engine.processQueue(), null);
    assert.ok(fs.existsSync(trip));
  });

  test('limits: over 200 files is "too big", deeper than 8 levels "too deep", an empty folder has no files; none is batched', async () => {
    const { queue, engine } = setup();
    for (let i = 0; i < 201; i++) put(path.join(queue, 'Big'), `f${i}.md`, 'x');
    put(path.join(queue, 'Deep'), '1/2/3/4/5/6/7/8/far.md', 'far');
    put(path.join(queue, 'Ok'), '1/2/3/4/5/6/7/near.md', 'near'); // level 8: allowed
    fs.mkdirSync(path.join(queue, 'Empty'));
    put(path.join(queue, 'Empty'), '.DS_Store', 'x');
    const entries = engine.listQueue();
    assert.equal(byName(entries, 'Big')!.problem, 'too big');
    assert.equal(byName(entries, 'Deep')!.problem, 'too deep');
    assert.equal(byName(entries, 'Empty')!.problem, 'empty folder');
    assert.equal(byName(entries, 'Ok')!.problem, undefined);
    const job = (await engine.processQueue({ force: true }))!;
    assert.deepEqual(job.folders, ['inbox/' + batchDay() + '/Ok']);
    for (const name of ['Big', 'Deep', 'Empty']) assert.ok(fs.existsSync(path.join(queue, name)), `${name} stays in the queue`);
  });

  test('the tree is capped at 500 entries', () => {
    const { queue, engine } = setup();
    for (let d = 0; d < 6; d++) for (let i = 0; i < 100; i++) fs.mkdirSync(path.join(queue, 'Wide', `d${d}`, `s${i}`), { recursive: true });
    put(path.join(queue, 'Wide'), 'a.md', 'a');
    const e = byName(engine.listQueue(), 'Wide')!;
    assert.equal(e.tree!.length, 500);
    assert.equal(e.treeTruncated, true);
  });

  test('Remove sends the whole folder to the Trash', async () => {
    const { queue, engine } = setup();
    put(path.join(queue, 'Trip'), 'notes/a.md', 'a');
    assert.deepEqual(await engine.removeQueueEntry(path.join(queue, 'Trip')), []);
    assert.equal(fs.readFileSync(path.join(tmp, 'Trash', 'Trip', 'notes', 'a.md'), 'utf8'), 'a');
  });
});

function batchDay(d = new Date()): string {
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

describe('a folder in a batch', () => {
  test('moves whole to inbox/<date>/; each file is a source; the runner gets the structure as context', async () => {
    const { queue, vault, engine, runner } = setup();
    const trip = path.join(queue, 'Tea tasting trip');
    put(trip, 'notes/day1-uji.md', '# Day 1\nUji.');
    put(trip, 'photos/kettle.jpg', 'J'.repeat(2048));
    put(trip, 'Itinerary.gdoc', '{"url":"https://docs.google.com/document/d/abcdefghij12345/edit","email":"me@example.com"}');
    put(trip, '.DS_Store', 'x');
    put(queue, 'loose.md', '# Loose');
    const job = (await engine.processQueue({ force: true }))!;
    await engine.whenIdle();
    const day = batchDay();
    const rel = `inbox/${day}/Tea tasting trip`;
    assert.deepEqual(job.folders, [rel]);
    assert.deepEqual([...job.files].sort(), ['inbox/loose.md', `${rel}/notes/day1-uji.md`, `${rel}/photos/kettle.jpg`].sort());
    assert.ok(fs.existsSync(path.join(vault, rel, 'notes', 'day1-uji.md')), 'the folder moves whole');
    // ...except its .gdoc pointers: they never enter the vault, and stay queued under the same relative path.
    assert.ok(!fs.existsSync(path.join(vault, rel, 'Itinerary.gdoc')));
    assert.equal(fs.readFileSync(path.join(trip, 'Itinerary.gdoc'), 'utf8').includes('abcdefghij12345'), true);
    assert.deepEqual(fs.readdirSync(queue).sort(), ['Tea tasting trip'], 'no staging folder is left behind');
    const left = byName(engine.listQueue(), 'Tea tasting trip')!;
    assert.deepEqual([left.kind, left.waiting, left.fileCount], ['folder', 'google-drive', 1]);
    assert.equal(await engine.processQueue({ force: true }), null, 'it keeps waiting');
    // The moved folder's manifest records the pointer (path, size, kind), never its contents.
    const manifest = fs.readFileSync(path.join(vault, rel, '.distill-folder.json'), 'utf8');
    assert.match(manifest, /"path": "Itinerary.gdoc"/);
    assert.ok(!manifest.includes('me@example.com') && !manifest.includes('docs.google.com'));

    const prompt = runner.requests[0]!.prompt;
    assert.match(prompt, /Folder source: Tea tasting trip\/ \(3 files, 2 folders, [\d.]+ KB\)/);
    assert.match(prompt, new RegExp(`In inbox/${day}/:`));
    assert.match(prompt, /- Tea tasting trip\/notes\/\n/);
    assert.match(prompt, /- Tea tasting trip\/notes\/day1-uji\.md \(\d+ B\)/);
    assert.match(prompt, /- Tea tasting trip\/photos\/kettle\.jpg \(2 KB\)/);
    assert.match(prompt, /- Tea tasting trip\/Itinerary\.gdoc \(Google Doc, not read\)/);
    assert.match(prompt, /Treat these as one source; the paths and names are context\./);
    assert.ok(!prompt.includes(queue), 'no queue-folder path reaches the runner');
    assert.ok(!prompt.includes('me@example.com') && !prompt.includes('.DS_Store'));
    // The batch counts the folder as one source.
    const progress = h!.events.filter((e) => e.type === 'progress').map((e) => (e as { progress: { message: string } }).progress.message);
    assert.ok(progress.includes('Reading 2 sources into vault'), progress.join(' | '));
    // job.folders is stored (jobs.json), so History survives a restart.
    const stored = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'jobs.json'), 'utf8')) as { id: string; folders?: string[] }[];
    assert.deepEqual(stored.find((j) => j.id === job.id)?.folders, [rel]);
  });

  test('a nested .gdoc stays queued at its relative path; the tree in the prompt still lists it', async () => {
    const { queue, vault, engine, runner } = setup();
    put(path.join(queue, 'Trip'), 'a.md', '# A');
    put(path.join(queue, 'Trip'), 'docs/deep/Plan.gdoc', '{"doc_id":"abcdefghij12345","email":"me@example.com"}');
    const job = (await engine.processQueue({ force: true }))!;
    await engine.whenIdle();
    assert.ok(fs.existsSync(path.join(queue, 'Trip', 'docs', 'deep', 'Plan.gdoc')));
    assert.ok(!fs.existsSync(path.join(vault, job.folders![0]!, 'docs')), 'nothing of it in the vault');
    const prompt = runner.requests[0]!.prompt;
    assert.match(prompt, /- Trip\/docs\/deep\/Plan\.gdoc \(Google Doc, not read\)/);
    assert.ok(!prompt.includes('me@example.com') && !prompt.includes('abcdefghij12345'));
    assert.equal(byName(engine.listQueue(), 'Trip')!.waiting, 'google-drive');
  });

  test('inbox/ is create-only: files and folders already there are never written (decision 2026-10-04)', async () => {
    const { queue, vault, engine } = setup();
    const day = batchDay();
    // The user's own files already in the inbox, with names the batch will want.
    const ownFile = put(path.join(vault, 'inbox'), 'loose.md', 'mine');
    const ownFolder = path.join(vault, 'inbox', day, 'Trip');
    put(ownFolder, 'a.md', 'my a');
    put(ownFolder, '.distill-folder.json', '{"version":1,"name":"Trip","tree":[]}');
    const before = (p: string) => [fs.readFileSync(p, 'utf8'), fs.statSync(p).mtimeMs];
    const snap = [ownFile, path.join(ownFolder, 'a.md'), path.join(ownFolder, '.distill-folder.json')].map(before);
    put(queue, 'loose.md', 'queued');
    put(path.join(queue, 'Trip'), 'a.md', 'queued a');
    put(path.join(queue, 'Trip'), 'Plan.gdoc', '{"doc_id":"abcdefghij12345"}');
    const job = (await engine.processQueue({ force: true }))!;
    await engine.whenIdle();
    assert.deepEqual([ownFile, path.join(ownFolder, 'a.md'), path.join(ownFolder, '.distill-folder.json')].map(before), snap);
    assert.deepEqual(job.folders, [`inbox/${day}/Trip 2`]);
    assert.ok(job.files.includes('inbox/loose 2.md'));
    assert.equal(fs.readFileSync(path.join(vault, 'inbox', 'loose 2.md'), 'utf8'), 'queued');
    // The pointer was recorded before the move (inside the queue folder), so the moved folder has it.
    assert.match(fs.readFileSync(path.join(vault, 'inbox', day, 'Trip 2', '.distill-folder.json'), 'utf8'), /"path": "Plan.gdoc"/);
    assert.ok(fs.existsSync(path.join(queue, 'Trip', 'Plan.gdoc')), 'the pointer stays queued');
  });

  test('when the queue is the inbox, a folder is batched in place and then counts as taken', async () => {
    const vault = path.join(tmp, 'vault');
    const { engine, runner } = setup({ settings: { vaults: [{ path: vault, queueDirectory: path.join(vault, 'inbox') }] } });
    put(path.join(vault, 'inbox', 'Trip'), 'notes/a.md', '# A');
    assert.equal(byName(engine.listQueue(), 'Trip')!.kind, 'folder');
    const job = (await engine.processQueue({ force: true }))!;
    await engine.whenIdle();
    assert.deepEqual(job.folders, ['inbox/Trip']);
    assert.deepEqual(job.files, ['inbox/Trip/notes/a.md']);
    assert.ok(fs.existsSync(path.join(vault, 'inbox', 'Trip', 'notes', 'a.md')), 'stays in place');
    assert.match(runner.requests[0]!.prompt, /In inbox\/:\nFolder source: Trip\//);
    assert.equal(byName(engine.listQueue(), 'Trip'), undefined, 'taken: no longer in the queue');
    assert.equal(await engine.processQueue({ force: true }), null);
  });

  test('a collector manifest: files seen before are listed but are not sources', async () => {
    const { queue, engine, runner } = setup();
    const a = path.join(queue, 'A');
    put(a, 'new.md', 'new');
    put(a, 'kept.md', 'kept'); // move mode: present but collected before
    fs.writeFileSync(
      path.join(a, '.distill-folder.json'),
      JSON.stringify({ version: 1, name: 'A', tree: [
        { path: 'kept.md', size: 4, kind: 'file', seenBefore: true },
        { path: 'gone/old.md', size: 3, kind: 'file', seenBefore: true }, // copy mode: left out
        { path: 'new.md', size: 3, kind: 'file' },
      ] }),
    );
    const e = byName(engine.listQueue(), 'A')!;
    assert.deepEqual(e.tree, [
      { path: 'gone', size: 3, kind: 'dir' },
      { path: 'gone/old.md', size: 3, kind: 'file', seenBefore: true },
      { path: 'kept.md', size: 4, kind: 'file', seenBefore: true },
      { path: 'new.md', size: 3, kind: 'file' },
    ]);
    const job = (await engine.processQueue({ force: true }))!;
    await engine.whenIdle();
    assert.deepEqual(job.files, [`inbox/${batchDay()}/A/new.md`]);
    assert.match(runner.requests[0]!.prompt, /- A\/kept\.md \(4 B, seen before, not a source\)/);
  });
});

describe('.gdoc pointers', () => {
  test('parsing: url, doc_id only, malformed JSON, wrong host, no link', () => {
    assert.deepEqual(parseGoogleDoc('{"url":"https://docs.google.com/document/d/abcdefghij12345/edit?usp=drive_fs","doc_id":"abcdefghij12345","email":"me@example.com"}', 'Plan.gdoc'), {
      title: 'Plan', url: 'https://docs.google.com/document/d/abcdefghij12345/edit?usp=drive_fs', docId: 'abcdefghij12345',
    });
    assert.deepEqual(parseGoogleDoc('{"doc_id":"abcdefghij12345"}', 'Notes.gdoc'), {
      title: 'Notes', url: 'https://docs.google.com/document/d/abcdefghij12345/edit', docId: 'abcdefghij12345',
    });
    for (const bad of ['', 'not json', '[]', 'null', '{"url":"http://docs.google.com/document/d/abcdefghij12345"}', '{"url":"https://evil.example/d/abcdefghij12345"}', '{"doc_id":"short"}', '{"doc_id":"../../etc"}', '{"email":"me@example.com"}']) {
      assert.deepEqual(parseGoogleDoc(bad, 'X.gdoc'), { problem: 'no link inside' }, bad);
    }
  });

  test('a Google Doc item waits ("google-drive"), is never batched, and never carries the email', async () => {
    const { queue, engine } = setup({ settings: { settleSeconds: 0 } });
    put(queue, 'Roadmap.gdoc', '{"url":"https://docs.google.com/document/d/abcdefghij12345/edit","doc_id":"abcdefghij12345","email":"me@example.com"}');
    put(queue, 'Broken.gdoc', '{"email":"me@example.com"}');
    const entries = engine.listQueue();
    const doc = byName(entries, 'Roadmap.gdoc')!;
    assert.equal(doc.kind, 'gdoc');
    assert.deepEqual(doc.gdoc, { title: 'Roadmap', url: 'https://docs.google.com/document/d/abcdefghij12345/edit', docId: 'abcdefghij12345' });
    assert.equal(doc.waiting, 'google-drive');
    assert.equal(doc.problem, undefined);
    const broken = byName(entries, 'Broken.gdoc')!;
    assert.equal(broken.kind, 'gdoc', 'still a Google Doc row ("Google Doc · no link inside")');
    assert.equal(broken.gdoc, undefined);
    assert.equal(broken.problem, 'no link inside');
    assert.equal(broken.waiting, undefined);
    assert.ok(!JSON.stringify(entries).includes('me@example.com'));
    assert.equal(await engine.processQueue({ force: true }), null, 'Process now does not take them');
    assert.equal(engine.listQueue().length, 2);
  });

  test('a folder holding only .gdoc files waits too', () => {
    const { queue, engine } = setup();
    put(path.join(queue, 'Docs'), 'a.gdoc', '{"doc_id":"abcdefghij12345"}');
    const e = byName(engine.listQueue(), 'Docs')!;
    assert.equal(e.waiting, 'google-drive');
    assert.equal(e.problem, undefined);
  });
});

describe('queue scan', () => {
  const scans = (events: CoreEvent[]) =>
    events.filter((e): e is { type: 'queue.scanned'; result: QueueScanResult } => e.type === 'queue.scanned').map((e) => e.result);

  test('reports added, removed and changed, including changes deep inside a folder', async () => {
    const { queue, engine, events } = setup();
    put(queue, 'gone.md', 'bye');
    put(path.join(queue, 'Trip'), 'deep/a.md', 'a');
    engine.listQueue();

    fs.writeFileSync(path.join(queue, 'Trip', 'deep', 'a.md'), 'a, edited'); // the top folder's mtime doesn't move
    // The 5-second rescan reuses the cached folder walk...
    assert.equal(byName(engine.listQueue(), 'Trip')!.size, 1);
    // ...and a scan walks again. (It compares with the list the core last had.)
    put(queue, 'new.md', 'hi');
    fs.rmSync(path.join(queue, 'gone.md')); // removed by hand
    const r = await engine.scanQueue();
    assert.deepEqual([r.added, r.removed, r.changed, r.trigger], [1, 1, 1, 'manual']);
    assert.deepEqual(r.addedEntries.map((e) => e.name), ['new.md']);
    assert.deepEqual(r.removedEntries.map((e) => e.name), ['gone.md']);
    assert.deepEqual(r.changedEntries.map((e) => [e.name, e.size]), [['Trip', 9]]);
    assert.deepEqual(r.entries.map((e) => e.name).sort(), ['Trip', 'new.md']);
    assert.equal(r.problem, undefined);
    assert.deepEqual(scans(events).map((s) => s.trigger), ['manual']);
    assert.ok((await engine.status()).lastQueueScanAt);

    // Nothing changed: counts are zero, no queue event, but the scan is still reported.
    const queueEventsBefore = events.filter((e) => e.type === 'queue').length;
    const again = await engine.scanQueue({ trigger: 'window' });
    assert.deepEqual([again.added, again.removed, again.changed, again.trigger], [0, 0, 0, 'window']);
    assert.equal(events.filter((e) => e.type === 'queue').length, queueEventsBefore);
    assert.equal(scans(events).length, 2);
  });

  test('a queue folder that cannot be read is reported', async () => {
    const { queue, engine } = setup();
    fs.chmodSync(queue, 0o000);
    try {
      const r = await engine.scanQueue();
      if (process.getuid?.() === 0) return; // root reads anything
      assert.match(r.problem ?? '', /Can't read the queue folder/);
    } finally {
      fs.chmodSync(queue, 0o755);
    }
  });
});

describe('the periodic queue check', () => {
  async function ticks(n = 3): Promise<void> {
    for (let i = 0; i < n; i++) await new Promise((r) => setTimeout(r, 25));
  }

  test('runs every 5 minutes by default, and the setting reschedules it', async () => {
    const { engine, events, clock } = setup({ tickMs: 10 });
    await engine.start();
    const status = await engine.status();
    assert.equal(status.nextQueueScanAt, new Date(clock.now.getTime() + 5 * 60_000).toISOString().replace(/\.\d{3}Z$/, 'Z'));
    await ticks();
    assert.equal(events.filter((e) => e.type === 'queue.scanned').length, 0, 'not due yet');
    clock.now = new Date(clock.now.getTime() + 5 * 60_000 + 1000);
    await ticks();
    const periodic = events.filter((e) => e.type === 'queue.scanned');
    assert.equal(periodic.length, 1, 'one periodic scan, then the next is 5 minutes out');
    assert.equal((periodic[0] as { result: QueueScanResult }).result.trigger, 'periodic');

    await engine.updateSettings({ queueScanMinutes: 1 });
    clock.now = new Date(clock.now.getTime() + 61_000);
    await ticks();
    assert.equal(events.filter((e) => e.type === 'queue.scanned').length, 2);
  });

  test('Off (0) never scans on its own; Refresh still works', async () => {
    const { engine, events, clock } = setup({ tickMs: 10, settings: { queueScanMinutes: 0 } });
    await engine.start();
    assert.equal((await engine.status()).nextQueueScanAt, null);
    clock.now = new Date(clock.now.getTime() + 24 * 3600_000);
    await ticks();
    assert.equal(events.filter((e) => e.type === 'queue.scanned').length, 0);
    await engine.scanQueue();
    assert.equal(events.filter((e) => e.type === 'queue.scanned').length, 1);
  });

  test('the setting is additive: absent stays absent on save; mistyped falls back; clamped to 0…1440', () => {
    const plain = decodeSettings({});
    assert.equal(plain.queueScanMinutes, undefined);
    assert.equal('queueScanMinutes' in encodeSettings(plain), false);
    assert.equal(decodeSettings({ queueScanMinutes: 'often' }).queueScanMinutes, undefined);
    assert.equal(decodeSettings({ queueScanMinutes: -3 }).queueScanMinutes, 0);
    assert.equal(decodeSettings({ queueScanMinutes: 99999 }).queueScanMinutes, 1440);
    assert.equal(encodeSettings(decodeSettings({ queueScanMinutes: 15 })).queueScanMinutes, 15);
  });
});
