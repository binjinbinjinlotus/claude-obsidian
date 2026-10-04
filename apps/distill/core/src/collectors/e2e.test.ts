/**
 * End to end through createCore and the HTTP API: a real Folder collection and a
 * real zsh script against temp dirs (temp state dir, throwaway vault and queue).
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import type { CoreEvent } from '../contracts.js';
import { createCore } from '../index.js';
import { startServer, type RunningServer } from '../server/http.js';
import { statePaths } from '../store/paths.js';

const TOKEN = 'c'.repeat(64);
let root: string;
let server: RunningServer;
let core: ReturnType<typeof createCore>;
const events: CoreEvent[] = [];
let vault: string;
let queue: string;
let inbox: string;

function request(method: string, p: string, body?: unknown): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const headers: Record<string, string> = { authorization: `Bearer ${TOKEN}` };
    if (payload !== undefined) {
      headers['content-type'] = 'application/json';
      headers['content-length'] = String(Buffer.byteLength(payload));
    }
    const req = http.request({ host: '127.0.0.1', port: server.port, method, path: p, headers }, (res) => {
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

async function runToEnd(id: string): Promise<any> {
  const started = await request('POST', `/v1/collectors/${id}/run`);
  assert.equal(started.status, 200, JSON.stringify(started.body));
  for (let i = 0; i < 250; i++) {
    const runs = await request('GET', `/v1/collectors/${id}/runs?limit=1`);
    const run = runs.body.runs[0];
    if (run.id === started.body.run.id && run.result !== 'running' && run.result !== 'queued') return run;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error('run did not finish');
}

before(async () => {
  root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-collectors-e2e-')));
  vault = path.join(root, 'vault');
  queue = path.join(root, 'queue');
  inbox = path.join(root, 'Distill Inbox');
  const state = path.join(root, 'state');
  for (const d of [vault, queue, inbox, state]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({ vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, settleSeconds: 600 }),
  );
  core = createCore({
    paths: statePaths(state),
    collectors: {
      homeDir: root,
      tmpDir: root,
      killGraceMs: 500,
      loginPath: async () => process.env.PATH ?? '/usr/bin:/bin',
      baseEnv: { ...process.env, HOME: root, DISTILL_STATE_DIR: state, DISTILL_TOKEN_HINT: 'secret' },
    },
  });
  core.subscribe((e) => events.push(e));
  server = await startServer({ core, token: TOKEN, port: 0 });
});

after(async () => {
  await server.close();
  await core.stop();
  fs.rmSync(root, { recursive: true, force: true });
});

test('a real Folder collection: copy, dedupe, Forget, collect again', async () => {
  const old = new Date(Date.now() - 3600_000);
  fs.writeFileSync(path.join(inbox, 'gyokuro.md'), '# Gyokuro\n');
  fs.writeFileSync(path.join(inbox, 'gyokuro copy.md'), '# Gyokuro\n');
  fs.writeFileSync(path.join(inbox, '.DS_Store'), 'x');
  fs.utimesSync(path.join(inbox, 'gyokuro.md'), new Date(old.getTime() - 60_000), new Date(old.getTime() - 60_000)); // oldest first
  fs.utimesSync(path.join(inbox, 'gyokuro copy.md'), old, old);

  const created = await request('POST', '/v1/collectors', { kind: 'folder', name: 'Inbox', folder: { source: '~/Distill Inbox' } });
  assert.equal(created.status, 201);
  const id = created.body.id;
  assert.equal(created.body.folder.source, inbox);
  assert.equal(created.body.vaultPath, vault);

  const run = await runToEnd(id);
  assert.equal(run.result, 'success');
  assert.equal(run.counts.copied, 1);
  assert.equal(run.counts.skipped, 1);
  assert.deepEqual(fs.readdirSync(queue), ['gyokuro.md']);
  assert.ok(fs.existsSync(path.join(inbox, 'gyokuro.md')));
  // The core's own queue sees the copy as ready at once (mtime kept).
  const entry = core.listQueue().find((e) => e.name === 'gyokuro.md');
  assert.ok(entry, 'listed in the queue');
  assert.equal(entry.settled, true);

  const collected = await request('GET', `/v1/collectors/${id}/collected?query=gyo`);
  assert.equal(collected.body.files.length, 1);
  const sha = collected.body.files[0].sha256;
  const forgot = await request('DELETE', `/v1/collectors/${id}/collected/${sha}`);
  assert.equal(forgot.body.forgotten.length, 1);
  const again = await runToEnd(id);
  assert.deepEqual(again.filesAdded, ['gyokuro 2.md']);
  const status = (await request('GET', `/v1/collectors/${id}`)).body.status;
  assert.equal(status.collectedCount, 1);
  assert.equal(status.lastRun.result, 'success');

  assert.ok(events.some((e) => e.type === 'collector.run.finished' && e.run.collectorId === id));
  assert.ok(fs.existsSync(path.join(root, 'state', 'collectors.json')));
});

test('a real zsh script: consent first, then argv, env, temp cwd, closed stdin, files added', async () => {
  const code = [
    'print -r -- "args:$1|$2"',
    'print -r -- "env:$DISTILL_VAULT|$DISTILL_QUEUE_DIR|${DISTILL_STATE_DIR:-unset}|${DISTILL_TOKEN_HINT:-unset}|$DISTILL_COLLECTOR_ID"',
    'print -r -- "cwd:$PWD"',
    'print -r -- "$PWD" > "$2/.cwd"',
    'if read -t 1 line; then print -r -- "stdin:open"; else print -r -- "stdin:closed"; fi',
    'tmp="$2/.partial"; print -r -- "from the script" > "$tmp"; mv "$tmp" "$2/collected-by-script.md"',
    'print -u2 -- "a warning"',
  ].join('\n');
  const created = await request('POST', '/v1/collectors', { kind: 'script', name: 'Pull', script: { source: { inline: code }, interpreter: 'zsh', timeoutSeconds: 60 } });
  assert.equal(created.status, 201);
  const id = created.body.id;
  assert.equal(created.body.enabled, false);
  assert.equal(created.body.status.needsConsent, true);

  const notYet = await runToEnd(id);
  assert.equal(notYet.result, 'notTrusted');
  assert.equal(notYet.error.code, 'notAllowed');
  assert.ok(!fs.existsSync(path.join(queue, 'collected-by-script.md')));
  assert.equal((await request('PATCH', `/v1/collectors/${id}`, { enabled: true })).status, 409);
  assert.equal((await request('POST', `/v1/collectors/${id}/consent`, { sha256: '0'.repeat(64) })).status, 409);

  const ok = await request('POST', `/v1/collectors/${id}/consent`, { sha256: created.body.status.currentSha256 });
  assert.equal(ok.status, 200);
  assert.equal(ok.body.enabled, true);

  const run = await runToEnd(id);
  assert.equal(run.result, 'success', JSON.stringify(run));
  assert.equal(run.exitCode, 0);
  assert.deepEqual(run.filesAdded, ['collected-by-script.md']);
  const out = run.stdoutTail.split('\n');
  assert.equal(out[0], `args:${vault}|${queue}`);
  assert.equal(out[1], `env:${vault}|${queue}|unset|unset|${id}`, 'no Distill variables leak in');
  assert.match(out[2], new RegExp(`^cwd:${root.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/distill-run-${run.id}-`));
  assert.equal(out[3], 'stdin:closed');
  assert.equal(run.stderrTail, 'a warning\n');
  const cwd = fs.readFileSync(path.join(queue, '.cwd'), 'utf8').trim();
  assert.ok(!fs.existsSync(cwd), 'the temp working folder is deleted after the run');
  assert.ok(events.some((e) => e.type === 'collector.run.output' && e.runId === run.id && e.text.includes('args:')));

  // Revoke over HTTP turns it off.
  const revoked = await request('DELETE', `/v1/collectors/${id}/consent`);
  assert.equal(revoked.body.enabled, false);
  assert.equal(revoked.body.script.allowedSha256, null);
});

test('schedule check and errors over HTTP', async () => {
  const good = await request('POST', '/v1/collectors/check-schedule', { cron: '30 8 * * 1-5' });
  assert.equal(good.body.valid, true);
  assert.equal(good.body.preset, 'weekdays');
  assert.equal(good.body.nextRuns.length, 3);
  const bad = await request('POST', '/v1/collectors/check-schedule', { cron: '@reboot' });
  assert.equal(bad.body.valid, false);
  assert.equal((await request('POST', '/v1/collectors', { kind: 'folder', schedule: { cron: 'nope' } })).status, 400);
  assert.equal((await request('GET', '/v1/collectors/col-missing')).status, 404);
  assert.equal((await request('POST', '/v1/collectors/col-missing/run')).status, 404);
  const list = await request('GET', '/v1/collectors');
  assert.equal(list.body.collectors.length, 2);
});
