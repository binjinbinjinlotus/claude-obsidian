/**
 * The activity log and Distill's trash (spec activity-log.md): logging for each mutation
 * family through createCore and the HTTP API, sources, redaction, rotation, concurrency,
 * trash and restore. Temp state dirs only.
 */
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { ActivityEntry, CoreEvent, Job } from '../contracts.js';
import { createCore } from '../index.js';
import { startServer, type RunningServer } from '../server/http.js';
import { statePaths } from '../store/paths.js';
import { newJob } from '../store/jobs.js';
import { asScheduler, runWithSource, sourceFromHeaders } from './context.js';
import { classifiedMethods, createEventLogger } from './instrument.js';
import { ActivityLog } from './log.js';
import { clip, redactDetails, redactText, REDACTED } from './redact.js';
import { Trash } from './trash.js';
import { instrumentCore } from './instrument.js';
import { MemorySecretStore } from '../runners/secrets.js';
import { createFakeCore } from '../server/fake-core.js';

const TOKEN = 'd'.repeat(64);
const here = path.dirname(fileURLToPath(import.meta.url));

function tmp(prefix: string): string {
  return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), prefix)));
}

function readLog(state: string): ActivityEntry[] {
  const dir = path.join(state, 'activity');
  const out: ActivityEntry[] = [];
  for (const name of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
    if (!name.endsWith('.jsonl')) continue;
    for (const line of fs.readFileSync(path.join(dir, name), 'utf8').split('\n')) if (line.trim()) out.push(JSON.parse(line) as ActivityEntry);
  }
  return out.sort((a, b) => a.id.localeCompare(b.id));
}

// ───────────── unit: redaction ─────────────

describe('redaction', () => {
  test('known token shapes and key=value secrets are replaced', () => {
    const samples = [
      'sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789',
      'sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX12345',
      'ghp_abcdefghijklmnopqrstuvwxyz0123456789',
      'xoxb-1234567890-abcdefghij',
      'AKIAABCDEFGHIJKLMNOP',
      'AIzaSyA1234567890abcdefghijklmnopqrstu',
      'ya29.a0AfH6SMBabcdefghijklmnopqrstuvwxyz',
      'ATATT3xFfGF0abcdefghijklmnopqrstuvwxyz',
      'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
      '0123456789abcdef0123456789abcdef0123456789abcdef',
    ];
    for (const s of samples) {
      const out = redactText(`before ${s} after`);
      assert.ok(!out.includes(s), `${s} survived: ${out}`);
      assert.ok(out.includes(REDACTED));
      assert.ok(out.startsWith('before ') && out.endsWith(' after'), out);
    }
    assert.equal(redactText('token=abc123'), `token=${REDACTED}`);
    assert.equal(redactText('API_KEY: "hunter2"'), `API_KEY: "${REDACTED}"`);
    assert.equal(redactText('Authorization: Bearer abcdefgh12345678'), `Authorization: ${REDACTED}`);
    assert.equal(redactText('password=hunter2&x=1'), `password=${REDACTED}&x=1`);
    assert.equal(redactText('https://me:pa55@example.com/x'), `https://${REDACTED}@example.com/x`);
    assert.equal(redactText('-----BEGIN RSA PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----'), REDACTED);
  });

  test('ordinary text, ids and paths are kept', () => {
    for (const s of [
      'Deleted the chat “How hot for sencha?”',
      'col-3f2a9c1e-8d4b-4b2a-9c1e-8d4b4b2a9c1e',
      'job-20261004-190400-ab12',
      '/Users/me/Distill Inbox/notes.md',
      '1791155040000-0001-a1b2c3',
    ]) {
      assert.equal(redactText(s), s);
    }
  });

  // Paths on this Mac (2026-10-04): the Activity screen showed a script as "/[redacted].py" and the vault as "[redacted]".
  const macPaths = [
    '/Users/jinbinliu/Library/Application Support/Distill/collectors/scripts/col-3f2a9c1e-8d4b-4b2a-9c1e-8d4b4b2a9c1e/collector.py',
    '~/Library/Application Support/Distill/collectors/scripts/col-3f2a9c1e-8d4b-4b2a-9c1e-8d4b4b2a9c1e/collector.py',
    '/private/var/folders/1b/qpdk0gs15sl2jjwfmqcxvfjc0000gn/T/distill-activity-Xk9mQ2/state/collectors/scripts/col-a1b2/collector.py',
    '/var/folders/1b/qpdk0gs15sl2jjwfmqcxvfjc0000gn/T/distill-activity-Xk9mQ2/Vault',
    '/private/var/folders/1b/qpdk0gs15sl2jjwfmqcxvfjc0000gn/T/tmp.AbCdEf0123456789GhIjKlMnOpQrStUvWxYz/vault',
    '/Users/jinbinliu/Library/Mobile Documents/iCloud~md~obsidian/Documents/Research Vault',
    '/Users/jinbinliu/Distill Inbox/0123456789abcdef0123456789abcdef01234567/notes.md', // a folder named with 40 hex
    '/tmp/3f2a9c1e8d4b4b2a9c1e8d4b4b2a9c1e/collector.py', // a UUID without dashes
    '~/.Trash/export 2.zip',
  ];

  test('paths stay readable: long temp paths, Application Support, hex and UUID folder names', () => {
    for (const p of macPaths) {
      assert.equal(redactText(p), p);
      assert.equal(redactText(p, { path: true }), p);
      // inside text: an error message quoting the path, and a summary
      const msg = `ENOENT: no such file or directory, open '${p}'`;
      assert.equal(redactText(msg), msg);
      const summary = `Couldn't read ${p} (gone)`;
      assert.equal(redactText(summary), summary);
    }
    const d = redactDetails({ scriptFile: macPaths[0], vault: macPaths[3], folder: macPaths[6], changedPaths: [macPaths[2]] })!;
    assert.equal(d.scriptFile, macPaths[0]);
    assert.equal(d.vault, macPaths[3]);
    assert.equal(d.folder, macPaths[6]);
    assert.deepEqual(d.changedPaths, [macPaths[2]]);
  });

  test('secrets are still caught next to, inside and outside paths', () => {
    const aws = 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'; // AWS secret access key shape: 40 base64 chars with "/"
    const b64 = 'Zm9vYmFyYmF6cXV4MTIzNDU2Nzg5MEFCQ0RFRkdISUpLTE1OT1A=';
    const hex = '9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08';
    for (const s of [aws, b64, hex]) {
      const out = redactText(`secret ${s} here`);
      assert.ok(!out.includes(s), `${s} survived: ${out}`);
    }
    // Precise shapes are caught even inside a path or a path-keyed detail.
    const inPath = '/Users/jinbinliu/keys/sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789/x.py';
    assert.ok(!redactText(inPath).includes('sk-ant-api03'));
    assert.ok(!redactText(inPath, { path: true }).includes('sk-ant-api03'));
    const d = redactDetails({ scriptFile: '/tmp/ATATT3xFfGF0abcdefghijklmnopqrstuvwxyz/run.py' })!;
    assert.ok(!String(d.scriptFile).includes('ATATT3x'));
    // A path next to a secret: the path stays, the secret goes.
    const mixed = `Failed /Users/jinbinliu/Library/Application Support/Distill/collectors/scripts/col-a1b2/collector.py: Authorization: Bearer abcdefgh12345678 and ${aws}`;
    const out = redactText(mixed);
    assert.ok(out.includes('/Users/jinbinliu/Library/Application Support/Distill/collectors/scripts/col-a1b2/collector.py'), out);
    assert.ok(!out.includes('abcdefgh12345678') && !out.includes(aws), out);
    // URLs are not paths: credentials and tokens in them still go.
    assert.equal(redactText('https://me:pa55@example.com/x'), `https://${REDACTED}@example.com/x`);
    const url = `https://example.com/api/${b64}`;
    assert.ok(!redactText(url).includes(b64));
    assert.ok(!redactText('see eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U').includes('eyJhbGci'));
  });

  test('details: secret-looking keys go, strings are clipped, lists capped', () => {
    const d = redactDetails({ token: 'abc', apiKey: 'x', note: 'ok', long: 'x'.repeat(1000), list: Array.from({ length: 30 }, (_, i) => `f${i}`), n: Number.NaN })!;
    assert.equal(d.token, REDACTED);
    assert.equal(d.apiKey, REDACTED);
    assert.equal(d.note, 'ok');
    assert.ok((d.long as string).length <= 300);
    assert.equal((d.list as string[]).length, 21);
    assert.equal(d.n, null);
    assert.ok(clip('a  b\n c', 10) === 'a b c');
  });
});

