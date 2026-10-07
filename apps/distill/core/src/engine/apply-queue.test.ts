import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { Job } from '../contracts.js';
import { isBookkeeping, plainBatchName, queueOrder, queueStatus, sinceApproved, staleFor } from './apply-queue.js';

const sha = (s: string) => createHash('sha256').update(s).digest('hex');

test('staleFor names each expected path whose bytes moved, including must-not-exist', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-queue-'));
  try {
    fs.mkdirSync(path.join(root, 'wiki'), { recursive: true });
    fs.writeFileSync(path.join(root, 'wiki/log.md'), 'log v2');
    fs.writeFileSync(path.join(root, 'wiki/a.md'), 'a');
    fs.writeFileSync(path.join(root, 'wiki/new.md'), 'appeared');
    const bundle = path.join(root, 'bundle.json');
    fs.writeFileSync(bundle, JSON.stringify({ expected_hashes: { 'wiki/log.md': sha('log v1'), 'wiki/a.md': sha('a'), 'wiki/new.md': null, 'wiki/gone.md': sha('x') } }));
    assert.deepEqual(staleFor(root, bundle).map((s) => s.path).sort(), ['wiki/gone.md', 'wiki/log.md', 'wiki/new.md']);
    assert.deepEqual(staleFor(root, path.join(root, 'missing.json')), []);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('sinceApproved sorts what differs: content, added, dropped, bookkeeping; sources are left out', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-since-'));
  try {
    const w = (p: string, content: string) => ({ path: p, content, op: 'replace' });
    fs.writeFileSync(path.join(root, 'a.json'), JSON.stringify({ writes: [w('wiki/sources/s.md', 'S'), w('wiki/concepts/retry.md', 'r1'), w('wiki/concepts/old.md', 'o'), w('wiki/log.md', 'l1')] }));
    fs.writeFileSync(path.join(root, 'b.json'), JSON.stringify({ writes: [w('wiki/sources/s.md', 'S'), w('wiki/concepts/retry.md', 'r2'), w('wiki/entities/auth.md', 'n'), w('wiki/log.md', 'l2'), w('wiki/meta/ledgers/claim-ledger.json', '{}')] }));
    assert.deepEqual(sinceApproved(path.join(root, 'a.json'), path.join(root, 'b.json'), ['wiki/sources/s.md']), {
      sources: 'same', content: ['wiki/concepts/retry.md'], added: ['wiki/entities/auth.md'], dropped: ['wiki/concepts/old.md'],
      bookkeeping: ['wiki/log.md', 'wiki/meta/ledgers/claim-ledger.json'],
    });
    assert.ok(isBookkeeping('wiki/hot.md') && !isBookkeeping('wiki/concepts/hot.md'));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('queueOrder: the vault waiting batches by first approval', () => {
  const job = (id: string, order: number | null, vaultPath = '/v', state: Job['state'] = 'awaitingApproval') =>
    ({ id, vaultPath, state, createdAt: '2026-10-05T00:00:00Z', ...(order === null ? {} : { queuedApply: { at: '', order, bundlePath: '', labels: 'confirm', carries: 'confirm' } }) }) as unknown as Job;
  const list = [job('c', 3), job('a', 1), job('x', 0, '/other'), job('n', null), job('r', 2, '/v', 'running')];
  assert.deepEqual(queueOrder(list, '/v').map((j) => j.id), ['a', 'c']);
});

test('staleFor: an unreadable bundle or one without an object of hashes names nothing; wrong-typed digests are skipped', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-queue-'));
  try {
    fs.writeFileSync(path.join(root, 'a.md'), 'a');
    const write = (v: string) => {
      const p = path.join(root, `b-${Math.random()}.json`);
      fs.writeFileSync(p, v);
      return p;
    };
    assert.deepEqual(staleFor(root, write('{not json')), []);
    assert.deepEqual(staleFor(root, write('null')), []);
    assert.deepEqual(staleFor(root, write('{}')), []);
    assert.deepEqual(staleFor(root, write('{"expected_hashes": "x"}')), []);
    assert.deepEqual(staleFor(root, write('{"expected_hashes": null}')), []);
    // Wrong-typed digests (a number, an object) are not checked; a matching one is fresh; null for a file that exists is stale.
    assert.deepEqual(staleFor(root, write(JSON.stringify({ expected_hashes: { 'a.md': 5, 'b.md': {}, 'c.md': sha('c') } }))), [{ path: 'c.md', expected: sha('c'), current: null }]);
    assert.deepEqual(staleFor(root, write(JSON.stringify({ expected_hashes: { 'a.md': sha('a'), 'none.md': null } }))), []);
    assert.deepEqual(staleFor(root, write(JSON.stringify({ expected_hashes: { 'a.md': null } }))), [{ path: 'a.md', expected: null, current: sha('a') }]);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

const qjob = (id: string, over: Record<string, unknown> = {}) =>
  ({ id, vaultPath: '/v', state: 'awaitingApproval', createdAt: '2026-10-05T00:00:00Z', files: [], ...over }) as unknown as Job;
const queued = (order: number, planSha256?: string) => ({ queuedApply: { at: '', order, bundlePath: '', labels: 'confirm', carries: 'confirm', ...(planSha256 ? { planSha256 } : {}) } });

test('queueOrder: the same order falls back to the oldest batch first', () => {
  const list = [qjob('late', { ...queued(1), createdAt: '2026-10-05T02:00:00Z' }), qjob('early', { ...queued(1), createdAt: '2026-10-05T01:00:00Z' }), qjob('zero', queued(0))];
  assert.deepEqual(queueOrder(list, '/v').map((j) => j.id), ['zero', 'early', 'late']);
});

test('plainBatchName: the first file without folder and extension, +N for the rest, the id when there are none', () => {
  assert.equal(plainBatchName(qjob('j1', { files: ['/q/inbox/Meeting notes.v2.md'] })), 'Meeting notes.v2');
  assert.equal(plainBatchName(qjob('j1', { files: ['/q/a.md', '/q/b.md', '/q/c.md'] })), 'a +2');
  assert.equal(plainBatchName(qjob('j1', { files: ['/q/README'] })), 'README');
  assert.equal(plainBatchName(qjob('j1', { files: [] })), 'j1');
});

test('queueStatus: queued approvals with a plan, numbered per vault head first; recovering batches that are not fixed', () => {
  const jobs = [
    qjob('b', { ...queued(2, 'p'), files: ['/q/b.md'] }),
    qjob('a', { ...queued(1, 'p'), files: ['/q/a.md'] }),
    qjob('noplan', { ...queued(0), files: ['/q/n.md'] }),
    qjob('w', { ...queued(5, 'p'), vaultPath: '/w', files: ['/q/w.md'] }),
    qjob('ran', { ...queued(3, 'p'), state: 'running' }),
    qjob('r1', { state: 'failed', files: ['/q/r1.md'], recovery: { state: 'waiting', signature: 'lock', attempts: [], waitUntil: '2026-10-06T10:00:00Z' } }),
    qjob('r2', { state: 'running', recovery: { state: 'running', signature: 'denial', attempts: [], waitUntil: 'ignored' } }),
    qjob('r3', { recovery: { state: 'gaveUp', signature: 'plan-error', attempts: [] } }),
    qjob('r4', { recovery: { state: 'waiting', signature: 'lock', attempts: [] } }),
    qjob('fixed', { recovery: { state: 'fixed', signature: 'lock', attempts: [] } }),
    qjob('done', { state: 'applied', recovery: { state: 'running', signature: 'lock', attempts: [] } }),
  ];
  const s = queueStatus(jobs);
  assert.deepEqual(s.applyQueue, [
    { id: 'a', name: 'a', vaultPath: '/v', position: 1 },
    { id: 'b', name: 'b', vaultPath: '/v', position: 2 },
    { id: 'w', name: 'w', vaultPath: '/w', position: 1 },
  ]);
  assert.deepEqual(s.recovering, [
    { id: 'r1', name: 'r1', signature: 'lock', state: 'waiting', waitUntil: '2026-10-06T10:00:00Z' },
    { id: 'r2', name: 'r2', signature: 'denial', state: 'running' },
    { id: 'r3', name: 'r3', signature: 'plan-error', state: 'gaveUp' },
    { id: 'r4', name: 'r4', signature: 'lock', state: 'waiting' },
  ]);
  assert.deepEqual(queueStatus([]), { applyQueue: [], recovering: [] });
});

test('isBookkeeping: the four pages exactly, and the ledgers folder', () => {
  for (const p of ['wiki/hot.md', 'wiki/log.md', 'wiki/index.md', 'wiki/overview.md', 'wiki/meta/ledgers/source-ledger.json']) assert.ok(isBookkeeping(p), p);
  for (const p of ['vault/wiki/hot.md', 'wiki/hot.md.bak', 'wiki/hotmd', 'wiki/sub/log.md', 'wiki/meta/ledger.json', 'x/wiki/meta/ledgers/a.json']) assert.ok(!isBookkeeping(p), p);
});

test('sinceApproved: unchanged pages are nowhere; a source the approved bundle had but the rebuild dropped is not "dropped"; unreadable bundles compare as empty', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-since-'));
  try {
    const w = (p: string, content: string) => ({ path: p, content, op: 'replace' });
    fs.writeFileSync(path.join(root, 'a.json'), JSON.stringify({ writes: [w('wiki/sources/s.md', 'S'), w('wiki/sources/t.md', 'T'), w('wiki/c.md', 'same'), w('wiki/hot.md', 'h')] }));
    fs.writeFileSync(path.join(root, 'b.json'), JSON.stringify({ writes: [w('wiki/sources/s.md', 'S2'), w('wiki/c.md', 'same')] }));
    assert.deepEqual(sinceApproved(path.join(root, 'a.json'), path.join(root, 'b.json'), ['wiki/sources/s.md', 'wiki/sources/t.md']), {
      sources: 'same', content: [], added: [], dropped: [], bookkeeping: [],
    });
    assert.deepEqual(sinceApproved(path.join(root, 'a.json'), path.join(root, 'b.json'), []).dropped, ['wiki/sources/t.md'], 'not a source: dropped; a dropped bookkeeping page is not');
    assert.deepEqual(sinceApproved(path.join(root, 'a.json'), path.join(root, 'b.json'), []).content, ['wiki/sources/s.md']);
    assert.deepEqual(sinceApproved(path.join(root, 'missing.json'), path.join(root, 'b.json'), []).added, ['wiki/sources/s.md', 'wiki/c.md']);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
