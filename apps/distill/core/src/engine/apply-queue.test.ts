import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type { Job } from '../contracts.js';
import { isBookkeeping, queueOrder, sinceApproved, staleFor } from './apply-queue.js';

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
