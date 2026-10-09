import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { Job } from '../contracts.js';
import {
  decodeJob,
  decodeSessionUnavailable,
  encodeJob,
  holdsVault,
  isFinished,
  jobRunnerID,
  jobStateDirectory,
  JobStore,
  LABELS_RECOVERY_NOTE,
  makeJobID,
  MAX_STORED_JOBS,
  newJob,
  newTurn,
  RECOVERY_NOTE,
  recoverInterrupted,
  totalCostUSD,
} from './jobs.js';

const NOW = new Date('2026-10-05T12:00:00Z');
const plan = { operation_id: 'op-1', operation_type: 'ingest', valid: true, changed_paths: ['wiki/a.md'], approval_sha256: 'f'.repeat(64) };
const source = { page: 'wiki/sources/tea.md', title: 'Tea', labels: ['tea'], by: 'ai', source: 'inbox/tea.md', state: 'waiting', removed: true };

/** Every field the core stores, as jobs.json holds it. */
function fullJob(): Record<string, unknown> {
  return {
    id: 'job-1',
    kind: 'labels',
    vaultPath: '/v',
    files: ['inbox/a.md', 'inbox/b.md'],
    sessionID: 'sess-1',
    runnerID: 'codex',
    model: 'opus',
    effort: 'high',
    state: 'awaitingApproval',
    createdAt: '2026-10-01T10:00:00Z',
    updatedAt: '2026-10-01T11:00:00Z',
    turns: [{ id: 'T1', date: '2026-10-01T10:00:00Z', author: 'worker', text: 'done', costUSD: 0.25 }],
    grantedTools: ['Read'],
    changedPaths: ['wiki/a.md'],
    operationID: 'op-1',
    error: 'oops',
    approval: {
      summary: 'Plan',
      questions: ['q?'],
      denials: [{ toolName: 'Bash', input: { command: 'ls' } }],
      skipped: ['inbox/c.md'],
      bundlePath: '/v/.vault-meta/worker/job-1/bundle.json',
      plan,
      planError: 'bad plan',
      sinceApproved: { sources: 'same', content: ['wiki/c.md'], added: ['wiki/d.md'], dropped: ['wiki/e.md'], bookkeeping: ['wiki/log.md'] },
      sources: [source],
      labels: { state: 'confirming', message: 'Suggesting…', done: 1, total: 3, revision: 2 },
      unconfirmed: { bundlePath: '/v/u.json', plan },
      rebuilt: { reason: 'stale', pages: ['wiki/a.md'], labels: 'later' },
      needsRebuild: true,
    },
    actionsFound: { status: 'failed', found: 3, pending: 1, added: 2, byType: { todo: 2 }, error: 'busy', model: 'sonnet' },
    folders: ['inbox/folder'],
    sessionUnavailable: { place: 'batch', reason: 'notFound', message: 'gone', detail: 'd', action: 'approve', text: 't', rules: ['Bash(ls)'], labels: 'later', pages: ['wiki/a.md'], at: '2026-10-01T12:00:00Z' },
    parts: [{ operationID: 'op-0', pages: ['wiki/a.md'], labels: 'later', at: '2026-10-01T09:00:00Z' }],
    pendingPart: {
      reason: 'remaining',
      expected: { 'wiki/a.md': 'aa' },
      excluded: ['wiki/b.md'],
      labels: 'later',
      rest: [{ page: 'wiki/sources/x.md', title: 'X', labels: [], by: 'user' }],
      restExpected: { 'wiki/x.md': 'xx' },
      restFiles: { 'inbox/x.md': 'wiki/sources/x.md' },
      removed: [{ page: 'wiki/sources/y.md', title: 'Y', labels: [], by: 'none' }],
      shown: [{ page: 'wiki/sources/z.md', title: 'Z', labels: ['z'], by: 'ai' }],
      before: { summary: 'Before', questions: [], denials: [], skipped: [] },
      prompt: 'rebuild',
      bundlePath: '/v/p.json',
    },
    approvedChange: { at: '2026-10-01T12:00:00Z', operationID: 'op-1', changes: 5, sources: 1, concepts: 2, entities: 1, otherPages: 1, updated: 3, sourcesApproved: 2 },
    reviewDoneAt: '2026-10-01T13:00:00Z',
    released: { at: '2026-10-01T13:00:00Z', files: ['inbox/a.md'], inVault: ['inbox/b.md'], missing: ['inbox/c.md'], rereadId: 'rr-2', alreadyRereading: true },
    reread: { id: 'rr-1', group: 1, groups: 3, fromJob: 'job-0', instruction: 'read it all' },
    queuedApply: { at: '2026-10-01T12:00:00Z', order: 4, bundlePath: '/v/b.json', labels: 'later', carries: 'later', planSha256: 'f'.repeat(64) },
    refresh: { since: '2026-10-01T12:00:00Z', reason: 'stale', stalePaths: ['wiki/a.md'], approved: true, attempt: 2 },
    recovery: {
      state: 'waiting',
      signature: 'lock',
      attempts: [{ at: '2026-10-01T12:00:00Z', by: 'agent', fix: 'wait_then_retry', result: 'running', costUSD: 0.5, runnerID: 'claude-code', model: 'opus', diagnosis: 'locked', error: 'e' }],
      denialAnswers: 1,
      summary: 'Waiting',
      waitUntil: '2026-10-01T12:05:00Z',
      proposal: 'split_batch',
      groups: [['wiki/a.md'], ['wiki/b.md']],
      approvedSha256: 'f'.repeat(64),
      wake: 'retry',
    },
  };
}

