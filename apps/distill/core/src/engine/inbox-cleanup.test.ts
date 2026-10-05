import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { Job } from '../contracts.js';
import { createCore } from '../index.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { MemorySecretStore } from '../runners/secrets.js';
import { newJob } from '../store/jobs.js';
import { statePaths } from '../store/paths.js';
import { startServer } from '../server/http.js';
import http from 'node:http';
import { finderTrash, previewCleanup, runCleanup, type TrashMover } from './inbox-cleanup.js';

let root: string;
let vault: string;
beforeEach(() => {
  root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-cleanup-')));
  vault = path.join(root, 'Research');
  fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
  fs.mkdirSync(path.join(vault, 'wiki', 'sources'), { recursive: true });
  fs.mkdirSync(path.join(vault, 'wiki', 'meta', 'ledgers'), { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
});
afterEach(() => fs.rmSync(root, { recursive: true, force: true }));

const sha = (text: string) => createHash('sha256').update(text).digest('hex');
let n = 0;
const sources: Record<string, unknown> = {};

function file(rel: string, text: string): void {
  fs.mkdirSync(path.dirname(path.join(vault, rel)), { recursive: true });
  fs.writeFileSync(path.join(vault, rel), text);
}

/** A ledger entry for `locator` with this content, and its page (written unless `noPage`). */
function ledger(locator: string, text: string, o: { noPage?: boolean } = {}): void {
  const page = `wiki/sources/${path.basename(locator, path.extname(locator))}.md`;
  if (!o.noPage) file(page, '# page\n');
  sources[`src-${String(++n).padStart(20, '0')}`] = { origin: { kind: 'file', locator }, content_sha256: sha(text), ingested_at: '2026-10-04', pages: [page] };
  fs.writeFileSync(path.join(vault, 'wiki/meta/ledgers/source-ledger.json'), JSON.stringify({ schema: 'x', sources }));
}

function job(id: string, files: string[], state: Job['state'], folders?: string[]): Job {
  return { ...newJob({ id, kind: 'ingest', vaultPath: vault, files, model: 'sonnet', now: new Date() }), state, ...(folders ? { folders } : {}) };
}

const fakeTrash = () => {
  const moved: string[] = [];
  const mover: TrashMover = async (abs) => {
    for (const a of abs) {
      moved.push(path.relative(vault, a));
      fs.rmSync(a, { recursive: true, force: true });
    }
    return { method: 'rename', failed: [] };
  };
  return { moved, mover };
};

describe('inbox clean-up', () => {
  beforeEach(() => {
    for (const k of Object.keys(sources)) delete sources[k];
  });

  test('only files the ledger says were added, unchanged, with their pages; each other file stays with its reason', () => {
    file('inbox/ok.md', 'ok');
    ledger('inbox/ok.md', 'ok');
    file('inbox/ok.distill.json', JSON.stringify({ title: 'ok', images: [{ file: 'ok image 1.png', mode: 'keep' }] }));
    file('inbox/ok image 1.png', 'png');
    file('inbox/changed.md', 'now different');
    ledger('inbox/changed.md', 'as added');
    file('inbox/nopage.md', 'np');
    ledger('inbox/nopage.md', 'np', { noPage: true });
    file('inbox/new.md', 'never added');
    file('inbox/.gitkeep', '');
    const p = previewCleanup({ vaultPath: vault, jobs: [] });
    assert.deepEqual(p.items.map((i) => [i.path, i.kind, i.members]), [['inbox/ok.md', 'note', ['inbox/ok.distill.json', 'inbox/ok image 1.png']]]);
    assert.equal(p.items[0]!.fileCount, 3);
    assert.deepEqual(p.items[0]!.pages, ['wiki/sources/ok.md']);
    const why = Object.fromEntries(p.stays.map((s) => [s.path, s.reason]));
    assert.deepEqual(why, { 'inbox/changed.md': 'changed', 'inbox/new.md': 'notAdded', 'inbox/nopage.md': 'pageMissing' });
  });

  test('names match in Unicode NFC; a case-only difference counts only with one entry and the same hash', () => {
    const nfd = 'inbox/Café notes.md';
    file(nfd, 'cafe');
    ledger('inbox/Café notes.md', 'cafe');
    file('inbox/Tea.md', 'tea');
    ledger('inbox/tea.md', 'tea');
    file('inbox/Two.md', 'two');
    ledger('inbox/two.md', 'two');
    ledger('inbox/TWO.md', 'two');
    const p = previewCleanup({ vaultPath: vault, jobs: [] });
    const go = p.items.map((i) => i.path.normalize('NFC'));
    assert.ok(go.includes('inbox/Café notes.md'));
    assert.ok(go.includes('inbox/Tea.md'));
    assert.equal(p.stays.find((s) => s.path === 'inbox/Two.md')?.reason, 'notAdded');
  });

  test('never a file a pending batch took or a queued file; a folder goes as one only when every source inside passes', () => {
    file('inbox/held.md', 'held');
    ledger('inbox/held.md', 'held');
    file('inbox/queued.md', 'q');
    ledger('inbox/queued.md', 'q');
    file('inbox/2026-10-04/Trip/a.md', 'a');
    ledger('inbox/2026-10-04/Trip/a.md', 'a');
    file('inbox/2026-10-04/Trip/b.md', 'b');
    ledger('inbox/2026-10-04/Trip/b.md', 'b');
    file('inbox/2026-10-04/Trip/.distill-folder.json', '{}');
    file('inbox/2026-10-04/Half/a2.md', 'a2');
    ledger('inbox/2026-10-04/Half/a2.md', 'a2');
    file('inbox/2026-10-04/Half/b2.md', 'b2');
    const jobs = [
      job('job-1', ['inbox/held.md'], 'awaitingApproval'),
      job('job-2', ['inbox/2026-10-04/Trip/a.md', 'inbox/2026-10-04/Trip/b.md'], 'completed', ['inbox/2026-10-04/Trip']),
      job('job-3', ['inbox/2026-10-04/Half/a2.md', 'inbox/2026-10-04/Half/b2.md'], 'completed', ['inbox/2026-10-04/Half']),
    ];
    const p = previewCleanup({ vaultPath: vault, jobs, queued: new Set(['inbox/queued.md']) });
    assert.deepEqual(p.items.map((i) => [i.path, i.kind, i.fileCount]), [['inbox/2026-10-04/Trip', 'folder', 2]]);
    const why = Object.fromEntries(p.stays.map((s) => [s.path, `${s.reason}${s.detail ? ` (${s.detail})` : ''}`]));
    assert.deepEqual(why, {
      'inbox/held.md': 'inReview',
      'inbox/queued.md': 'inQueue',
      'inbox/2026-10-04/Half': 'notAdded (1 of 2 files not added yet)',
    });
    // One batch's scope: only the files that batch used.
    const scoped = previewCleanup({ vaultPath: vault, jobs, jobId: 'job-2' });
    assert.deepEqual(scoped.items.map((i) => i.path), ['inbox/2026-10-04/Trip']);
    assert.deepEqual(scoped.stays, []);
  });

  test('checked again when moved: a file that changed after the preview stays; the rest go to the Trash', async () => {
    file('inbox/a.md', 'a');
    ledger('inbox/a.md', 'a');
    file('inbox/b.md', 'b');
    ledger('inbox/b.md', 'b');
    const scope = { vaultPath: vault, jobs: [] };
    assert.equal(previewCleanup(scope).items.length, 2);
    file('inbox/b.md', 'b, edited after the preview');
    const t = fakeTrash();
    const r = await runCleanup(scope, ['inbox/a.md', 'inbox/b.md', 'inbox/gone.md'], t.mover);
    assert.deepEqual(t.moved, ['inbox/a.md']);
    assert.deepEqual(r.moved, [{ path: 'inbox/a.md', fileCount: 1 }]);
    assert.deepEqual(r.stayed.map((s) => [s.path, s.reason]), [['inbox/b.md', 'changed'], ['inbox/gone.md', 'notAdded']]);
    assert.ok(fs.existsSync(path.join(vault, 'inbox/b.md')));
  });

  test('Finder is asked first (Put Back works); when it refuses, a rename into the Trash folder', async () => {
    file('inbox/a.md', 'a');
    const trash = path.join(root, 'Trash');
    const calls: string[][] = [];
    const refuse = finderTrash(trash, async (o) => {
      calls.push(o.args);
      return { status: 1, stdout: Buffer.alloc(0), stderr: Buffer.from('not allowed') };
    });
    const r = await refuse([path.join(vault, 'inbox/a.md')]);
    assert.equal(r.method, 'rename');
    assert.equal(calls.length, 1);
    assert.ok(calls[0]!.includes(path.join(vault, 'inbox/a.md')));
    assert.ok(fs.existsSync(path.join(trash, 'a.md')));
    assert.ok(!fs.existsSync(path.join(vault, 'inbox/a.md')));
  });

  test('the core: preview and clean up through the facade, logged in Activity with names and counts', async () => {
    const state = path.join(root, 'state');
    const queue = path.join(root, 'queue');
    fs.mkdirSync(state, { recursive: true });
    fs.mkdirSync(queue, { recursive: true });
    file('inbox/a.md', 'a');
    ledger('inbox/a.md', 'a');
    fs.writeFileSync(path.join(state, 'settings.json'), JSON.stringify({ vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, autoProcessEnabled: false }));
    fs.writeFileSync(path.join(state, 'jobs.json'), JSON.stringify([job('job-20261004-120000-aaaa', ['inbox/a.md'], 'completed')]));
    const t = fakeTrash();
    const core = createCore({ paths: statePaths(state), runners: createRunnerRegistry([]), trashMover: t.mover, tickMs: 60_000, secrets: new MemorySecretStore(), collectors: { homeDir: root, tmpDir: root } });
    const server = await startServer({ core, token: 'tttttttttttttttttttt' });
    const call = (method: string, p: string, body?: unknown) => new Promise<{ status: number; body: any }>((resolve, reject) => {
      const req = http.request({ host: '127.0.0.1', port: server.port, path: p, method, headers: { authorization: 'Bearer tttttttttttttttttttt', 'content-type': 'application/json' } }, (res) => {
        let data = '';
        res.on('data', (c) => (data += c));
        res.on('end', () => resolve({ status: res.statusCode ?? 0, body: JSON.parse(data) }));
      });
      req.on('error', reject);
      req.end(body === undefined ? undefined : JSON.stringify(body));
    });
    try {
      const viaHttp = await call('GET', '/v1/inbox/cleanup?job=job-20261004-120000-aaaa');
      assert.equal(viaHttp.status, 200);
      assert.deepEqual(viaHttp.body.items.map((i: { path: string }) => i.path), ['inbox/a.md']);
      assert.equal((await call('POST', '/v1/inbox/cleanup', { paths: [] })).status, 400);
      // Done is only for an approved batch.
      assert.equal((await call('POST', '/v1/jobs/job-20261004-120000-aaaa/done')).status, 409);
      const p = await core.previewInboxCleanup!({ jobId: 'job-20261004-120000-aaaa' });
      assert.deepEqual(p.items.map((i) => i.path), ['inbox/a.md']);
      const r = await core.cleanUpInbox!({ paths: ['inbox/a.md'], jobId: 'job-20261004-120000-aaaa' });
      assert.deepEqual(r.moved.map((m) => m.path), ['inbox/a.md']);
      await assert.rejects(core.cleanUpInbox!({ paths: ['wiki/sources/a.md'] }), /inside inbox/);
      const page = await core.listActivity({ types: ['queue.inbox_cleaned'] });
      const ok = page.entries.find((e) => e.outcome === 'ok');
      assert.equal(ok?.summary, 'Cleaned up inbox: 1 file to the Trash');
      assert.deepEqual(ok?.details?.moved, ['inbox/a.md']);
      assert.equal(page.entries.find((e) => e.outcome === 'failed')?.summary, "Couldn't clean up inbox");
    } finally {
      await server.close();
      await core.stop();
    }
  });
});
