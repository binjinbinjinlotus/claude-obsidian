import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, afterEach, beforeEach, describe, test } from 'node:test';
import { CoreError, type Collector, type CollectorRun, type CoreEvent, type Settings } from '../contracts.js';
import { createCollectorsService, type CollectorsOptions, type CollectorsService } from './index.js';
import { sha256Text } from './script.js';
import { ledgerFile } from './store.js';

const roots: string[] = [];
after(() => {
  for (const r of roots) fs.rmSync(r, { recursive: true, force: true });
});

interface Env {
  root: string;
  vault: string;
  queue: string;
  inbox: string;
  state: string;
  events: CoreEvent[];
  clock: { now: Date };
  settings: Settings;
  busy: Set<string>;
  svc: CollectorsService;
  make(extra?: Partial<CollectorsOptions>): CollectorsService;
}

function setup(extra: Partial<CollectorsOptions> = {}): Env {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-collectors-')));
  roots.push(root);
  const vault = path.join(root, 'vault');
  const queue = path.join(root, 'queue');
  const inbox = path.join(root, 'Distill Inbox');
  const state = path.join(root, 'state');
  for (const d of [vault, queue, inbox, state]) fs.mkdirSync(d, { recursive: true });
  const settings = { vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, settleSeconds: 600 } as unknown as Settings;
  const events: CoreEvent[] = [];
  const clock = { now: new Date() };
  const busy = new Set<string>();
  const make = (more: Partial<CollectorsOptions> = {}) =>
    createCollectorsService({
      emit: (e) => events.push(e),
      getSettings: () => settings,
      file: path.join(state, 'collectors.json'),
      dir: path.join(state, 'collectors'),
      now: () => clock.now,
      isVaultBusy: (v) => busy.has(v),
      killGraceMs: 300,
      homeDir: root,
      loginPath: async () => process.env.PATH ?? '/usr/bin:/bin',
      tmpDir: root,
      baseEnv: { HOME: root, PATH: process.env.PATH, DISTILL_STATE_DIR: '/secret/should-not-leak' },
      ...extra,
      ...more,
    });
  return { root, vault, queue, inbox, state, events, clock, settings, busy, svc: make(), make };
}

/** A settled file (mtime an hour ago). */
function put(dir: string, name: string, content: string, ageSeconds = 3600): string {
  const p = path.join(dir, name);
  fs.writeFileSync(p, content);
  const t = new Date(Date.now() - ageSeconds * 1000);
  fs.utimesSync(p, t, t);
  return p;
}

async function runAndWait(svc: CollectorsService, id: string): Promise<CollectorRun> {
  await svc.runCollector(id);
  await svc.whenIdle();
  return (await svc.listCollectorRuns(id))[0]!;
}

async function folder(env: Env, afterCollect: 'copy' | 'move' = 'copy'): Promise<Collector> {
  return env.svc.createCollector({ kind: 'folder', folder: { source: env.inbox, afterCollect } });
}

async function rejects(p: Promise<unknown>, code: string): Promise<void> {
  await assert.rejects(p, (err: unknown) => err instanceof CoreError && err.code === code);
}