describe('decodeJob / encodeJob', () => {
  test('every stored field round-trips unchanged', () => {
    const raw = fullJob();
    const job = decodeJob(raw, NOW)!;
    assert.deepEqual(encodeJob(job), raw);
  });

  test('id and vaultPath are required; anything else falls back', () => {
    assert.equal(decodeJob('job', NOW), undefined);
    assert.equal(decodeJob({ vaultPath: '/v' }, NOW), undefined);
    assert.equal(decodeJob({ id: 'j' }, NOW), undefined);
    const job = decodeJob({ id: 'j', vaultPath: '/v', state: 'exploded', files: 'x', turns: 'x', model: 3 }, NOW)!;
    assert.equal(job.kind, 'ingest');
    assert.equal(job.model, 'sonnet');
    assert.equal(job.state, 'failed');
    assert.deepEqual(job.files, []);
    assert.deepEqual(job.turns, []);
    assert.deepEqual(job.grantedTools, []);
    assert.deepEqual(job.changedPaths, []);
    assert.match(job.sessionID, /^[0-9a-f-]{36}$/);
    assert.equal(job.createdAt, '2026-10-05T12:00:00Z');
    assert.equal(job.updatedAt, job.createdAt, 'updatedAt falls back to createdAt');
    for (const k of ['runnerID', 'effort', 'approval', 'operationID', 'error', 'actionsFound', 'folders', 'parts', 'pendingPart', 'sessionUnavailable', 'approvedChange', 'reviewDoneAt', 'released', 'reread', 'queuedApply', 'refresh', 'recovery']) {
      assert.equal(k in job, false, k);
    }
  });

  test('a minimal job decodes and encodes to exactly the required keys', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v', sessionID: 's', createdAt: '2026-10-01T10:00:00Z' }, NOW)!;
    const want = {
      id: 'j', kind: 'ingest', vaultPath: '/v', files: [], sessionID: 's', model: 'sonnet', state: 'failed',
      createdAt: '2026-10-01T10:00:00Z', updatedAt: '2026-10-01T10:00:00Z', turns: [], grantedTools: [], changedPaths: [],
    };
    assert.deepEqual(job, want);
    assert.deepEqual(encodeJob(job), want);
  });

  test('encoding over a raw object drops every stale optional key the job no longer has', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v', sessionID: 's', createdAt: '2026-10-01T10:00:00Z' }, NOW)!;
    assert.deepEqual(encodeJob(job, { ...fullJob(), future: 1 }), { ...encodeJob(job), future: 1 });
  });

  test('minimal nested parts encode without empty optionals', () => {
    const job = decodeJob(
      {
        id: 'j',
        vaultPath: '/v',
        actionsFound: { status: 'done' },
        sessionUnavailable: { place: 'batch', reason: 'missing' },
        reread: { id: 'r', group: 1, groups: 2 },
      },
      NOW,
    )!;
    const out = encodeJob(job);
    assert.deepEqual(out.actionsFound, { status: 'done', found: 0, pending: 0, added: 0, byType: {} });
    assert.deepEqual(out.sessionUnavailable, { place: 'batch', reason: 'missing', message: '', detail: '' });
    assert.deepEqual(out.reread, { id: 'r', group: 1, groups: 2 });
  });

  test('null entries in lists are skipped, never a crash', () => {
    assert.equal(decodeJob(null, NOW), undefined);
    const job = decodeJob(
      {
        id: 'j',
        vaultPath: '/v',
        turns: [null],
        parts: [null, { operationID: 'op' }],
        approval: { denials: [null], sources: [null] },
        pendingPart: { reason: 'stale', rest: [null], removed: [{ page: 'p.md' }, { nope: 1 }], expected: 'ab' },
      },
      NOW,
    )!;
    assert.deepEqual(job.turns, []);
    assert.equal(job.parts!.length, 1);
    assert.deepEqual(job.approval!.denials, []);
    assert.deepEqual(job.approval!.sources, []);
    assert.deepEqual(job.pendingPart, { reason: 'stale', expected: {}, excluded: [], labels: 'confirm', rest: [], removed: [{ page: 'p.md', title: 'p', labels: [], by: 'none' }] });
  });

  test('unconfirmed needs both its bundle path and a plan', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', approval: { unconfirmed: { plan } } }, NOW)!.approval!.unconfirmed, undefined);
    assert.deepEqual(decodeJob({ id: 'j', vaultPath: '/v', approval: { unconfirmed: { bundlePath: '/u', plan } } }, NOW)!.approval!.unconfirmed, { bundlePath: '/u', plan });
  });

  test('a plan missing any one of its three ids is dropped', () => {
    for (const k of ['operation_id', 'operation_type', 'approval_sha256']) {
      const p: Record<string, unknown> = { ...plan };
      delete p[k];
      assert.equal(decodeJob({ id: 'j', vaultPath: '/v', approval: { plan: p } }, NOW)!.approval!.plan, undefined, k);
    }
  });

  test('mistyped numbers are not trusted: planSha256, sourcesApproved, byType', () => {
    const at = '2026-10-01T12:00:00Z';
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', queuedApply: { at, order: 1, bundlePath: '/b', planSha256: 5 } }, NOW)!.queuedApply!.planSha256, undefined);
    assert.equal('sourcesApproved' in decodeJob({ id: 'j', vaultPath: '/v', approvedChange: { at, operationID: 'op', sourcesApproved: '3' } }, NOW)!.approvedChange!, false);
    assert.deepEqual(decodeJob({ id: 'j', vaultPath: '/v', actionsFound: { byType: [5] } }, NOW)!.actionsFound!.byType, {});
  });

  test('each known state is kept', () => {
    for (const state of ['running', 'awaitingApproval', 'completed', 'failed', 'rejected', 'cancelled']) {
      assert.equal(decodeJob({ id: 'j', vaultPath: '/v', state }, NOW)!.state, state);
    }
  });

  test('turns: unknown authors are dropped; missing fields take defaults', () => {
    const job = decodeJob(
      { id: 'j', vaultPath: '/v', turns: [{ author: 'robot' }, 'x', { author: 'user' }, { author: 'app', id: 'A', text: 'hi', costUSD: 'x', date: '2026-10-01T10:00:00.5Z' }] },
      NOW,
    )!;
    assert.equal(job.turns.length, 2);
    assert.equal(job.turns[0]!.author, 'user');
    assert.equal(job.turns[0]!.text, '');
    assert.equal(job.turns[0]!.costUSD, 0);
    assert.equal(job.turns[0]!.date, '2026-10-05T12:00:00Z');
    assert.match(job.turns[0]!.id, /^[0-9A-F-]{36}$/);
    assert.deepEqual(job.turns[1], { id: 'A', date: '2026-10-01T10:00:00Z', author: 'app', text: 'hi', costUSD: 0 });
  });

  test('approval: a minimal one gets empty lists; a plan missing a key is dropped; bad parts are dropped', () => {
    const job = decodeJob(
      {
        id: 'j',
        vaultPath: '/v',
        approval: {
          denials: [{ input: {} }, { toolName: 'Read', input: 'x' }, 'x'],
          plan: { operation_id: 'op', operation_type: 'ingest' },
          sources: [{ title: 'no page' }, { page: 'wiki/sources/a-b.md', by: 'robot', state: 'odd', labels: 'x' }],
          labels: { state: 'pondering' },
          unconfirmed: { bundlePath: '/u.json', plan: {} },
          rebuilt: { reason: 'later', pages: [] },
          needsRebuild: 'yes',
          sinceApproved: {},
        },
      },
      NOW,
    )!;
    const a = job.approval!;
    assert.deepEqual(Object.keys(a).sort(), ['denials', 'questions', 'sinceApproved', 'skipped', 'sources', 'summary']);
    assert.equal(a.summary, '');
    assert.deepEqual(a.questions, []);
    assert.deepEqual(a.skipped, []);
    assert.deepEqual(a.denials, [{ toolName: 'Read', input: {} }]);
    assert.equal(a.plan, undefined);
    assert.deepEqual(a.sources, [{ page: 'wiki/sources/a-b.md', title: 'a-b', labels: [], by: 'none' }]);
    assert.equal(a.labels, undefined);
    assert.equal(a.unconfirmed, undefined);
    assert.equal(a.rebuilt, undefined);
    assert.equal(a.needsRebuild, undefined);
    assert.deepEqual(a.sinceApproved, { sources: 'same', content: [], added: [], dropped: [], bookkeeping: [] });
  });

  test('a plan with valid not exactly true is invalid; changed_paths defaults to []', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v', approval: { plan: { operation_id: 'o', operation_type: 't', approval_sha256: 's', valid: 'true' } } }, NOW)!;
    assert.deepEqual(job.approval!.plan, { operation_id: 'o', operation_type: 't', valid: false, changed_paths: [], approval_sha256: 's' });
  });

  test('review labels keep each known state and only numeric counts', () => {
    for (const state of ['suggesting', 'confirming', 'confirmed', 'unconfirmed']) {
      const job = decodeJob({ id: 'j', vaultPath: '/v', approval: { labels: { state, done: '1', total: 2 } } }, NOW)!;
      assert.deepEqual(job.approval!.labels, { state, total: 2 });
    }
  });

  test('rebuilt: each reason is kept; labels other than later mean confirm', () => {
    for (const reason of ['partial', 'remaining', 'stale']) {
      const job = decodeJob({ id: 'j', vaultPath: '/v', approval: { rebuilt: { reason, labels: 'whenever' } } }, NOW)!;
      assert.deepEqual(job.approval!.rebuilt, { reason, pages: [], labels: 'confirm' });
    }
  });

  test('sources keep by user, and the failed and suggesting states', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v', approval: { sources: [{ page: 'p.md', by: 'user', state: 'failed' }, { page: 'q.md', state: 'suggesting', removed: 'yes' }] } }, NOW)!;
    assert.deepEqual(job.approval!.sources, [
      { page: 'p.md', title: 'p', labels: [], by: 'user', state: 'failed' },
      { page: 'q.md', title: 'q', labels: [], by: 'none', state: 'suggesting' },
    ]);
  });

  test('actionsFound: unknown status is done, counts default to 0, non-numeric byType entries dropped', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v', actionsFound: { status: 'weird', byType: { todo: 2, jira: 'x', slack: Number.NaN } } }, NOW)!;
    assert.deepEqual(job.actionsFound, { status: 'done', found: 0, pending: 0, added: 0, byType: { todo: 2 } });
    for (const status of ['finding', 'done', 'failed', 'skipped']) {
      assert.equal(decodeJob({ id: 'j', vaultPath: '/v', actionsFound: { status } }, NOW)!.actionsFound!.status, status);
    }
  });

  test('folders: an empty list stays absent', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', folders: [] }, NOW)!.folders, undefined);
    assert.equal(encodeJob({ ...decodeJob({ id: 'j', vaultPath: '/v' }, NOW)!, folders: [] }).folders, undefined);
  });

  test('parts: entries without an operationID are dropped; an empty result stays absent', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', parts: [{ pages: [] }, 'x'] }, NOW)!.parts, undefined);
    const job = decodeJob({ id: 'j', vaultPath: '/v', parts: [{ operationID: 'op', labels: 'x' }] }, NOW)!;
    assert.deepEqual(job.parts, [{ operationID: 'op', pages: [], labels: 'confirm', at: '' }]);
    assert.equal(encodeJob({ ...job, parts: [] }).parts, undefined);
  });

  test('pendingPart: an unknown reason drops it; minimal fields default', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', pendingPart: { reason: 'other' } }, NOW)!.pendingPart, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', pendingPart: 'x' }, NOW)!.pendingPart, undefined);
    for (const reason of ['partial', 'remaining', 'stale']) {
      const job = decodeJob({ id: 'j', vaultPath: '/v', pendingPart: { reason, expected: { a: 'h', b: 2 }, restExpected: [], restFiles: 'x' } }, NOW)!;
      assert.deepEqual(job.pendingPart, { reason, expected: { a: 'h' }, excluded: [], labels: 'confirm' });
    }
  });

  test('sessionUnavailable: unknown place, reason or action is dropped', () => {
    assert.equal(decodeSessionUnavailable({ place: 'moon', reason: 'notFound' }), undefined);
    assert.equal(decodeSessionUnavailable({ place: 'batch', reason: 'tired' }), undefined);
    assert.equal(decodeSessionUnavailable({ reason: 'notFound' }), undefined);
    assert.equal(decodeSessionUnavailable({ place: 'batch' }), undefined);
    assert.equal(decodeSessionUnavailable(null), undefined);
    assert.deepEqual(decodeSessionUnavailable({ place: 'terminal', reason: 'runnerGone', action: 'dance', labels: 'sometimes' }), { place: 'terminal', reason: 'runnerGone', message: '', detail: '' });
    for (const place of ['batch', 'conversation', 'terminal']) {
      for (const reason of ['notFound', 'missing', 'neverStarted', 'runnerGone']) {
        assert.equal(decodeSessionUnavailable({ place, reason })?.reason, reason);
      }
    }
    for (const action of ['approve', 'reply', 'allow', 'ask', 'resume']) {
      assert.equal(decodeSessionUnavailable({ place: 'batch', reason: 'missing', action })?.action, action);
    }
    assert.equal(decodeSessionUnavailable({ place: 'batch', reason: 'missing', labels: 'confirm' })?.labels, 'confirm');
  });

  test('approvedChange: needs at and a non-empty operationID; counts are whole and never negative', () => {
    const at = '2026-10-01T12:00:00Z';
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', approvedChange: { at, operationID: '' } }, NOW)!.approvedChange, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', approvedChange: { operationID: 'op' } }, NOW)!.approvedChange, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', approvedChange: { at, operationID: 3 } }, NOW)!.approvedChange, undefined);
    const job = decodeJob({ id: 'j', vaultPath: '/v', approvedChange: { at, operationID: 'op', changes: 2.7, sources: -1, concepts: 'x', entities: Number.POSITIVE_INFINITY, sourcesApproved: 0 } }, NOW)!;
    assert.deepEqual(job.approvedChange, { at, operationID: 'op', changes: 2, sources: 0, concepts: 0, entities: 0, otherPages: 0, updated: 0 });
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', approvedChange: { at, operationID: 'op', sourcesApproved: 1.9 } }, NOW)!.approvedChange!.sourcesApproved, 1);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', approvedChange: { at, operationID: 'op', changes: 0 } }, NOW)!.approvedChange!.changes, 0);
  });

  test('released needs its time; lists keep only text; a wrong shape is dropped', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', released: { files: [] } }, NOW)!.released, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', released: 'yes' }, NOW)!.released, undefined);
    assert.deepEqual(decodeJob({ id: 'j', vaultPath: '/v', released: { at: 't', files: ['a', 3], inVault: 'x', alreadyRereading: 'yes' } }, NOW)!.released, { at: 't', files: ['a'], inVault: [], missing: [] });
  });

  test('reviewDoneAt must be a date', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', reviewDoneAt: 'soon' }, NOW)!.reviewDoneAt, undefined);
  });

  test('reread needs an id and numeric group and groups', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', reread: { id: 'r', group: '1', groups: 2 } }, NOW)!.reread, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', reread: { id: 'r', group: 1 } }, NOW)!.reread, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', reread: { group: 1, groups: 2 } }, NOW)!.reread, undefined);
    assert.deepEqual(decodeJob({ id: 'j', vaultPath: '/v', reread: { id: 'r', group: 0, groups: 2 } }, NOW)!.reread, { id: 'r', group: 0, groups: 2 });
  });

  test('queuedApply needs at, order and bundlePath; labels default to confirm; an empty planSha256 is dropped', () => {
    const base = { at: 'a', order: 1, bundlePath: '/b' };
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', queuedApply: { ...base, at: 1 } }, NOW)!.queuedApply, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', queuedApply: { ...base, order: '1' } }, NOW)!.queuedApply, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', queuedApply: { ...base, bundlePath: null } }, NOW)!.queuedApply, undefined);
    assert.deepEqual(decodeJob({ id: 'j', vaultPath: '/v', queuedApply: { ...base, labels: 'x', planSha256: '' } }, NOW)!.queuedApply, { ...base, labels: 'confirm', carries: 'confirm' });
  });

  test('refresh needs since; approved only when true; attempt defaults to 1', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', refresh: { approved: true } }, NOW)!.refresh, undefined);
    assert.deepEqual(decodeJob({ id: 'j', vaultPath: '/v', refresh: { since: 's', approved: 'true', reason: 'other' } }, NOW)!.refresh, { since: 's', reason: 'stale', stalePaths: [], approved: false, attempt: 1 });
  });

  test('recovery: unknown state or signature drops it; attempts default safely', () => {
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { state: 'sleeping', signature: 'lock' } }, NOW)!.recovery, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { state: 'running', signature: 'gremlins' } }, NOW)!.recovery, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { signature: 'lock' } }, NOW)!.recovery, undefined);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { state: 'running' } }, NOW)!.recovery, undefined);
    const job = decodeJob(
      {
        id: 'j',
        vaultPath: '/v',
        recovery: {
          state: 'gaveUp',
          signature: 'denial',
          attempts: [{ at: 'a', fix: 'give_up', by: 'robot', result: 'maybe', costUSD: Number.NaN, model: 3 }, { at: 'a' }, { fix: 'x' }, 'x', { at: 'b', fix: 'f', result: 'fixed' }],
          proposal: 'rebuild',
          groups: [['a', 1], 'x', []],
          wake: 'sometimes',
        },
      },
      NOW,
    )!;
    assert.deepEqual(job.recovery, {
      state: 'gaveUp',
      signature: 'denial',
      attempts: [
        { at: 'a', by: 'rule', fix: 'give_up', result: 'failed', costUSD: 0 },
        { at: 'b', by: 'rule', fix: 'f', result: 'fixed', costUSD: 0 },
      ],
      groups: [['a'], []],
    });
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { state: 'fixed', signature: 'lock', groups: ['x'] } }, NOW)!.recovery!.groups, undefined);
    for (const signature of ['stale-again', 'lock', 'plan-error', 'not-recorded', 'full-read-stop', 'session-gone', 'runner-failed', 'denial']) {
      assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { state: 'running', signature } }, NOW)!.recovery!.signature, signature);
    }
    for (const proposal of ['new_session', 'split_batch', 'discard_stale_part']) {
      assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { state: 'running', signature: 'lock', proposal, wake: 'agent' } }, NOW)!.recovery!.proposal, proposal);
    }
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', recovery: { state: 'running', signature: 'lock', wake: 'agent' } }, NOW)!.recovery!.wake, 'agent');
  });

  test('encodeJob keeps unknown keys from the raw object, replaces known ones, and omits nil optionals', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v' }, NOW)!;
    const out = encodeJob(job, { id: 'old', future: { x: 1 }, runnerID: 'stale', error: 'stale' });
    assert.equal(out.id, 'j');
    assert.deepEqual(out.future, { x: 1 });
    assert.equal('runnerID' in out, false);
    assert.equal('error' in out, false);
  });

  test('encodeJob omits empty optional approval parts', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v', approval: { summary: 's', sources: [{ page: 'p.md' }] } }, NOW)!;
    assert.deepEqual(encodeJob(job).approval, { summary: 's', questions: [], denials: [], skipped: [], sources: [{ page: 'p.md', title: 'p', labels: [], by: 'none' }] });
    const labels = decodeJob({ id: 'j', vaultPath: '/v', approval: { labels: { state: 'confirmed' } } }, NOW)!;
    assert.deepEqual(encodeJob(labels).approval!, { summary: '', questions: [], denials: [], skipped: [], labels: { state: 'confirmed' } });
  });
});