// ───────────── unit: sources ─────────────

describe('sources', () => {
  test('header, Mac User-Agent, none', () => {
    assert.equal(sourceFromHeaders({ 'x-distill-client': 'cli' }), 'cli');
    assert.equal(sourceFromHeaders({ 'x-distill-client': 'plugin' }), 'agent');
    assert.equal(sourceFromHeaders({ 'x-distill-client': 'Agent' }), 'agent');
    assert.equal(sourceFromHeaders({ 'user-agent': 'Distill/1 CFNetwork/1568.100.1 Darwin/25.5.0' }), 'app');
    assert.equal(sourceFromHeaders({ 'user-agent': 'curl/8.7.1' }), 'api');
    assert.equal(sourceFromHeaders({}), 'api');
    assert.equal(sourceFromHeaders({ 'x-distill-client': 'bogus', 'user-agent': 'curl/8' }), 'api');
  });
});

// ───────────── unit: the log file ─────────────

describe('ActivityLog', () => {
  let dir: string;
  beforeEach(() => {
    dir = tmp('distill-activity-log-');
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  const entry = (i: number, over: Partial<ActivityEntry> = {}) => ({
    type: i % 2 ? 'chat.deleted' : 'collector.updated',
    source: (i % 3 ? 'app' : 'cli') as ActivityEntry['source'],
    object: { kind: (i % 2 ? 'chat' : 'collector') as 'chat' | 'collector', id: `obj-${i % 5}`, name: `Thing ${i}` },
    summary: `Entry number ${i}`,
    outcome: 'ok' as const,
    ...over,
  });

  test('append-only JSON Lines, 0600, newest first, filters and cursor pagination', () => {
    const log = new ActivityLog({ dir });
    for (let i = 0; i < 25; i++) log.record(entry(i));
    const stat = fs.statSync(log.file);
    assert.equal(stat.mode & 0o777, 0o600);
    assert.equal(fs.readFileSync(log.file, 'utf8').trim().split('\n').length, 25);

    const first = log.list({ limit: 10 });
    assert.equal(first.entries.length, 10);
    assert.equal(first.entries[0]!.summary, 'Entry number 24');
    assert.ok(first.nextCursor);
    const second = log.list({ limit: 10, cursor: first.nextCursor! });
    assert.equal(second.entries[0]!.summary, 'Entry number 14');
    const third = log.list({ limit: 10, cursor: second.nextCursor! });
    assert.equal(third.entries.length, 5);
    assert.equal(third.nextCursor, null);

    assert.ok(log.list({ types: ['chat'] }).entries.every((e) => e.type.startsWith('chat.')));
    assert.equal(log.list({ types: ['chat.deleted'] }).entries.length, 12);
    assert.ok(log.list({ sources: ['cli'] }).entries.every((e) => e.source === 'cli'));
    assert.ok(log.list({ objectID: 'obj-2' }).entries.every((e) => e.object.id === 'obj-2'));
    assert.equal(log.list({ objectKind: 'collector' }).entries.length, 13);
    assert.deepEqual(
      log.list({ text: 'number 7' }).entries.map((e) => e.summary),
      ['Entry number 7'],
    );
    assert.equal(log.list({ since: '2999-01-01' }).entries.length, 0);
    assert.equal(log.list({ until: '2000-01-01' }).entries.length, 0);
  });

  test('a line is capped; torn and foreign lines are skipped', () => {
    const log = new ActivityLog({ dir });
    log.record(entry(1, { details: { big: Array.from({ length: 20 }, () => 'y'.repeat(200)) } as never }));
    fs.appendFileSync(log.file, '{"torn": \nnot json\n');
    log.record(entry(2));
    const list = log.list();
    assert.equal(list.entries.length, 2);
    for (const line of fs.readFileSync(log.file, 'utf8').split('\n')) assert.ok(Buffer.byteLength(line) <= 8 * 1024);
  });

  test('rotation by size keeps a bounded number of files and every entry readable', () => {
    const log = new ActivityLog({ dir, maxFileBytes: 2000, keepFiles: 3 });
    for (let i = 0; i < 200; i++) log.record(entry(i));
    const files = fs.readdirSync(dir).filter((n) => n.endsWith('.jsonl'));
    assert.ok(files.includes('activity.jsonl'));
    const rotated = files.filter((n) => n !== 'activity.jsonl');
    assert.equal(rotated.length, 3, files.join(', '));
    assert.ok(rotated.every((n) => /^activity-\d{8}T\d{6}Z-\d+-[0-9a-f]+\.jsonl$/.test(n)));
    // Newest entries survive and read back in order across files.
    const page = log.list({ limit: 30 });
    assert.equal(page.entries[0]!.summary, 'Entry number 199');
    assert.deepEqual(
      page.entries.map((e) => Number(e.summary.split(' ').pop())),
      Array.from({ length: 30 }, (_, i) => 199 - i),
    );
    assert.ok(!fs.existsSync(path.join(dir, '.rotate.lock')));
  });

  test('rotation by age drops old rotated files', () => {
    let now = new Date('2026-01-01T00:00:00Z');
    const log = new ActivityLog({ dir, maxFileBytes: 500, keepDays: 30, now: () => now });
    for (let i = 0; i < 10; i++) log.record(entry(i));
    const oldFiles = fs.readdirSync(dir).filter((n) => n !== 'activity.jsonl');
    assert.ok(oldFiles.length > 0);
    for (const n of oldFiles) fs.utimesSync(path.join(dir, n), new Date('2026-01-01'), new Date('2026-01-01'));
    now = new Date('2026-03-01T00:00:00Z');
    for (let i = 10; i < 20; i++) log.record(entry(i));
    const left = fs.readdirSync(dir);
    for (const n of oldFiles) assert.ok(!left.includes(n), `${n} should have aged out`);
  });

  test('a stale rotation lock is taken over', () => {
    const log = new ActivityLog({ dir, maxFileBytes: 300 });
    fs.mkdirSync(path.join(dir, '.rotate.lock'), { recursive: true });
    const old = new Date(Date.now() - 60_000);
    fs.utimesSync(path.join(dir, '.rotate.lock'), old, old);
    for (let i = 0; i < 10; i++) log.record(entry(i));
    assert.ok(fs.readdirSync(dir).some((n) => n.startsWith('activity-')));
  });

  test('concurrent writers: in-process bursts and four processes, with rotation, lose nothing', async () => {
    const log = new ActivityLog({ dir, maxFileBytes: 64 * 1024, keepFiles: 1000 });
    const writer = path.join(dir, 'writer.ts');
    fs.writeFileSync(
      writer,
      `import { ActivityLog } from ${JSON.stringify(path.join(here, 'log.ts'))};
const log = new ActivityLog({ dir: process.argv[2], maxFileBytes: 64 * 1024, keepFiles: 1000 });
for (let i = 0; i < 300; i++) log.record({ type: 'test.write', source: 'core', outcome: 'ok', object: { kind: 'core', id: process.argv[3] + '-' + i }, summary: 'writer ' + process.argv[3] + ' line ' + i + ' ' + 'z'.repeat(120) });
`,
    );
    const children = ['a', 'b', 'c', 'd'].map(
      (name) =>
        new Promise<number>((resolve, reject) => {
          const child = spawn(process.execPath, ['--import', 'tsx', writer, dir, name], { stdio: ['ignore', 'ignore', 'pipe'] });
          let err = '';
          child.stderr.on('data', (d: Buffer) => (err += d.toString()));
          child.on('error', reject);
          child.on('exit', (code) => (code === 0 ? resolve(code) : reject(new Error(`writer ${name} exited ${code}: ${err}`))));
        }),
    );
    await Promise.all([
      ...children,
      ...Array.from({ length: 4 }, (_, k) =>
        (async () => {
          for (let i = 0; i < 100; i++) {
            log.record({ type: 'test.write', source: 'core', outcome: 'ok', object: { kind: 'core', id: `main${k}-${i}` }, summary: `main ${k} line ${i}` });
            if (i % 10 === 0) await new Promise((r) => setImmediate(r));
          }
        })(),
      ),
    ]);
    const lines: string[] = [];
    for (const name of fs.readdirSync(dir).filter((n) => n.endsWith('.jsonl'))) {
      lines.push(...fs.readFileSync(path.join(dir, name), 'utf8').split('\n').filter((l) => l.trim()));
    }
    const parsed = lines.map((l) => JSON.parse(l) as ActivityEntry); // throws on an interleaved line
    assert.equal(parsed.length, 4 * 300 + 4 * 100);
    assert.equal(new Set(parsed.map((e) => e.object.id)).size, parsed.length);
    assert.equal(new Set(parsed.map((e) => e.id)).size, parsed.length);
    assert.ok(fs.readdirSync(dir).filter((n) => n.startsWith('activity-')).length > 0, 'expected rotation during the run');
    assert.equal(log.list({ limit: 500 }).entries.length, 500);
  });
});

// ───────────── unit: trash ─────────────

describe('Trash', () => {
  let dir: string;
  beforeEach(() => {
    dir = tmp('distill-trash-');
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  test('0700 dir, 0600 files, list without payloads, retention by age, count and size', () => {
    let now = new Date('2026-10-04T12:00:00Z');
    const trash = new Trash({ dir: path.join(dir, 'trash'), now: () => now, keepItems: 3, maxBytes: 9_200 });
    const put = (name: string, payload: unknown) => trash.put({ kind: 'chat', objectID: name, name, source: 'app', details: {}, payload });
    const a = put('a', { secret: 'inline script body' });
    assert.equal(fs.statSync(trash.dir).mode & 0o777, 0o700);
    assert.equal(fs.statSync(path.join(trash.dir, `${a.id}.json`)).mode & 0o777, 0o600);
    const listed = JSON.stringify(trash.list());
    assert.ok(!listed.includes('inline script body'));
    assert.equal(a.expiresAt, '2026-11-03T12:00:00.000Z');
    assert.deepEqual(trash.get(a.id)?.payload, { secret: 'inline script body' });

    for (const n of ['b', 'c', 'd']) {
      now = new Date(now.getTime() + 1000);
      put(n, { n });
    }
    assert.deepEqual(trash.list().map((i) => i.name), ['d', 'c', 'b']); // count cap
    now = new Date(now.getTime() + 1000);
    put('big', { blob: 'x'.repeat(9_000) });
    assert.deepEqual(trash.list().map((i) => i.name), ['big']); // size cap keeps the newest
    now = new Date(now.getTime() + 31 * 86_400_000);
    assert.deepEqual(trash.list(), []); // age
    assert.equal(trash.get('../../etc/passwd'), undefined); // ids are checked: no path traversal
  });

  test('a shorter stay (keepHours): a history-off chat leaves after 24 hours, others stay 30 days', () => {
    let now = new Date('2026-10-04T12:00:00Z');
    const trash = new Trash({ dir: path.join(dir, 'trash'), now: () => now });
    const short = trash.put({ kind: 'chat', objectID: 'off', name: 'off', source: 'app', details: {}, payload: {}, keepHours: 24 });
    trash.put({ kind: 'chat', objectID: 'kept', name: 'kept', source: 'app', details: {}, payload: {} });
    assert.equal(short.expiresAt, '2026-10-05T12:00:00.000Z');
    now = new Date('2026-10-05T11:59:00Z');
    assert.equal(trash.list().length, 2);
    now = new Date('2026-10-05T12:00:01Z');
    assert.deepEqual(trash.list().map((i) => i.name), ['kept']);
  });

  test('a folder goes with its item: copied without node_modules/.venv, removed with it', () => {
    const trash = new Trash({ dir: path.join(dir, 'trash') });
    const src = path.join(dir, 'scripts', 'col-1');
    fs.mkdirSync(path.join(src, 'node_modules', 'x'), { recursive: true });
    fs.mkdirSync(path.join(src, '.venv'), { recursive: true });
    fs.mkdirSync(path.join(src, 'lib', 'node_modules'), { recursive: true });
    fs.writeFileSync(path.join(src, 'collector.py'), 'print(1)');
    const item = trash.put({ kind: 'collector', objectID: 'col-1', name: 'S', source: 'app', details: {}, payload: {}, folder: src });
    const got = trash.get(item.id)!;
    assert.ok(got.files);
    assert.deepEqual(fs.readdirSync(got.files!).sort(), ['collector.py', 'lib']);
    assert.ok(fs.existsSync(path.join(got.files!, 'lib', 'node_modules')), 'only the top-level package folders are skipped');
    assert.equal(item.details.scriptFolder, true);
    trash.remove(item.id);
    assert.ok(!fs.existsSync(got.files!));
  });
});

// ───────────── the wrapper over a fake core (no Keychain) ─────────────

describe('instrumentCore', () => {
  test('runner secrets: which key, never the value; failures logged and rethrown', async () => {
    const dir = tmp('distill-activity-wrap-');
    const log = new ActivityLog({ dir });
    const trash = new Trash({ dir: path.join(dir, 'trash') });
    const fake = createFakeCore();
    const core = instrumentCore(fake, { log, trash, askDir: path.join(dir, 'ask') });
    const secret = 'sk-or-v1-0123456789abcdef0123456789abcdef';
    await runWithSource('app', () => core.setRunnerSecret('openrouter', 'apiKey', secret));
    await runWithSource('cli', () => core.setRunnerSecret('openrouter', 'apiKey', null));
    fake.failNext('approve', new Error('nope'));
    await assert.rejects(runWithSource('app', () => core.approve('job-1')), /nope/);
    const entries = log.list().entries.reverse();
    assert.deepEqual(
      entries.map((e) => [e.type, e.source, e.outcome]),
      [
        ['runner.secret_saved', 'app', 'ok'],
        ['runner.secret_cleared', 'cli', 'ok'],
        ['batch.approved', 'app', 'failed'],
      ],
    );
    assert.equal(entries[0]!.details?.keyName, 'apiKey');
    assert.ok(!fs.readFileSync(log.file, 'utf8').includes(secret));
    assert.equal(entries[2]!.error, 'nope');
    // Reads pass straight through and log nothing.
    await core.listCollectors();
    assert.equal(log.list().entries.length, 3);
    fs.rmSync(dir, { recursive: true, force: true });
  });
});

// ───────────── the event stream ─────────────

describe('event logger', () => {
  test('batches started, ready, applied and failed; runs; retention; queue scans', () => {
    const dir = tmp('distill-activity-events-');
    const log = new ActivityLog({ dir: path.join(dir, 'activity') });
    const job = newJob({ id: 'job-1', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md', 'inbox/b.md'], model: 'sonnet', now: new Date() });
    const logEvent = createEventLogger({ log, getSettings: () => ({ askPreferences: { historyDays: 10 } }) as never, collectorName: () => 'Meeting notes' }, []);
    asScheduler(() => logEvent({ type: 'job', job: { ...job, state: 'running' } }))();
    logEvent({ type: 'job', job: { ...job, state: 'running' } }); // no change, no line
    logEvent({ type: 'job', job: { ...job, state: 'awaitingApproval' } });
    logEvent({ type: 'job', job: { ...job, state: 'completed', changedPaths: ['wiki/a.md'], actionsFound: { status: 'finding', found: 0, pending: 0, added: 0, byType: {} } } });
    logEvent({ type: 'job', job: { ...job, state: 'completed', changedPaths: ['wiki/a.md'], actionsFound: { status: 'done', found: 2, pending: 2, added: 0, byType: { todo: 2 } } } });
    const failed: Job = { ...job, id: 'job-2', state: 'running' };
    logEvent({ type: 'job', job: failed });
    logEvent({ type: 'job', job: { ...failed, state: 'failed', error: 'runner crashed with token=abc' } });
    const run = { id: 'run-1', collectorId: 'col-1', kind: 'script' as const, vaultPath: '/v', startedAt: '2026-10-04T09:00:00Z', counts: { copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 0, added: 2 }, filesAdded: ['a.md', 'b.md'] };
    logEvent({ type: 'collector.run.finished', run: { ...run, trigger: 'schedule', result: 'success' } });
    logEvent({ type: 'collector.run.finished', run: { ...run, trigger: 'schedule', result: 'nothing' } }); // quiet
    runWithSource('app', () => logEvent({ type: 'collector.run.finished', run: { ...run, trigger: 'now', result: 'failed', error: { code: 'exit', message: 'exit 1' } } }));
    logEvent({ type: 'conversation', conversation: { id: 'c1', title: 'Old chat', vaultPath: '/v', createdAt: '', updatedAt: '2026-09-01T00:00:00Z', pinned: false, turnCount: 3 }, deleted: true });
    logEvent({ type: 'action', action: { id: 'act-1', title: 'Old todo', type: 'todo', status: 'done' } as never, deleted: true });
    logEvent({ type: 'queue.scanned', result: { added: 1, removed: 1, changed: 0, checkedAt: '', trigger: 'periodic', addedEntries: [{ name: 'new.md' } as never], removedEntries: [{ name: 'gone.md' } as never], changedEntries: [], entries: [] } });
    logEvent({ type: 'queue.scanned', result: { added: 0, removed: 0, changed: 2, checkedAt: '', trigger: 'manual', addedEntries: [], removedEntries: [], changedEntries: [], entries: [] } });

    const got = readLog(dir).map((e) => [e.type, e.source, e.outcome]);
    assert.deepEqual(got, [
      ['batch.started', 'scheduler', 'ok'],
      ['batch.ready', 'core', 'ok'],
      ['batch.applied', 'core', 'ok'],
      ['action.found', 'core', 'ok'],
      ['batch.started', 'core', 'ok'],
      ['batch.failed', 'core', 'failed'],
      ['collector.run', 'scheduler', 'ok'],
      ['collector.run', 'app', 'failed'],
      ['chat.expired', 'scheduler', 'ok'],
      ['action.expired', 'scheduler', 'ok'],
      ['queue.scanned', 'scheduler', 'ok'],
    ]);
    const all = readLog(dir);
    assert.ok(!JSON.stringify(all).includes('token=abc'));
    assert.match(all.find((e) => e.type === 'batch.applied')!.summary, /applied 1 page change/);
    assert.match(all.find((e) => e.type === 'collector.run')!.summary, /“Meeting notes” added 2 files/);
    fs.rmSync(dir, { recursive: true, force: true });
  });
});

// ───────────── end to end through createCore and HTTP ─────────────

describe('activity through the core and the API', () => {
  let root: string;
  let state: string;
  let vault: string;
  let queue: string;
  let server: RunningServer;
  let core: ReturnType<typeof createCore>;
  const events: CoreEvent[] = [];

  function request(method: string, p: string, body?: unknown, headers: Record<string, string> = { 'x-distill-client': 'app' }): Promise<{ status: number; body: any }> {
    return new Promise((resolve, reject) => {
      const payload = body === undefined ? undefined : JSON.stringify(body);
      const h: Record<string, string> = { authorization: `Bearer ${TOKEN}`, ...headers };
      if (payload !== undefined) {
        h['content-type'] = 'application/json';
        h['content-length'] = String(Buffer.byteLength(payload));
      }
      const req = http.request({ host: '127.0.0.1', port: server.port, method, path: p, headers: h }, (res) => {
        const chunks: Buffer[] = [];
        res.on('data', (c: Buffer) => chunks.push(c));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          resolve({ status: res.statusCode ?? 0, body: text ? JSON.parse(text) : null });
        });
      });
      req.on('error', reject);
      if (payload !== undefined) req.write(payload);
      req.end();
    });
  }

  const last = (type: string) => [...readLog(state)].reverse().find((e) => e.type === type);

  beforeEach(async () => {
    root = tmp('distill-activity-e2e-');
    state = path.join(root, 'state');
    vault = path.join(root, 'vault');
    queue = path.join(root, 'queue');
    for (const d of [state, vault, queue, path.join(root, 'Inbox'), path.join(root, 'trash'), path.join(root, 'bin')]) fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(state, 'settings.json'), JSON.stringify({ vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, settleSeconds: 600 }));
    const done = { ...newJob({ id: 'job-20261004-120000-aaaa', kind: 'ingest', vaultPath: vault, files: ['inbox/x.md'], model: 'sonnet', now: new Date() }), state: 'completed', changedPaths: ['wiki/x.md'] };
    fs.writeFileSync(path.join(state, 'jobs.json'), JSON.stringify([done]));
    events.length = 0;
    // Never the real Keychain or network: an in-memory secret store and a fetch that refuses.
    core = createCore({
      paths: statePaths(state),
      trashDir: path.join(root, 'trash'),
      secrets: new MemorySecretStore(),
      fetch: async () => new Response('{"message":"unauthorized"}', { status: 401, headers: { 'content-type': 'application/json' } }),
      collectors: { homeDir: root, tmpDir: root, loginPath: async () => `${path.join(root, 'bin')}:${process.env.PATH ?? '/usr/bin:/bin'}` },
    });
    core.subscribe((e) => events.push(e));
    server = await startServer({ core, token: TOKEN });
  });

  afterEach(async () => {
    await server.close();
    await core.stop();
    fs.rmSync(root, { recursive: true, force: true });
  });

  test('every core method is classified (logged, read, event or quiet)', () => {
    const classified = classifiedMethods();
    const internal = new Set(['start', 'stop', 'subscribe', 'setJobActions', 'whenIdle', 'listActivity', 'listTrash', 'restoreFromTrash']);
    const methods = Object.keys(core).filter((k) => typeof (core as unknown as Record<string, unknown>)[k] === 'function' && !internal.has(k));
    const missing = methods.filter((m) => !(m in classified));
    assert.deepEqual(missing, [], `unclassified core methods: ${missing.join(', ')}`);
    assert.ok(Object.values(classified).filter((v) => v === 'logged').length >= 40);
  });

  test('collectors: create, enable/disable, consent failure, delete to trash, restore; no script body in the log', async () => {
    const body = '#!/bin/zsh\nexport GOOGLE_TOKEN=ya29.a0AfH6SMBsupersecretvalue1234567890\necho hi > "$DISTILL_QUEUE/a.md"\n';
    const created = await request('POST', '/v1/collectors', { kind: 'script', name: 'Meeting notes', script: { source: { inline: body }, interpreter: 'zsh' } });
    assert.equal(created.status, 201, JSON.stringify(created.body));
    const id = created.body.id as string;
    const folder = await request('POST', '/v1/collectors', { kind: 'folder', name: 'Inbox', folder: { source: path.join(root, 'Inbox') } }, { 'x-distill-client': 'cli' });
    assert.equal(folder.status, 201);
    assert.equal((await request('PATCH', `/v1/collectors/${folder.body.id}`, { enabled: false })).status, 200);
    assert.equal((await request('PATCH', `/v1/collectors/${folder.body.id}`, { enabled: true })).status, 200);
    assert.equal((await request('PATCH', `/v1/collectors/${id}`, { name: 'Meetings' })).status, 200);
    assert.equal((await request('POST', `/v1/collectors/${id}/consent`, { sha256: 'f'.repeat(64) })).status, 409);
    const sha = created.body.status.currentSha256 as string;
    assert.equal((await request('POST', `/v1/collectors/${id}/consent`, { sha256: sha })).status, 200);
    assert.equal((await request('DELETE', `/v1/collectors/${id}/consent`)).status, 200);

    const del = await request('DELETE', `/v1/collectors/${id}`);
    assert.equal(del.status, 200);

    const entries = readLog(state);
    assert.deepEqual(
      entries.map((e) => [e.type, e.source, e.outcome]),
      [
        ['collector.created', 'app', 'ok'],
        ['collector.created', 'cli', 'ok'],
        ['collector.disabled', 'app', 'ok'],
        ['collector.enabled', 'app', 'ok'],
        ['collector.updated', 'app', 'ok'],
        ['collector.consented', 'app', 'failed'],
        ['collector.consented', 'app', 'ok'],
        ['collector.consent_revoked', 'app', 'ok'],
        ['collector.deleted', 'app', 'ok'],
      ],
    );
    const text = fs.readFileSync(path.join(state, 'activity', 'activity.jsonl'), 'utf8');
    assert.ok(!text.includes('supersecretvalue'), 'script secret leaked into the log');
    assert.ok(!text.includes('echo hi'), 'script body leaked into the log');
    const deleted = last('collector.deleted')!;
    assert.equal(deleted.object.name, 'Meetings');
    assert.equal(deleted.details?.scriptBytes, Buffer.byteLength(body));
    assert.equal(deleted.details?.scriptLines, 4);
    assert.equal(deleted.recovery?.kind, 'trash');
    // The activity event went out too.
    assert.ok(events.some((e) => e.type === 'activity' && e.entry.type === 'collector.deleted'));

    // Trash: listed without the script; restore brings it back off, consent cleared, same id.
    const trash = await request('GET', '/v1/trash');
    assert.equal(trash.status, 200);
    assert.equal(trash.body.items.length, 1);
    assert.ok(!JSON.stringify(trash.body).includes('supersecretvalue'));
    const trashId = trash.body.items[0].id as string;
    assert.equal(deleted.recovery?.kind === 'trash' && deleted.recovery.trashId, trashId);
    const restored = await request('POST', `/v1/trash/${trashId}/restore`);
    assert.equal(restored.status, 200, JSON.stringify(restored.body));
    assert.equal(restored.body.objectID, id);
    const back = await core.getCollector(id);
    assert.equal(back?.enabled, false);
    assert.equal(back?.script?.allowedSha256, undefined);
    // v6: the script comes back as a real file with the same bytes.
    const backSource = back?.script?.source as { file: string; managed?: boolean };
    assert.equal(backSource.managed, true);
    assert.equal(fs.readFileSync(backSource.file, 'utf8'), body);
    assert.equal(back?.status?.needsConsent, true);
    assert.equal(last('collector.restored')?.source, 'app');
    assert.equal((await request('GET', '/v1/trash')).body.items.length, 0);
    assert.equal((await request('POST', `/v1/trash/${trashId}/restore`)).status, 404);
  });

  test('v6: one trash for a script collector: its folder goes with the record; delete, restore, allow (packages reinstall), run the same bytes', async () => {
    // A fake npm on the scripts' PATH (never the network).
    fs.writeFileSync(path.join(root, 'bin', 'npm'), '#!/bin/zsh\nprint "fake npm $*"\nmkdir -p node_modules/dep\n', { mode: 0o755 });
    const body = 'print -r -- "token=hunter2-secret" >/dev/null; print -r -- restored > "$2/r.md"\n';
    const created = await request('POST', '/v1/collectors', { kind: 'script', name: 'Round trip', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{"dependencies":{"dep":"1"}}' } });
    assert.equal(created.status, 201);
    const id = created.body.id as string;
    const dir = created.body.status.script.dir as string;
    // The script edited in the app (logged without its text), then allowed: packages install at once.
    const saved = await request('PUT', `/v1/collectors/${id}/script`, { code: body, baseSha256: (await request('GET', `/v1/collectors/${id}/script`)).body.sha256 });
    assert.equal(saved.status, 200, JSON.stringify(saved.body));
    const sha = (await request('GET', `/v1/collectors/${id}`)).body.status.currentSha256 as string;
    assert.equal((await request('POST', `/v1/collectors/${id}/consent`, { sha256: sha })).status, 200);
    for (let i = 0; i < 100 && !last('collector.install'); i += 1) await new Promise((r) => setTimeout(r, 20));
    assert.equal(last('collector.install')?.outcome, 'ok');
    assert.ok(fs.existsSync(path.join(dir, 'node_modules', 'dep')));
    const savedEntry = last('collector.script_saved')!;
    assert.equal(savedEntry.details?.scriptBytes, Buffer.byteLength(body));
    assert.equal(String(savedEntry.details?.scriptSha256).length, 12);

    assert.equal((await request('DELETE', `/v1/collectors/${id}`)).status, 200);
    assert.ok(!fs.existsSync(dir), 'the folder left scripts/');
    assert.ok(!fs.existsSync(path.join(state, 'collectors', 'trash')), 'no second trash');
    const items = (await request('GET', '/v1/trash')).body.items as { id: string; details: Record<string, unknown> }[];
    assert.equal(items.length, 1);
    assert.equal(items[0]!.details.scriptFolder, true);
    const kept = path.join(state, 'trash', `${items[0]!.id}.files`);
    assert.equal(fs.readFileSync(path.join(kept, 'collector.js'), 'utf8'), body);
    assert.ok(fs.existsSync(path.join(kept, 'package.json')));
    assert.ok(!fs.existsSync(path.join(kept, 'node_modules')), 'installed packages are not kept');

    const restored = await request('POST', `/v1/trash/${items[0]!.id}/restore`);
    assert.equal(restored.status, 200, JSON.stringify(restored.body));
    assert.ok(!fs.existsSync(kept), 'the trash copy is gone after a restore');
    const back = (await request('GET', `/v1/collectors/${id}`)).body;
    assert.equal(back.enabled, false);
    assert.equal(back.status.needsConsent, true);
    assert.equal(back.script.source.file, path.join(dir, 'collector.js'));
    assert.equal(fs.readFileSync(back.script.source.file, 'utf8'), body);
    assert.equal(back.status.currentSha256, sha, 'same bytes, same hash');
    assert.equal(back.status.script.manifest.state, 'needsInstall');
    assert.equal((await request('POST', `/v1/collectors/${id}/consent`, { sha256: sha })).status, 200);
    for (let i = 0; i < 100 && (await core.getCollector(id))?.status?.script?.manifest?.state !== 'ready'; i += 1) await new Promise((r) => setTimeout(r, 20));
    assert.equal((await core.getCollector(id))?.status?.script?.manifest?.state, 'ready', 'packages reinstalled on Allow');

    // Run it: the restored bytes (a zsh body under node would fail, so switch the language and allow again).
    await request('PATCH', `/v1/collectors/${id}`, { script: { interpreter: 'zsh' } });
    const zsha = (await request('GET', `/v1/collectors/${id}`)).body.status.currentSha256 as string;
    assert.equal((await request('POST', `/v1/collectors/${id}/consent`, { sha256: zsha })).status, 200);
    assert.equal((await request('POST', `/v1/collectors/${id}/run`)).status, 200);
    for (let i = 0; i < 200 && !fs.existsSync(path.join(queue, 'r.md')); i += 1) await new Promise((r) => setTimeout(r, 25));
    assert.equal(fs.readFileSync(path.join(queue, 'r.md'), 'utf8').trim(), 'restored');
    const text = fs.readFileSync(path.join(state, 'activity', 'activity.jsonl'), 'utf8');
    assert.ok(!text.includes('hunter2'), 'no script text in the log');
  });

  test('a delete is refused when the trash copy cannot be written', async () => {
    const created = await core.createCollector({ kind: 'script', name: 'S', script: { source: { inline: 'echo' }, interpreter: 'zsh' } });
    fs.writeFileSync(path.join(state, 'trash'), 'not a directory');
    await assert.rejects(core.deleteCollector(created.id), /trash/);
    assert.ok(await core.getCollector(created.id), 'collector must still exist');
    assert.equal(last('collector.deleted')?.outcome, 'failed');
  });

  test('chats: delete goes to the trash and restores; history-off deletes are logged with the reason; retention logs expired', async () => {
    const askDir = path.join(state, 'ask');
    fs.mkdirSync(askDir, { recursive: true });
    const chat = (id: string, title: string, updatedAt: string, pinned = false) => {
      const record = {
        conversationID: id,
        sessionID: null,
        selection: { runnerID: 'claude-code', model: 'sonnet' },
        vaultPath: vault,
        createdAt: updatedAt,
        updatedAt,
        turns: 1,
        costUSD: 0,
        title,
        pinned,
        history: [{ askedAt: updatedAt, request: { question: title }, response: { answer: 'sk-ant-api03-thisisasecretinsideananswer000' } }],
      };
      fs.writeFileSync(path.join(askDir, `${id}.json`), JSON.stringify(record));
    };
    const now = new Date().toISOString();
    chat('chat-a', 'How hot for sencha?', now);
    const del = await request('DELETE', '/v1/conversations/chat-a', undefined, { 'user-agent': 'Distill/1 CFNetwork/1568 Darwin/25.5.0' });
    assert.equal(del.status, 200);
    const entry = last('chat.deleted')!;
    assert.equal(entry.source, 'app');
    assert.equal(entry.object.name, 'How hot for sencha?');
    assert.equal(entry.details?.turnCount, 1);
    assert.equal(entry.details?.reason, 'deleted');
    assert.equal(entry.recovery?.kind, 'trash');
    assert.ok(!fs.existsSync(path.join(askDir, 'chat-a.json')));
    const trashId = entry.recovery?.kind === 'trash' ? entry.recovery.trashId : '';
    const restored = await request('POST', `/v1/trash/${trashId}/restore`, undefined, { 'x-distill-client': 'cli' });
    assert.equal(restored.status, 200);
    assert.equal((await core.getConversation('chat-a'))?.title, 'How hot for sencha?');
    assert.equal(last('chat.restored')?.source, 'cli');
    assert.ok(events.some((e) => e.type === 'conversation' && e.conversation.id === 'chat-a' && !e.deleted));

    // A conflict: restoring over an existing chat is refused.
    await request('DELETE', '/v1/conversations/chat-a');
    const id2 = (last('chat.deleted')!.recovery as { trashId: string }).trashId;
    chat('chat-a', 'A new chat with the same id', now);
    assert.equal((await request('POST', `/v1/trash/${id2}/restore`)).status, 409);
    assert.equal(last('chat.restored')?.outcome, 'failed');

    // Keep history off: logged with the reason and kept in the trash for 24 hours (the owner, 2026-10-04).
    await core.updateSettings({ askPreferences: { keepHistory: false } });
    chat('chat-b', 'Closed chat', now);
    const beforeDelete = Date.now();
    await request('DELETE', '/v1/conversations/chat-b');
    const off = last('chat.deleted')!;
    assert.equal(off.details?.reason, 'keep-history-off');
    assert.equal(off.recovery?.kind, 'trash');
    const offExpiry = Date.parse(off.recovery?.kind === 'trash' ? off.recovery.expiresAt : '');
    assert.ok(Math.abs(offExpiry - beforeDelete - 24 * 3_600_000) < 60_000, 'kept 24 hours, not 30 days');
    const offItem = ((await request('GET', '/v1/trash')).body.items as { objectID: string; details: Record<string, unknown> }[]).find((i) => i.objectID === 'chat-b');
    assert.equal(offItem?.details.reason, 'keep-history-off');
    assert.equal(last('settings.changed')?.details?.changes?.toString(), 'askPreferences.keepHistory: — → false');

    // Retention: an old unpinned chat removed by the sweep is "expired", from the scheduler.
    await core.updateSettings({ askPreferences: { keepHistory: true, historyDays: 10 } });
    chat('chat-old', 'Very old chat', '2020-01-01T00:00:00.000Z');
    chat('chat-pinned', 'Old but pinned', '2020-01-01T00:00:00.000Z', true);
    await runWithSource('app', () => core.listConversations()); // hourly sweep: forced below
    const fresh = createCore({ paths: statePaths(state), trashDir: path.join(root, 'trash'), secrets: new MemorySecretStore() });
    await new Promise((r) => setTimeout(r, 100)); // the sweep on creation runs in the background
    await fresh.stop();
    const expired = readLog(state).filter((e) => e.type === 'chat.expired');
    assert.ok(expired.some((e) => e.object.id === 'chat-old' && e.source === 'scheduler'), JSON.stringify(expired));
    assert.ok(!expired.some((e) => e.object.id === 'chat-pinned'));

    const text = readLog(state).map((e) => JSON.stringify(e)).join('\n');
    assert.ok(!text.includes('thisisasecret'));
  });

  test('a restored chat starts its retention days again (no expiry right after Restore)', async () => {
    const askDir = path.join(state, 'ask');
    fs.mkdirSync(askDir, { recursive: true });
    const old = '2020-01-01T00:00:00.000Z';
    fs.writeFileSync(
      path.join(askDir, 'chat-r.json'),
      JSON.stringify({ conversationID: 'chat-r', sessionID: null, selection: { runnerID: 'claude-code', model: 'sonnet' }, vaultPath: vault, createdAt: old, updatedAt: old, turns: 1, costUSD: 0, title: 'Old but wanted', history: [] }),
    );
    await core.deleteConversation('chat-r');
    const trashId = (last('chat.deleted')!.recovery as { trashId: string }).trashId;
    await core.restoreFromTrash(trashId);
    const fresh = createCore({ paths: statePaths(state), trashDir: path.join(root, 'trash'), secrets: new MemorySecretStore() });
    await new Promise((r) => setTimeout(r, 100)); // the sweep on creation
    await fresh.stop();
    assert.equal((await core.getConversation('chat-r'))?.title, 'Old but wanted');
    assert.ok(!readLog(state).some((e) => e.type === 'chat.expired' && e.object.id === 'chat-r'));
  });

  test('a brand-new state dir lists empty activity and trash', async () => {
    const page = await request('GET', '/v1/activity');
    assert.equal(page.status, 200);
    assert.deepEqual(page.body, { entries: [], nextCursor: null });
    const trash = await request('GET', '/v1/trash');
    assert.deepEqual(trash.body, { items: [] });
  });

  test('settings, secrets, queue, notes, actions, batches and connections are logged; unknown callers are "api"', async () => {
    // settings: changed keys with values
    assert.equal((await request('PUT', '/v1/settings', { batchIntervalMinutes: 15 })).status, 200);
    const s = last('settings.changed')!;
    assert.deepEqual(s.details?.changes, ['batchIntervalMinutes: 10 → 15']);
    // no change, no line
    const before = readLog(state).length;
    await request('PUT', '/v1/settings', { batchIntervalMinutes: 15 });
    assert.equal(readLog(state).length, before);

    // a caller that doesn't say who it is: "api"
    await request('PUT', '/v1/settings', { batchIntervalMinutes: 20 }, {});
    assert.equal(last('settings.changed')?.source, 'api');

    // queue: add a file, remove it (to the test Trash dir)
    const src = path.join(root, 'clip.md');
    fs.writeFileSync(src, '# clip');
    const added = await request('POST', '/v1/queue/files', { paths: [src] });
    assert.equal(added.status, 200, JSON.stringify(added.body));
    assert.equal(last('queue.added')?.object.name, 'clip.md');
    const queued = added.body.entries[0].path as string;
    assert.equal((await request('DELETE', '/v1/queue/entries', { path: queued })).status, 200);
    const removed = last('queue.removed')!;
    assert.equal(removed.recovery?.kind, 'macosTrash');
    assert.equal(removed.details?.size, 6);

    // a note
    const note = await request('POST', '/v1/notes', { title: 'Tea notes', text: 'Gyokuro at 60°C', suggest: 'none' }, { 'x-distill-client': 'agent' });
    assert.equal(note.status, 201, JSON.stringify(note.body));
    assert.equal(last('note.added')?.source, 'agent');
    assert.ok(!JSON.stringify(last('note.added')).includes('Gyokuro'), 'note text is not logged');

    // actions
    const action = await request('POST', '/v1/actions', { title: 'Buy sencha', type: 'todo' });
    assert.equal(action.status, 201, JSON.stringify(action.body));
    const aid = action.body.id as string;
    await request('PATCH', `/v1/actions/${aid}`, { title: 'Buy gyokuro', body: 'secret plan' });
    await request('POST', `/v1/actions/${aid}/remove`);
    await request('POST', `/v1/actions/${aid}/restore`);
    await request('POST', `/v1/actions/${aid}/remove`);
    await request('DELETE', `/v1/actions/${aid}`);
    const types = readLog(state).filter((e) => e.object.kind === 'action').map((e) => e.type);
    assert.deepEqual(types, ['action.created', 'action.updated', 'action.removed', 'action.restored', 'action.removed', 'action.deleted']);
    assert.deepEqual(last('action.updated')?.details?.changed, ['title', 'body']);
    assert.ok(!JSON.stringify(readLog(state)).includes('secret plan'));
    assert.equal(last('action.deleted')?.object.name, 'Buy gyokuro');
    assert.equal(last('action.deleted')?.recovery?.kind, 'none');

    // batches: delete a finished one; approving a missing one fails before the core (404, not logged)
    assert.equal((await request('DELETE', '/v1/jobs/job-20261004-120000-aaaa')).status, 200);
    const jd = last('batch.deleted')!;
    assert.equal(jd.object.name, 'Batch · 1 file');
    assert.deepEqual(jd.details?.files, ['inbox/x.md']);
    assert.equal(jd.details?.state, 'completed');

    // connections: a failed connect is logged without the token
    const token = 'ATATT3xFfGF0verysecretatlassiantoken12345';
    await request('POST', '/v1/connections/atlassian/connect', { site: 'acme.atlassian.net', email: 'me@acme.com', token });
    const conn = last('connection.connected')!;
    assert.ok(conn);
    const all = JSON.stringify(readLog(state));
    assert.ok(!all.includes(token));
    assert.ok(!all.includes('me@acme.com'));

    // the API: filters, pagination, bad input
    const page = await request('GET', '/v1/activity?type=action&limit=2');
    assert.equal(page.status, 200);
    assert.equal(page.body.entries.length, 2);
    assert.equal(page.body.entries[0].type, 'action.deleted');
    const next = await request('GET', `/v1/activity?type=action&limit=2&cursor=${page.body.nextCursor}`);
    assert.deepEqual(next.body.entries.map((e: ActivityEntry) => e.type), ['action.restored', 'action.removed']);
    assert.equal((await request('GET', `/v1/activity?object=${aid}`)).body.entries.length, 6);
    assert.ok((await request('GET', '/v1/activity?source=agent')).body.entries.every((e: ActivityEntry) => e.source === 'agent'));
    assert.equal((await request('GET', '/v1/activity?q=gyokuro')).body.entries.length >= 1, true);
    assert.equal((await request('GET', '/v1/activity?kind=batch')).body.entries[0].type, 'batch.deleted');
    assert.equal((await request('GET', '/v1/activity?source=martian')).status, 400);
    assert.equal((await request('GET', '/v1/activity?limit=0')).status, 400);
    assert.equal((await request('GET', '/v1/activity?since=yesterday-ish')).status, 400);
    assert.equal((await request('GET', '/v1/activity?since=2999-01-01')).body.entries.length, 0);
  });
});