describe('Folder collector', () => {
  test('copies by default, keeps the original and its mtime, then skips it as already collected', async () => {
    const env = setup();
    const src = put(env.inbox, 'gyokuro.md', 'Gyokuro: shade-grown.');
    const c = await folder(env);
    assert.equal(c.enabled, true);
    assert.deepEqual(c.schedule, { cron: '0 * * * *', preset: 'hourly' });
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success');
    assert.equal(run.counts.copied, 1);
    assert.deepEqual(run.filesAdded, ['gyokuro.md']);
    assert.ok(fs.existsSync(src), 'the original stays');
    const copied = path.join(env.queue, 'gyokuro.md');
    assert.equal(fs.readFileSync(copied, 'utf8'), 'Gyokuro: shade-grown.');
    assert.equal(Math.round(fs.statSync(copied).mtimeMs / 1000), Math.round(fs.statSync(src).mtimeMs / 1000), 'mtime kept: ready at once');

    const again = await runAndWait(env.svc, c.id);
    assert.equal(again.result, 'nothing');
    assert.equal(again.counts.skipped, 1);
    assert.deepEqual(again.files, [], 'an unchanged, already collected file is counted without a line');
    assert.deepEqual(fs.readdirSync(env.queue), ['gyokuro.md']);
    assert.equal((await env.svc.getCollector(c.id))!.status!.collectedCount, 1);
  });

  test('an edited file is collected again; an identical copy under another name is skipped', async () => {
    const env = setup();
    const c = await folder(env);
    put(env.inbox, 'tasting-notes.md', 'Monday notes');
    assert.equal((await runAndWait(env.svc, c.id)).counts.copied, 1);
    put(env.inbox, 'tasting-notes.md', 'Monday notes, edited on Tuesday', 1800);
    put(env.inbox, 'gyokuro copy.md', 'Monday notes', 1800); // same bytes as the first version
    const run = await runAndWait(env.svc, c.id);
    const byName = Object.fromEntries(run.files!.map((f) => [f.name, f]));
    assert.equal(byName['tasting-notes.md']!.outcome, 'copied');
    assert.equal(byName['tasting-notes.md']!.queueName, 'tasting-notes 2.md', 'a name clash never replaces');
    assert.deepEqual(byName['gyokuro copy.md'], { name: 'gyokuro copy.md', outcome: 'skipped', reason: 'already collected', size: 12 });
    assert.equal(fs.readFileSync(path.join(env.queue, 'tasting-notes.md'), 'utf8'), 'Monday notes');
    assert.equal(fs.readFileSync(path.join(env.queue, 'tasting-notes 2.md'), 'utf8'), 'Monday notes, edited on Tuesday');
    const collected = await env.svc.listCollected(c.id);
    assert.equal(collected.length, 2, 'the ledger keeps one entry per collected content');
    assert.equal(collected[0]!.collectorId, c.id);
    assert.ok(!('mtimeMs' in collected[0]!));
    assert.deepEqual((await env.svc.listCollected(c.id, 'TASTING')).length, 2);
    assert.deepEqual((await env.svc.listCollected(c.id, 'sencha')).length, 0);
  });

  test('a folder of many kept originals keeps the run history small', async () => {
    const env = setup();
    const c = await folder(env);
    for (let i = 0; i < 300; i++) put(env.inbox, `note-${String(i).padStart(3, '0')}.md`, `note ${i}`);
    assert.equal((await runAndWait(env.svc, c.id)).counts.copied, 300);
    const runsFile = path.join(env.state, 'collectors', 'runs', `${c.id}.jsonl`);
    const before = fs.statSync(runsFile).size;
    for (let i = 0; i < 5; i++) {
      const run = await runAndWait(env.svc, c.id);
      assert.equal(run.counts.skipped, 300);
      assert.equal(run.files!.length, 0);
    }
    const perRun = (fs.statSync(runsFile).size - before) / 5;
    assert.ok(perRun < 1024, `${perRun} bytes per quiet run`);
  });

  test('two identical files in one run: the second is skipped', async () => {
    const env = setup();
    const c = await folder(env);
    put(env.inbox, 'a.md', 'same', 3600);
    put(env.inbox, 'b.md', 'same', 3000);
    const run = await runAndWait(env.svc, c.id);
    assert.deepEqual(run.files!.map((f) => [f.name, f.outcome]), [['a.md', 'copied'], ['b.md', 'skipped']]);
  });

  test('Forget one / Forget all make the next run collect again; Undo puts entries back', async () => {
    const env = setup();
    const c = await folder(env);
    put(env.inbox, 'a.md', 'alpha');
    put(env.inbox, 'b.md', 'beta');
    await runAndWait(env.svc, c.id);
    const [first] = await env.svc.listCollected(c.id, 'a.md');
    const forgotten = await env.svc.forgetCollected(c.id, first!.sha256);
    assert.equal(forgotten.length, 1);
    assert.equal((await env.svc.getCollector(c.id))!.status!.collectedCount, 1);
    const rerun = await runAndWait(env.svc, c.id);
    assert.deepEqual(rerun.files!.filter((f) => f.outcome === 'copied').map((f) => f.queueName), ['a 2.md']);

    const all = await env.svc.forgetCollected(c.id);
    assert.equal(all.length, 2);
    assert.equal((await env.svc.getCollector(c.id))!.status!.collectedCount, 0);
    assert.equal(await env.svc.restoreCollected(c.id, all), 2, 'Undo');
    assert.equal((await env.svc.listCollected(c.id)).length, 2);
    assert.equal(await env.svc.restoreCollected(c.id, all), 0, 'restore is idempotent');
    assert.equal((await runAndWait(env.svc, c.id)).result, 'nothing');
    await rejects(env.svc.forgetCollected(c.id, 'f'.repeat(64)), 'not_found');
  });

  test('the ledger is per vault and outlives the collector', async () => {
    const env = setup();
    put(env.inbox, 'a.md', 'alpha');
    const c = await folder(env);
    await runAndWait(env.svc, c.id);
    await env.svc.deleteCollector(c.id);
    const again = await folder(env);
    assert.equal((await runAndWait(env.svc, again.id)).result, 'nothing', 'a new collector on the same folder does not take old files');
    assert.ok(fs.existsSync(ledgerFile(path.join(env.state, 'collectors'), env.vault)));
    // Another vault has its own ledger.
    const other = path.join(env.root, 'vault2');
    const otherQueue = path.join(env.root, 'queue2');
    fs.mkdirSync(other);
    fs.mkdirSync(otherQueue);
    env.settings.vaults.push({ path: other, queueDirectory: otherQueue });
    const c2 = await env.svc.createCollector({ kind: 'folder', vaultPath: other, folder: { source: env.inbox } });
    assert.equal((await runAndWait(env.svc, c2.id)).counts.copied, 1);
    assert.deepEqual(fs.readdirSync(otherQueue), ['a.md']);
  });

  test('move takes the file out of the source folder', async () => {
    const env = setup();
    const src = put(env.inbox, 'sencha.md', 'Sencha');
    const c = await folder(env, 'move');
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success');
    assert.equal(run.counts.moved, 1);
    assert.equal(run.counts.copied, 0);
    assert.equal(run.files![0]!.outcome, 'moved');
    assert.ok(!fs.existsSync(src));
    assert.equal(fs.readFileSync(path.join(env.queue, 'sencha.md'), 'utf8'), 'Sencha');
    assert.equal((await env.svc.listCollected(c.id))[0]!.outcome, 'moved');
    // The same content dropped again is still skipped and left where it is.
    const back = put(env.inbox, 'sencha again.md', 'Sencha');
    assert.equal((await runAndWait(env.svc, c.id)).result, 'nothing');
    assert.ok(fs.existsSync(back));
  });

  test('files still changing wait; hidden files, Icon\\r, symlinks and (with Include subfolders off) subfolders are left alone', async () => {
    const env = setup();
    put(env.inbox, 'fresh.md', 'being written', 5); // inside the 600 s settle delay
    put(env.inbox, 'download.pdf.crdownload', 'partial');
    put(env.inbox, '.DS_Store', 'x');
    put(env.inbox, '.hidden.md', 'x');
    put(env.inbox, 'Icon\r', 'x');
    fs.mkdirSync(path.join(env.inbox, 'sub'));
    put(path.join(env.inbox, 'sub'), 'inner.md', 'x');
    fs.symlinkSync(path.join(env.inbox, 'sub', 'inner.md'), path.join(env.inbox, 'link.md'));
    put(env.inbox, 'ready.md', 'settled');
    const c = await env.svc.createCollector({ kind: 'folder', folder: { source: env.inbox, includeSubfolders: false } });
    const run = await runAndWait(env.svc, c.id);
    assert.deepEqual(
      run.files!.map((f) => [f.name, f.outcome, f.reason ?? '']).sort(),
      [
        ['download.pdf.crdownload', 'waiting', 'still downloading'],
        ['fresh.md', 'waiting', 'still changing'],
        ['ready.md', 'copied', ''],
      ],
    );
    assert.equal(run.counts.waiting, 2);
    assert.deepEqual(fs.readdirSync(env.queue), ['ready.md']);
    // Once settled (same rule as batching), a later run picks it up.
    const t = new Date(Date.now() - 3600_000);
    fs.utimesSync(path.join(env.inbox, 'fresh.md'), t, t);
    const later = await runAndWait(env.svc, c.id);
    assert.deepEqual(later.filesAdded, ['fresh.md']);
  });

  test('includeSubfolders: on for new collectors, off for one saved before v5, and validated', async () => {
    const env = setup();
    const c = await folder(env);
    assert.equal(c.folder!.includeSubfolders, true);
    const off = await env.svc.updateCollector(c.id, { folder: { includeSubfolders: false } });
    assert.equal(off.folder!.includeSubfolders, false);
    await rejects(env.svc.updateCollector(c.id, { folder: { includeSubfolders: 'yes' as unknown as boolean } }), 'invalid_request');
    // A collector written before v5 has no field: it keeps leaving subfolders alone.
    const file = path.join(env.state, 'collectors.json');
    const raw = JSON.parse(fs.readFileSync(file, 'utf8')) as { collectors: { folder: Record<string, unknown> }[] };
    delete raw.collectors[0]!.folder.includeSubfolders;
    fs.writeFileSync(file, JSON.stringify(raw));
    const reloaded = env.make();
    const old = (await reloaded.getCollector(c.id))!;
    assert.equal(old.folder!.includeSubfolders, undefined);
    fs.mkdirSync(path.join(env.inbox, 'Trip'));
    put(path.join(env.inbox, 'Trip'), 'a.md', 'a');
    const run = await runAndWait(reloaded, c.id);
    assert.equal(run.result, 'nothing');
    assert.deepEqual(fs.readdirSync(env.queue), []);
  });

  test('a subfolder is one folder item: copied when a file in it is new or changed, skipped when all are collected', async () => {
    const env = setup();
    const trip = path.join(env.inbox, 'Tea trip');
    fs.mkdirSync(path.join(trip, 'notes'), { recursive: true });
    put(trip, 'plan.md', 'Kyoto, then Uji.');
    put(path.join(trip, 'notes'), 'day1.md', 'Uji: gyokuro tasting.');
    put(trip, '.DS_Store', 'x');
    put(trip, 'Shared notes.gdoc', '{"url":"https://docs.google.com/document/d/abcdefghij12345/edit","doc_id":"abcdefghij12345","email":"me@example.com"}');
    put(env.inbox, 'loose.md', 'a loose file');
    const c = await folder(env);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success');
    const line = run.files!.find((f) => f.kind === 'folder')!;
    assert.deepEqual(
      { name: line.name, outcome: line.outcome, queueName: line.queueName, fileCount: line.fileCount, newCount: line.newCount },
      { name: 'Tea trip/', outcome: 'copied', queueName: 'Tea trip', fileCount: 3, newCount: 3 },
    );
    assert.deepEqual(run.filesAdded.sort(), ['Tea trip', 'loose.md']);
    const q = path.join(env.queue, 'Tea trip');
    assert.equal(fs.readFileSync(path.join(q, 'notes', 'day1.md'), 'utf8'), 'Uji: gyokuro tasting.');
    assert.ok(!fs.existsSync(path.join(q, '.DS_Store')), 'hidden files are not copied');
    assert.ok(fs.existsSync(path.join(trip, 'plan.md')), 'copy keeps the originals');
    const manifest = JSON.parse(fs.readFileSync(path.join(q, '.distill-folder.json'), 'utf8')) as { tree: { path: string; kind: string; seenBefore?: boolean }[] };
    assert.deepEqual(manifest.tree.map((t) => [t.path, t.kind, t.seenBefore ?? false]), [
      ['Shared notes.gdoc', 'gdoc', false], ['notes', 'dir', false], ['notes/day1.md', 'file', false], ['plan.md', 'file', false],
    ]);
    // Dedupe stays per file: the ledger has each file, with its path inside the folder.
    const collected = await env.svc.listCollected(c.id);
    assert.deepEqual(collected.map((f) => f.name).sort(), ['Tea trip/Shared notes.gdoc', 'Tea trip/notes/day1.md', 'Tea trip/plan.md', 'loose.md']);
    assert.equal((await env.svc.getCollector(c.id))!.status!.collectedCount, 4, 'nested files count as collected');

    // Nothing new: the folder is skipped, counted without a line.
    const again = await runAndWait(env.svc, c.id);
    assert.equal(again.result, 'nothing');
    assert.equal(again.counts.skipped, 2);
    assert.deepEqual(again.files, []);

    // One file inside changes: the folder is collected again, with only that file, and the
    // manifest marks the others seen before.
    put(path.join(trip, 'notes'), 'day1.md', 'Uji: gyokuro and matcha.');
    const changed = await runAndWait(env.svc, c.id);
    const l2 = changed.files!.find((f) => f.kind === 'folder')!;
    assert.deepEqual([l2.outcome, l2.queueName, l2.newCount, l2.fileCount], ['copied', 'Tea trip 2', 1, 3]);
    const q2 = path.join(env.queue, 'Tea trip 2');
    assert.deepEqual(fs.readdirSync(q2).sort(), ['.distill-folder.json', 'notes']);
    assert.equal(fs.readFileSync(path.join(q2, 'notes', 'day1.md'), 'utf8'), 'Uji: gyokuro and matcha.');
    const m2 = JSON.parse(fs.readFileSync(path.join(q2, '.distill-folder.json'), 'utf8')) as { tree: { path: string; seenBefore?: boolean }[] };
    assert.deepEqual(m2.tree.filter((t) => t.seenBefore).map((t) => t.path), ['Shared notes.gdoc', 'plan.md']);

    // Forget all covers nested files too.
    const forgotten = await env.svc.forgetCollected(c.id);
    assert.equal(forgotten.length, 5);

    // Folder lines survive a core restart (the run history is read back from disk).
    const reloaded = env.make();
    const back = (await reloaded.listCollectorRuns(c.id)).find((r) => r.id === changed.id)!;
    const l3 = back.files!.find((f) => f.name === 'Tea trip/')!;
    assert.deepEqual([l3.kind, l3.fileCount, l3.newCount, l3.queueName], ['folder', 3, 1, 'Tea trip 2']);
  });

  test('subfolders: move takes the whole folder; still changing waits; too big and too deep are skipped', async () => {
    const env = setup();
    const c = await folder(env, 'move');
    const a = path.join(env.inbox, 'A');
    fs.mkdirSync(a);
    put(a, 'one.md', 'one');
    put(env.inbox, 'one copy.md', 'one'); // same bytes as A/one.md; subfolders run first, so this is skipped
    const busy = path.join(env.inbox, 'Busy');
    fs.mkdirSync(busy);
    put(busy, 'old.md', 'old');
    put(busy, 'new.md', 'being written', 5);
    const deep = path.join(env.inbox, 'Deep', '1', '2', '3', '4', '5', '6', '7', '8');
    fs.mkdirSync(deep, { recursive: true });
    put(deep, 'far.md', 'far');
    const big = path.join(env.inbox, 'Big');
    fs.mkdirSync(big);
    for (let i = 0; i < 201; i++) put(big, `f${i}.md`, `file ${i}`);
    const run = await runAndWait(env.svc, c.id);
    const byName = new Map(run.files!.filter((f) => f.kind === 'folder').map((f) => [f.name, f]));
    assert.equal(byName.get('A/')!.outcome, 'moved');
    assert.ok(!fs.existsSync(a), 'move takes the folder out of the source');
    assert.ok(fs.existsSync(path.join(env.queue, 'A', 'one.md')));
    assert.ok(fs.existsSync(path.join(env.queue, 'A', '.distill-folder.json')));
    assert.deepEqual([byName.get('Busy/')!.outcome, byName.get('Busy/')!.reason], ['waiting', 'still changing']);
    assert.deepEqual([byName.get('Deep/')!.outcome, byName.get('Deep/')!.reason], ['skipped', 'too deep']);
    assert.deepEqual([byName.get('Big/')!.outcome, byName.get('Big/')!.reason, byName.get('Big/')!.newCount], ['skipped', 'too big', 201]);
    assert.ok(fs.existsSync(busy) && fs.existsSync(big));
    assert.deepEqual(run.files!.find((f) => f.name === 'one copy.md')?.reason, 'already collected', 'dedupe is vault-wide, across folders');
  });

  test('a top-level .gdoc is collected like a file (it then waits in the queue)', async () => {
    const env = setup();
    put(env.inbox, 'Roadmap.gdoc', '{"url":"https://docs.google.com/document/d/abcdefghij12345/edit"}');
    const c = await folder(env);
    const run = await runAndWait(env.svc, c.id);
    assert.deepEqual(run.filesAdded, ['Roadmap.gdoc']);
  });

  test('errors: source missing, no permission, queue missing, vault removed', async () => {
    const env = setup();
    const c = await folder(env);
    fs.rmSync(env.inbox, { recursive: true });
    let run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'failed');
    assert.equal(run.error!.code, 'sourceMissing');
    assert.equal((await env.svc.getCollector(c.id))!.status!.needsAttention, true);
    await env.svc.createCollectorFolder(c.id, 'source');
    assert.ok(fs.existsSync(env.inbox));

    if (process.getuid?.() !== 0) {
      fs.chmodSync(env.inbox, 0o000);
      try {
        run = await runAndWait(env.svc, c.id);
        assert.equal(run.error!.code, 'noPermission');
      } finally {
        fs.chmodSync(env.inbox, 0o755);
      }
    }

    fs.rmSync(env.queue, { recursive: true });
    put(env.inbox, 'a.md', 'a');
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.error!.code, 'queueMissing');
    assert.ok(fs.existsSync(path.join(env.inbox, 'a.md')));
    await env.svc.createCollectorFolder(c.id, 'queue');
    assert.equal((await runAndWait(env.svc, c.id)).result, 'success');

    env.settings.vaults = [];
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.error!.code, 'vaultMissing');
  });

  test('a file that fails to copy is logged on its line and the run goes on', async () => {
    const env = setup();
    if (process.getuid?.() === 0) return;
    const c = await folder(env);
    const locked = put(env.inbox, 'locked.md', 'secret');
    put(env.inbox, 'open.md', 'fine');
    fs.chmodSync(locked, 0o000);
    try {
      const run = await runAndWait(env.svc, c.id);
      assert.equal(run.result, 'success');
      const byName = Object.fromEntries(run.files!.map((f) => [f.name, f]));
      assert.equal(byName['locked.md']!.outcome, 'error');
      assert.equal(byName['locked.md']!.reason, 'no permission to read it');
      assert.equal(byName['open.md']!.outcome, 'copied');
      assert.equal(run.counts.errors, 1);
    } finally {
      fs.chmodSync(locked, 0o644);
    }
  });

  test('validation: default source under home, created on save; the queue folder is refused; bad vault', async () => {
    const env = setup();
    const c = await env.svc.createCollector({ kind: 'folder' });
    assert.equal(c.folder!.source, path.join(env.root, 'Distill Inbox'));
    assert.equal(c.folder!.afterCollect, 'copy');
    assert.equal(c.vaultPath, env.vault, 'the active vault by default');
    const tilde = await env.svc.createCollector({ kind: 'folder', folder: { source: '~/Elsewhere' } });
    assert.ok(fs.statSync(path.join(env.root, 'Elsewhere')).isDirectory(), 'created on first save');
    assert.equal(tilde.folder!.source, path.join(env.root, 'Elsewhere'));
    await rejects(env.svc.createCollector({ kind: 'folder', folder: { source: env.queue } }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'folder', folder: { source: 'relative' } }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'folder', vaultPath: '/nope' }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'folder', schedule: { cron: '* * *' } }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'folder', schedule: { cron: '0 0 30 2 *' } }), 'invalid_request');
    await rejects(env.svc.updateCollector(c.id, { folder: { afterCollect: 'shred' as 'move' } }), 'invalid_request');
    const moved = await env.svc.updateCollector(c.id, { folder: { afterCollect: 'move' }, name: 'Inbox', schedule: { cron: '*/15 * * * *' } });
    assert.equal(moved.folder!.afterCollect, 'move');
    assert.equal(moved.folder!.source, path.join(env.root, 'Distill Inbox'));
    assert.deepEqual(moved.schedule, { cron: '*/15 * * * *', preset: 'every15' });
    env.settings.vaults = [];
    await rejects(env.svc.createCollector({ kind: 'folder' }), 'no_vault');
  });

  test('a source inside a vault, or a queue folder inside the vault, is refused; a saved one fails visibly (decision 2026-10-04)', async () => {
    const env = setup();
    for (const sub of ['', 'inbox', 'wiki', '.raw/x']) {
      const source = path.join(env.vault, sub);
      fs.mkdirSync(source, { recursive: true });
      await rejects(env.svc.createCollector({ kind: 'folder', folder: { source } }), 'invalid_request');
    }
    const c = await folder(env);
    await rejects(env.svc.updateCollector(c.id, { folder: { source: path.join(env.vault, 'wiki') } }), 'invalid_request');
    put(env.inbox, 'a.md', 'A');

    // The source later falls inside a vault the user added: the run fails, with the reason, and copies nothing.
    env.settings.vaults = [...env.settings.vaults, { path: env.root, queueDirectory: path.join(env.root, 'other-queue') }];
    let run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'failed');
    assert.match(run.error?.message ?? '', /inside the vault/);
    assert.deepEqual(fs.readdirSync(env.queue), []);

    // The vault's queue folder is set to wiki/: nothing is written there.
    env.settings.vaults = [{ path: env.vault, queueDirectory: path.join(env.vault, 'wiki') }];
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'failed');
    assert.match(run.error?.message ?? '', /Queue directory .*wiki is inside the vault/);
    assert.deepEqual(fs.readdirSync(path.join(env.vault, 'wiki')), []);

    // Exactly <vault>/inbox is fine.
    env.settings.vaults = [{ path: env.vault, queueDirectory: path.join(env.vault, 'inbox') }];
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success');
    assert.deepEqual(fs.readdirSync(path.join(env.vault, 'inbox')), ['a.md']);
  });
});