describe('job helpers', () => {
  const job = (o: Partial<Job> = {}): Job => ({ ...newJob({ id: 'j', kind: 'ingest', vaultPath: '/v', files: [], model: 'sonnet', now: NOW }), ...o });

  test('holdsVault / isFinished', () => {
    assert.equal(holdsVault('running'), true);
    assert.equal(holdsVault('awaitingApproval'), true);
    for (const s of ['completed', 'failed', 'rejected', 'cancelled'] as const) {
      assert.equal(holdsVault(s), false);
      assert.equal(isFinished(s), true);
    }
    assert.equal(isFinished('running'), false);
  });

  test('totalCostUSD sums the turns', () => {
    assert.equal(totalCostUSD(job()), 0);
    assert.equal(totalCostUSD(job({ turns: [newTurn('worker', 'a', NOW, 0.5), newTurn('user', 'b', NOW, 0.25)] })), 0.75);
  });

  test('newJob and newTurn', () => {
    const j = job();
    assert.equal(j.state, 'running');
    assert.deepEqual([j.turns, j.grantedTools, j.changedPaths], [[], [], []]);
    assert.equal(j.createdAt, '2026-10-05T12:00:00Z');
    assert.equal(j.updatedAt, j.createdAt);
    assert.match(j.sessionID, /^[0-9a-f-]{36}$/);
    const t = newTurn('app', 'hi', NOW);
    assert.equal(t.costUSD, 0);
    assert.match(t.id, /^[0-9A-F-]{36}$/);
  });

  test('jobStateDirectory and jobRunnerID', () => {
    assert.equal(jobStateDirectory({ vaultPath: '/v', id: 'job-1' }), '/v/.vault-meta/worker/job-1');
    assert.equal(jobRunnerID(job()), 'claude-code');
    assert.equal(jobRunnerID(job({ runnerID: 'codex' })), 'codex');
  });

  test('makeJobID uses local time, zero-padded', () => {
    const id = makeJobID(new Date(2026, 0, 2, 3, 4, 5));
    assert.match(id, /^job-20260102-030405-[0-9a-f]{4}$/);
    // The suffix is lower-case hex (a single id may be all digits, so look at several).
    const suffixes = Array.from({ length: 40 }, () => makeJobID().slice(-4)).join('');
    assert.match(suffixes, /^[0-9a-f]+$/);
    assert.match(suffixes, /[a-f]/);
  });

  test('recoverInterrupted: running jobs wait for the user; a labels job keeps its plan; others untouched', () => {
    const done = job({ state: 'completed' });
    assert.equal(recoverInterrupted(done), done);
    const r = recoverInterrupted(job());
    assert.equal(r.state, 'awaitingApproval');
    assert.deepEqual(r.approval, { summary: RECOVERY_NOTE, questions: [], denials: [], skipped: [] });
    const p = { operation_id: 'o', operation_type: 'labels', valid: true, changed_paths: [], approval_sha256: 's' };
    const labels = recoverInterrupted(job({ kind: 'labels', approval: { summary: 'Add tea', questions: [], denials: [], skipped: [], plan: p } }));
    assert.equal(labels.state, 'awaitingApproval');
    assert.equal(labels.approval!.summary, `${LABELS_RECOVERY_NOTE}\n\nAdd tea`);
    assert.deepEqual(labels.approval!.plan, p);
    // Only a labels job is approved again; any other running job waits for a reply.
    assert.equal(recoverInterrupted(job({ kind: 'ingest', approval: { summary: 'Plan', questions: [], denials: [], skipped: [], plan: p } })).approval!.summary, RECOVERY_NOTE);
    // A labels job without a plan has nothing to approve again.
    assert.equal(recoverInterrupted(job({ kind: 'labels' })).approval!.summary, RECOVERY_NOTE);
  });
});