/** An inline zsh script that leaves a marker, writes one file to the queue and prints its arguments and env. */
const SCRIPT = [
  'print -r -- "args:$1|$2"',
  'print -r -- "env:$DISTILL_VAULT|$DISTILL_QUEUE_DIR|${DISTILL_STATE_DIR:-unset}|$DISTILL_COLLECTOR_ID|${DISTILL_RUN_ID:0:4}"',
  'print -r -- "cwd:$PWD"',
  'read -t 1 line && print -r -- "stdin:$line" || print -r -- "stdin:closed"',
  'print -r -- "from the script" > "$2/collected-by-script.md"',
  'print -u2 -- "a warning"',
  'exit 0',
].join('\n');

async function script(env: Env, code = SCRIPT, extra: { timeoutSeconds?: number } = {}): Promise<Collector> {
  return env.svc.createCollector({ kind: 'script', name: 'Pull', script: { source: { inline: code }, interpreter: 'zsh', ...extra } });
}

async function allow(env: Env, c: Collector): Promise<Collector> {
  const fresh = (await env.svc.getCollector(c.id))!;
  return env.svc.allowCollector(c.id, fresh.status!.currentSha256!);
}

describe('Script collector', () => {
  test('Add as "Commands for buttons": created with collects false, and it never collects on its own', async () => {
    const env = setup();
    // As the Mac's Add sheet sends it: with the default schedule (kept, unused while it doesn't collect).
    const c = await env.svc.createCollector({ kind: 'script', name: 'Slack CLI', schedule: { cron: '0 * * * *' }, script: { source: { inline: 'exit 0' }, interpreter: 'zsh', collects: false } });
    assert.equal(c.script!.collects, false);
    assert.equal((await env.svc.getCollector(c.id))!.script!.collects, false, 'kept');
    await assert.rejects(env.svc.runCollector(c.id), /doesn't collect/);
    const plain = await script(env);
    assert.notEqual(plain.script!.collects, false, 'absent = collects, as before');
  });

  test('nothing runs before consent; consent is bound to the sha256; a change asks again', async () => {
    const env = setup();
    const marker = path.join(env.root, 'ran');
    const code = `print ran >> ${marker}\nexit 0`;
    const c = await script(env, code);
    assert.equal(c.enabled, false, 'a new script is saved off');
    assert.equal(c.status!.needsConsent, true);
    assert.equal(c.status!.needsAttention, true);
    assert.equal(c.status!.currentSha256, sha256Text(code));

    let run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'notTrusted');
    assert.equal(run.error!.code, 'notAllowed');
    assert.ok(!fs.existsSync(marker), 'the script never ran');
    await rejects(env.svc.updateCollector(c.id, { enabled: true }), 'invalid_state');
    await rejects(env.svc.allowCollector(c.id, 'f'.repeat(64)), 'invalid_state');

    const allowed = await env.svc.allowCollector(c.id, sha256Text(code));
    assert.equal(allowed.enabled, true, 'Allow and turn on');
    assert.equal(allowed.script!.allowedSha256, sha256Text(code));
    assert.equal(allowed.status!.needsConsent, false);
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'nothing', 'exit 0 and no files');
    assert.equal(fs.readFileSync(marker, 'utf8'), 'ran\n');

    // Editing inline code asks again; the collector stays on but does not run.
    const edited = await env.svc.updateCollector(c.id, { script: { source: { inline: `${code}\n# edited` } } });
    assert.equal(edited.status!.needsConsent, true);
    assert.equal(edited.script!.allowedSha256, sha256Text(code), 'the old hash stays for the consent card');
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'notTrusted');
    assert.equal(run.error!.code, 'scriptChanged');
    assert.equal(fs.readFileSync(marker, 'utf8'), 'ran\n');
    await allow(env, c);
    assert.equal((await runAndWait(env.svc, c.id)).result, 'nothing');
    assert.equal(fs.readFileSync(marker, 'utf8'), 'ran\nran\n');

    // A new interpreter clears consent; revoke turns it off.
    const py = await env.svc.updateCollector(c.id, { script: { interpreter: 'python3' } });
    assert.equal(py.script!.allowedSha256, null);
    await env.svc.updateCollector(c.id, { script: { interpreter: 'zsh' } });
    await allow(env, c);
    const revoked = await env.svc.revokeCollector(c.id);
    assert.equal(revoked.enabled, false);
    assert.equal(revoked.script!.allowedSha256, null);
    assert.equal((await runAndWait(env.svc, c.id)).error!.code, 'notAllowed');
  });

  test('a file source: a change to the file on disk needs consent again; a missing file fails', async () => {
    const env = setup();
    const file = path.join(env.root, 'pull.zsh');
    fs.writeFileSync(file, 'print -r -- "$1" > "$2/from-file.md"\n');
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { file: '~/pull.zsh' }, interpreter: 'zsh' } });
    assert.deepEqual(c.script!.source, { file });
    await allow(env, c);
    let run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success');
    assert.deepEqual(run.filesAdded, ['from-file.md']);
    assert.equal(fs.readFileSync(path.join(env.queue, 'from-file.md'), 'utf8'), `${env.vault}\n`);
    fs.appendFileSync(file, 'touch "$2/sneaky.md"\n');
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'notTrusted');
    assert.equal(run.error!.code, 'scriptChanged');
    assert.ok(!fs.existsSync(path.join(env.queue, 'sneaky.md')));
    fs.rmSync(file);
    const missing = (await env.svc.getCollector(c.id))!;
    assert.equal(missing.status!.currentSha256, null);
    assert.match(missing.status!.scriptProblem!, /doesn't exist/);
    run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'failed');
    assert.equal(run.error!.code, 'scriptMissing');
  });

  test('timeout: SIGTERM, then SIGKILL after the grace period, for the whole process group', async () => {
    const env = setup();
    const pidFile = path.join(env.root, 'bg.pid');
    const c = await script(env, `trap '' TERM\nsleep 30 &\nprint $! > ${pidFile}\nprint started\nwhile true; do sleep 0.1; done`, { timeoutSeconds: 1 });
    await allow(env, c);
    const t0 = Date.now();
    const run = await runAndWait(env.svc, c.id);
    const took = Date.now() - t0;
    assert.equal(run.result, 'timedout');
    assert.match(run.error!.message, /Timed out after 1 s/);
    assert.equal(run.signal, 'SIGKILL');
    assert.ok(took >= 1000 && took < 6000, `took ${took} ms`);
    assert.equal(run.stdoutTail, 'started\n');
    const bg = Number(fs.readFileSync(pidFile, 'utf8'));
    await new Promise((r) => setTimeout(r, 100));
    assert.throws(() => process.kill(bg, 0), /ESRCH/, 'the background child was killed too');
    assert.equal((await env.svc.getCollector(c.id))!.status!.needsAttention, true);
  });

  test('Stop ends a running script; failures keep the exit code and output tails', async () => {
    const env = setup();
    const c = await script(env, 'print -u2 working\nsleep 30');
    await allow(env, c);
    const started = await env.svc.runCollector(c.id);
    assert.equal(started.result, 'running');
    await rejects(env.svc.runCollector(c.id), 'busy');
    await rejects(env.svc.deleteCollector(c.id), 'busy');
    await new Promise((r) => setTimeout(r, 200));
    await env.svc.stopCollector(c.id);
    await env.svc.whenIdle();
    const [run] = await env.svc.listCollectorRuns(c.id);
    assert.equal(run!.result, 'stopped');
    assert.equal(await env.svc.stopCollector(c.id), null, 'idle');

    await env.svc.updateCollector(c.id, { script: { source: { inline: 'print out; print -u2 err; exit 3' } } });
    await allow(env, c);
    const failed = await runAndWait(env.svc, c.id);
    assert.equal(failed.result, 'failed');
    assert.equal(failed.exitCode, 3);
    assert.equal(failed.error!.code, 'scriptFailed');
    assert.equal(failed.stdoutTail, 'out\n');
    assert.equal(failed.stderrTail, 'err\n');
  });

  test('output is bounded to the last 64 KB per stream, and streamed as throttled events', async () => {
    const env = setup();
    const c = await script(env, "repeat 20000 print -r -- '0123456789'\nprint -r -- END");
    await allow(env, c);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'nothing');
    assert.ok(run.stdoutTail!.length <= 64 * 1024);
    assert.ok(run.stdoutTail!.endsWith('END\n'));
    const chunks = env.events.filter((e) => e.type === 'collector.run.output');
    assert.ok(chunks.length >= 1 && chunks.length < 50, `${chunks.length} output events`);
  });

  for (const [interpreter, code] of [
    ['python3', 'import os, sys\nprint("args:" + sys.argv[1] + "|" + sys.argv[2])\nopen(os.path.join(sys.argv[2], "from-python.md"), "w").write(os.environ["DISTILL_VAULT"])\n'],
    ['node', "import fs from 'node:fs';\nimport path from 'node:path';\nconsole.log(`args:${process.argv[2]}|${process.argv[3]}`);\nfs.writeFileSync(path.join(process.argv[3], 'from-node.md'), process.env.DISTILL_VAULT);\n"],
  ] as const) {
    test(`inline ${interpreter}: same argv layout, writes into the queue folder`, async () => {
      const env = setup();
      const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter } });
      await allow(env, c);
      const run = await runAndWait(env.svc, c.id);
      assert.equal(run.result, 'success', JSON.stringify(run));
      assert.equal(run.stdoutTail, `args:${env.vault}|${env.queue}\n`);
      const name = interpreter === 'node' ? 'from-node.md' : 'from-python.md';
      assert.deepEqual(run.filesAdded, [name]);
      assert.equal(fs.readFileSync(path.join(env.queue, name), 'utf8'), env.vault);
    });
  }

  test('a missing interpreter fails the run', async () => {
    const env = setup({ loginPath: async () => path.join(os.tmpdir(), 'no-such-bin') });
    const c = await script(env, 'exit 0');
    await allow(env, c);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'failed');
    assert.equal(run.error!.code, 'interpreterMissing');
  });

  test('validation: timeout 1 s … 1 h, interpreter, empty code', async () => {
    const env = setup();
    await rejects(env.svc.createCollector({ kind: 'script', script: { source: { inline: 'x' }, interpreter: 'zsh', timeoutSeconds: 3601 } }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'script', script: { source: { inline: 'x' }, interpreter: 'zsh', timeoutSeconds: 0 } }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'script', script: { source: { inline: ' ' }, interpreter: 'zsh' } }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'script', script: { source: { inline: 'x' }, interpreter: 'bash' as 'zsh' } }), 'invalid_request');
    await rejects(env.svc.createCollector({ kind: 'script', enabled: true } as never), 'invalid_request');
    const c = await env.svc.createCollector({ kind: 'script', enabled: true, script: { source: { inline: 'x' }, interpreter: 'node' } });
    assert.equal(c.enabled, false, 'saved off even when asked to be on');
    assert.equal(c.script!.timeoutSeconds, 300, '5 minutes by default');
  });
});

describe('Scheduler', () => {
  test('catches up once after missed runs, then follows the schedule', async () => {
    const env = setup();
    env.clock.now = new Date(2026, 9, 4, 8, 0, 30);
    put(env.inbox, 'a.md', 'a');
    const c = await folder(env); // hourly; counts from 8:00:30
    env.svc.tick();
    assert.equal((await env.svc.listCollectorRuns(c.id)).length, 0, 'nothing due yet');
    // The Mac slept from 8:01 to 12:30: four ticks missed → one catch-up run.
    env.clock.now = new Date(2026, 9, 4, 12, 30);
    env.svc.tick();
    env.svc.tick();
    await env.svc.whenIdle();
    let list = await env.svc.listCollectorRuns(c.id);
    assert.equal(list.length, 1);
    assert.equal(list[0]!.trigger, 'catchup');
    assert.equal((await env.svc.getCollector(c.id))!.status!.nextRunAt, new Date(2026, 9, 4, 13, 0).toISOString().replace('.000', ''));
    // On time: a plain scheduled run.
    env.clock.now = new Date(2026, 9, 4, 13, 0, 10);
    env.svc.tick();
    await env.svc.whenIdle();
    list = await env.svc.listCollectorRuns(c.id);
    assert.equal(list.length, 2);
    assert.equal(list[0]!.trigger, 'schedule');
    // A single tick handled late (more than 2 minutes) is also a catch-up.
    env.clock.now = new Date(2026, 9, 4, 14, 10);
    env.svc.tick();
    await env.svc.whenIdle();
    assert.equal((await env.svc.listCollectorRuns(c.id))[0]!.trigger, 'catchup');
  });

  test('catch-up survives a core restart (the last tick is persisted)', async () => {
    const env = setup();
    env.clock.now = new Date(2026, 9, 4, 8, 0, 30);
    const c = await folder(env);
    env.clock.now = new Date(2026, 9, 5, 9, 15);
    const restarted = env.make();
    restarted.start();
    await restarted.whenIdle();
    await restarted.stop();
    const runs = await restarted.listCollectorRuns(c.id);
    assert.equal(runs.length, 1);
    assert.equal(runs[0]!.trigger, 'catchup');
  });

  test('off collectors never run; turning one on does not catch up the time it was off', async () => {
    const env = setup();
    env.clock.now = new Date(2026, 9, 4, 8, 0, 30);
    const c = await folder(env);
    await env.svc.updateCollector(c.id, { enabled: false });
    env.clock.now = new Date(2026, 9, 4, 12, 30);
    env.svc.tick();
    await env.svc.updateCollector(c.id, { enabled: true });
    env.svc.tick();
    await env.svc.whenIdle();
    assert.equal((await env.svc.listCollectorRuns(c.id)).length, 0);
  });

  test('a tick while the previous run is still going is skipped and logged', async () => {
    const env = setup();
    env.clock.now = new Date(2026, 9, 4, 6, 0, 30);
    const c = await script(env, 'sleep 30');
    await allow(env, c);
    await env.svc.updateCollector(c.id, { schedule: { cron: '* * * * *' } });
    env.clock.now = new Date(2026, 9, 4, 6, 1, 5);
    env.svc.tick();
    assert.equal((await env.svc.getCollector(c.id))!.status!.running, true);
    env.clock.now = new Date(2026, 9, 4, 6, 2, 5);
    env.svc.tick();
    const runs = await env.svc.listCollectorRuns(c.id);
    assert.equal(runs[0]!.result, 'skipped');
    assert.match(runs[0]!.skipReason!, /^the 6:01\sAM run was still going$/);
    assert.equal(runs[1]!.result, 'running');
    await env.svc.stopCollector(c.id);
    await env.svc.whenIdle();
  });

  test('a script waiting for consent records "Not run" once, not every tick', async () => {
    const env = setup();
    env.clock.now = new Date(2026, 9, 4, 6, 0, 30);
    const c = await script(env, 'exit 0');
    await allow(env, c);
    await env.svc.updateCollector(c.id, { schedule: { cron: '* * * * *' }, script: { source: { inline: 'exit 1' } } });
    for (let m = 1; m <= 4; m++) {
      env.clock.now = new Date(2026, 9, 4, 6, m, 5);
      env.svc.tick();
      await env.svc.whenIdle();
    }
    const runs = await env.svc.listCollectorRuns(c.id);
    assert.equal(runs.length, 1);
    assert.equal(runs[0]!.error!.code, 'scriptChanged');
  });

  test('at most 2 collectors run at once; the third waits for a slot', async () => {
    const env = setup();
    const cs = [];
    for (let i = 0; i < 3; i++) {
      const c = await script(env, `sleep 0.4\nprint x > "$2/s${i}.md"`);
      await allow(env, c);
      cs.push(c);
    }
    let running = 0;
    let peak = 0;
    env.events.length = 0;
    const svc = env.svc;
    const runs = await Promise.all(cs.map((c) => svc.runCollector(c.id)));
    assert.deepEqual(runs.map((r) => r.result), ['running', 'running', 'queued']);
    assert.equal(runs[2]!.waiting, 'slot');
    await svc.whenIdle();
    for (const e of env.events) {
      if (e.type === 'collector.run.started') peak = Math.max(peak, ++running);
      if (e.type === 'collector.run.finished') running--;
    }
    assert.equal(peak, 2);
    for (const c of cs) assert.equal((await svc.listCollectorRuns(c.id))[0]!.result, 'success');
    assert.deepEqual(fs.readdirSync(env.queue).sort(), ['s0.md', 's1.md', 's2.md']);
  });

  test('scripts never run while a batch applies to the same vault; Folder collectors still do', async () => {
    const env = setup();
    const c = await script(env, 'print x > "$2/s.md"');
    await allow(env, c);
    put(env.inbox, 'a.md', 'a');
    const f = await folder(env);
    env.busy.add(env.vault);
    const queued = await env.svc.runCollector(c.id);
    assert.equal(queued.result, 'queued');
    assert.equal(queued.waiting, 'batch');
    assert.equal((await runAndWaitFolder(env, f.id)).result, 'success');
    assert.ok(!fs.existsSync(path.join(env.queue, 's.md')));
    assert.equal((await env.svc.getCollector(c.id))!.status!.lastRun!.waiting, 'batch');
    env.busy.clear();
    env.svc.pump();
    await env.svc.whenIdle();
    assert.equal((await env.svc.listCollectorRuns(c.id))[0]!.result, 'success');
    assert.ok(fs.existsSync(path.join(env.queue, 's.md')));
  });

  test('Stop on a queued run cancels it', async () => {
    const env = setup();
    const c = await script(env, 'exit 0');
    await allow(env, c);
    env.busy.add(env.vault);
    await env.svc.runCollector(c.id);
    const stopped = await env.svc.stopCollector(c.id);
    assert.equal(stopped!.result, 'stopped');
    await env.svc.whenIdle();
    assert.equal((await env.svc.getCollector(c.id))!.status!.running, false);
  });

  test('stop() ends running scripts and marks running and queued runs interrupted', async () => {
    const env = setup();
    const a = await script(env, 'sleep 30');
    await allow(env, a);
    const b = await script(env, 'exit 0');
    await allow(env, b);
    await env.svc.runCollector(a.id);
    env.busy.add(env.vault); // b waits for the "batch"
    await env.svc.runCollector(b.id);
    await new Promise((r) => setTimeout(r, 100));
    const t0 = Date.now();
    await env.svc.stop();
    assert.ok(Date.now() - t0 < 5000);
    for (const c of [a, b]) {
      const [run] = await env.svc.listCollectorRuns(c.id);
      assert.equal(run!.result, 'failed');
      assert.equal(run!.error!.code, 'interrupted', 'a core shutdown is not the user pressing Stop');
    }
  });
});