describe('JobStore', () => {
  let dir: string;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-jobs-'));
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  test('a file that is not a list is set aside and loads as no jobs', () => {
    const file = path.join(dir, 'jobs.json');
    fs.writeFileSync(file, '{"jobs": []}');
    const store = new JobStore(file);
    assert.deepEqual(store.load(NOW), []);
    assert.ok(store.preserved);
    assert.equal(fs.readFileSync(store.preserved!, 'utf8'), '{"jobs": []}');
  });

  test('a missing file is no jobs and no copy', () => {
    const store = new JobStore(path.join(dir, 'jobs.json'));
    assert.deepEqual(store.load(NOW), []);
    assert.equal(store.preserved, undefined);
  });

  test('a fully decodable file makes no copy; save keeps unknown keys per job', () => {
    const file = path.join(dir, 'jobs.json');
    fs.writeFileSync(file, JSON.stringify([{ id: 'a', vaultPath: '/v', state: 'completed', extra: 1 }]));
    const store = new JobStore(file);
    const jobs = store.load(NOW);
    assert.equal(store.preserved, undefined);
    store.save(jobs);
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(saved[0].extra, 1);
    store.save(jobs);
    assert.equal(JSON.parse(fs.readFileSync(file, 'utf8'))[0].extra, 1, 'kept across a second save without a load');
  });

  test('entries it cannot decode are skipped and the file is set aside first', () => {
    const file = path.join(dir, 'jobs.json');
    const text = JSON.stringify([{ id: 'a', vaultPath: '/v', state: 'running' }, { id: 'b' }, 'x']);
    fs.writeFileSync(file, text);
    const store = new JobStore(file);
    const jobs = store.load(NOW);
    assert.deepEqual(jobs.map((j) => [j.id, j.state]), [['a', 'awaitingApproval']]);
    assert.equal(fs.readFileSync(store.preserved!, 'utf8'), text);
  });

  test('load caps the list at MAX_STORED_JOBS', () => {
    const file = path.join(dir, 'jobs.json');
    fs.writeFileSync(file, JSON.stringify(Array.from({ length: MAX_STORED_JOBS + 1 }, (_, i) => ({ id: `j${i}`, vaultPath: '/v', state: 'completed' }))));
    const jobs = new JobStore(file).load(NOW);
    assert.equal(jobs.length, MAX_STORED_JOBS);
    assert.equal(jobs[0]!.id, 'j0');
  });

  test('save caps the list at MAX_STORED_JOBS', () => {
    const store = new JobStore(path.join(dir, 'jobs.json'));
    const many = Array.from({ length: MAX_STORED_JOBS + 2 }, (_, i) => newJob({ id: `j${i}`, kind: 'ingest', vaultPath: '/v', files: [], model: 'm', now: NOW }));
    store.save(many);
    assert.equal(JSON.parse(fs.readFileSync(store.file, 'utf8')).length, MAX_STORED_JOBS);
  });
});