async function runAndWaitFolder(env: Env, id: string): Promise<CollectorRun> {
  await env.svc.runCollector(id);
  for (let i = 0; i < 100; i++) {
    const [run] = await env.svc.listCollectorRuns(id);
    if (run && run.result !== 'running' && run.result !== 'queued') return run;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error('folder run did not finish');
}

describe('run history and events', () => {
  test('keeps 30 days or the newest 200 runs, whichever keeps more', async () => {
    const env = setup();
    const c = await folder(env);
    const day = 24 * 3600 * 1000;
    // 250 runs spread over 100 days.
    env.clock.now = new Date(Date.now() - 100 * day);
    for (let i = 0; i < 250; i++) {
      env.clock.now = new Date(env.clock.now.getTime() + 0.4 * day);
      await env.svc.runCollector(c.id);
      await env.svc.whenIdle();
    }
    const runs = await env.svc.listCollectorRuns(c.id);
    assert.equal(runs.length, 200);
    // Now with a fresh burst: everything in the last 30 days stays, even past 200.
    env.clock.now = new Date();
    for (let i = 0; i < 210; i++) {
      env.clock.now = new Date(env.clock.now.getTime() + 60_000);
      await env.svc.runCollector(c.id);
      await env.svc.whenIdle();
    }
    const fresh = await env.svc.listCollectorRuns(c.id);
    assert.ok(fresh.length >= 210 && fresh.length <= 210 + 75, `${fresh.length}`);
    assert.equal((await env.svc.listCollectorRuns(c.id, { limit: 5 })).length, 5);
  });

  test('events: changed, run started, run finished; delete emits deleted', async () => {
    const env = setup();
    const c = await folder(env);
    put(env.inbox, 'a.md', 'a');
    await runAndWait(env.svc, c.id);
    const types = env.events.map((e) => e.type);
    assert.ok(types.includes('collector.changed'));
    const started = env.events.find((e) => e.type === 'collector.run.started');
    const finished = env.events.find((e) => e.type === 'collector.run.finished');
    assert.equal(started && started.type === 'collector.run.started' && started.run.result, 'running');
    assert.equal(finished && finished.type === 'collector.run.finished' && finished.run.result, 'success');
    const changed = env.events.filter((e) => e.type === 'collector.changed').at(-1);
    assert.ok(changed && changed.type === 'collector.changed' && changed.collector.status!.lastRun!.result === 'success');
    assert.equal(changed.collector.status!.lastRun!.files, undefined, 'the summary leaves files out');
    await env.svc.deleteCollector(c.id);
    const del = env.events.at(-1)!;
    assert.ok(del.type === 'collector.changed' && del.deleted === true);
    assert.equal((await env.svc.listCollectors()).length, 0);
    await rejects(env.svc.listCollectorRuns(c.id), 'not_found');
  });
});

describe('user data', () => {
  let env: Env;
  beforeEach(() => {
    env = setup();
  });
  afterEach(async () => {
    await env.svc.stop();
  });

  test('an unreadable collectors.json is set aside, never overwritten', async () => {
    const file = path.join(env.state, 'collectors.json');
    fs.writeFileSync(file, '{ this is not json');
    const svc = env.make();
    assert.deepEqual(await svc.listCollectors(), []);
    await svc.createCollector({ kind: 'folder', folder: { source: env.inbox } });
    const copies = fs.readdirSync(env.state).filter((n) => n.startsWith('collectors.json.unreadable-'));
    assert.equal(copies.length, 1);
    assert.equal(fs.readFileSync(path.join(env.state, copies[0]!), 'utf8'), '{ this is not json');
  });

  test('collectors this build cannot decode, and unknown keys, survive a save', async () => {
    const file = path.join(env.state, 'collectors.json');
    const future = { id: 'col-future', kind: 'webhook', vaultPath: env.vault, url: 'https://example.com' };
    const known = {
      id: 'col-1', kind: 'folder', name: 'Inbox', vaultPath: env.vault, enabled: true,
      schedule: { cron: '0 * * * *', preset: 'hourly', jitter: 5 },
      folder: { source: env.inbox, afterCollect: 'copy', recursive: false },
      createdAt: '2026-10-01T00:00:00Z', updatedAt: '2026-10-01T00:00:00Z', color: 'peach',
    };
    fs.writeFileSync(file, JSON.stringify({ version: 1, collectors: [known, future], extra: { keep: true } }));
    const svc = env.make();
    assert.deepEqual((await svc.listCollectors()).map((c) => c.id), ['col-1']);
    await svc.updateCollector('col-1', { name: 'Renamed' });
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(saved.extra, { keep: true });
    assert.deepEqual(saved.collectors[1], future);
    assert.equal(saved.collectors[0].name, 'Renamed');
    assert.equal(saved.collectors[0].color, 'peach');
    assert.equal(saved.collectors[0].schedule.jitter, 5);
    assert.equal(saved.collectors[0].folder.recursive, false);
    assert.equal(saved.collectors[0].status, undefined, 'status is never stored');
    assert.equal(fs.readdirSync(env.state).filter((n) => n.startsWith('collectors.json.unreadable-')).length, 1);
  });

  test('unreadable lines in the run history and the ledger are kept on rewrite', async () => {
    const c = await folder(env);
    const runsFile = path.join(env.state, 'collectors', 'runs', `${c.id}.jsonl`);
    fs.mkdirSync(path.dirname(runsFile), { recursive: true });
    fs.writeFileSync(runsFile, '{"broken": \n{"id":"run-old","collectorId":"' + c.id + '","result":"running","startedAt":"2026-10-01T00:00:00Z","futureField":1}\n');
    const ledger = ledgerFile(path.join(env.state, 'collectors'), env.vault);
    fs.writeFileSync(ledger, 'not json at all\n');
    put(env.inbox, 'a.md', 'a');
    const svc = env.make();
    await svc.runCollector(c.id);
    await svc.whenIdle();
    const lines = fs.readFileSync(runsFile, 'utf8').split('\n');
    assert.equal(lines[0], '{"broken": ');
    const old = JSON.parse(lines[1]!);
    assert.equal(old.result, 'failed', 'a run left running by a stopped core is closed');
    assert.equal(old.error.code, 'interrupted');
    assert.equal(old.futureField, 1);
    assert.ok(fs.readdirSync(path.dirname(runsFile)).some((n) => n.startsWith(`${c.id}.jsonl.unreadable-`)));
    // The ledger: appended after the bad line, and the bad line survives a Forget rewrite.
    await svc.forgetCollected(c.id);
    assert.equal(fs.readFileSync(ledger, 'utf8'), 'not json at all\n');
    assert.ok(fs.readdirSync(path.dirname(ledger)).some((n) => n.startsWith(path.basename(ledger) + '.unreadable-')));
  });

  test('a torn last ledger line does not swallow the next entry', async () => {
    const c = await folder(env);
    const ledger = ledgerFile(path.join(env.state, 'collectors'), env.vault);
    fs.mkdirSync(path.dirname(ledger), { recursive: true });
    fs.writeFileSync(ledger, '{"sha256":"ab');
    put(env.inbox, 'a.md', 'a');
    const svc = env.make();
    await svc.runCollector(c.id);
    await svc.whenIdle();
    const lines = fs.readFileSync(ledger, 'utf8').split('\n');
    assert.equal(lines[0], '{"sha256":"ab');
    assert.equal(JSON.parse(lines[1]!).name, 'a.md');
    assert.equal((await svc.listCollected(c.id)).length, 1);
  });
});
