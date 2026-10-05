import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, it } from 'node:test';
import { CoreError } from '../contracts.js';
import { createFakeCore, type FakeCore } from './fake-core.js';
import { startServer, type RunningServer } from './http.js';

const TOKEN = 'd'.repeat(64);

function request(port: number, method: string, path: string, body?: unknown): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const headers: Record<string, string> = { authorization: `Bearer ${TOKEN}` };
    if (payload !== undefined) {
      headers['content-type'] = 'application/json';
      headers['content-length'] = String(Buffer.byteLength(payload));
    }
    const req = http.request({ host: '127.0.0.1', port, method, path, headers }, (res) => {
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

describe('HTTP API: collectors', () => {
  let core: FakeCore;
  let server: RunningServer;
  let port: number;
  before(async () => {
    core = createFakeCore();
    server = await startServer({ core, token: TOKEN, port: 0 });
    port = server.port;
  });
  after(() => server.close());
  const last = (m: string) => core.calls.filter((c) => c.method === m).at(-1);

  it('lists, gets (404 when unknown) and creates with validation', async () => {
    const list = await request(port, 'GET', '/v1/collectors');
    assert.equal(list.status, 200);
    assert.equal(list.body.collectors[0].id, 'col-1');
    assert.equal((await request(port, 'GET', '/v1/collectors/col-1')).body.name, 'Distill Inbox');
    const missing = await request(port, 'GET', '/v1/collectors/nope');
    assert.equal(missing.status, 404);
    assert.equal(missing.body.error.code, 'collector_not_found');

    const made = await request(port, 'POST', '/v1/collectors', {
      kind: 'folder', name: 'Downloads', vaultPath: '/tmp/vault', schedule: { cron: '*/15 * * * *', preset: 'every15' },
      folder: { source: '~/Downloads', afterCollect: 'move' },
    });
    assert.equal(made.status, 201);
    assert.deepEqual(last('createCollector')!.args[0], {
      kind: 'folder', name: 'Downloads', vaultPath: '/tmp/vault', schedule: { cron: '*/15 * * * *', preset: 'every15' },
      folder: { source: '~/Downloads', afterCollect: 'move' },
    });
    const script = await request(port, 'POST', '/v1/collectors', { kind: 'script', script: { source: { inline: 'echo hi' }, interpreter: 'python3', timeoutSeconds: 60 } });
    assert.equal(script.status, 201);
    assert.deepEqual(last('createCollector')!.args[0], { kind: 'script', script: { source: { inline: 'echo hi' }, interpreter: 'python3', timeoutSeconds: 60 } });

    for (const bad of [
      {},
      { kind: 'webhook' },
      { kind: 'script' },
      { kind: 'script', script: { source: { inline: 'x', file: '/x' }, interpreter: 'zsh' } },
      { kind: 'script', script: { source: { inline: 'x' }, interpreter: 'bash' } },
      { kind: 'folder', folder: { afterCollect: 'shred' } },
      { kind: 'folder', schedule: { preset: 'hourly' } },
      { kind: 'folder', enabled: 'yes' },
    ]) {
      assert.equal((await request(port, 'POST', '/v1/collectors', bad)).status, 400, JSON.stringify(bad));
    }
  });

  it('patches, deletes, runs, stops; core errors map to HTTP codes', async () => {
    const patched = await request(port, 'PATCH', '/v1/collectors/col-1', { enabled: false, script: { timeoutSeconds: 120 } });
    assert.equal(patched.status, 200);
    assert.deepEqual(last('updateCollector')!.args, ['col-1', { enabled: false, script: { timeoutSeconds: 120 } }]);
    const run = await request(port, 'POST', '/v1/collectors/col-1/run');
    assert.equal(run.status, 200);
    assert.equal(run.body.run.result, 'running');
    core.failNext('runCollector', new CoreError('busy', 'Distill Inbox is already running.'));
    const busy = await request(port, 'POST', '/v1/collectors/col-1/run');
    assert.equal(busy.status, 409);
    assert.equal(busy.body.error.code, 'busy');
    core.collectorRuns.unshift({ ...core.collectorRuns[0]!, id: 'run-live', result: 'running' });
    const stop = await request(port, 'POST', '/v1/collectors/col-1/stop');
    assert.equal(stop.body.run.result, 'stopped');
    assert.equal((await request(port, 'POST', '/v1/collectors/col-1/stop')).body.run, null);
    assert.equal((await request(port, 'POST', '/v1/collectors/nope/run')).status, 404);
    const del = await request(port, 'DELETE', '/v1/collectors/col-2');
    assert.deepEqual(del.body, { id: 'col-2', deleted: true });
  });

  it('consent: allow needs sha256; revoke', async () => {
    assert.equal((await request(port, 'POST', '/v1/collectors/col-3/consent', {})).status, 400);
    const ok = await request(port, 'POST', '/v1/collectors/col-3/consent', { sha256: 'a'.repeat(64) });
    assert.equal(ok.status, 200);
    assert.deepEqual(last('allowCollector')!.args, ['col-3', 'a'.repeat(64)]);
    core.failNext('allowCollector', new CoreError('invalid_state', 'The script changed since you reviewed it.'));
    assert.equal((await request(port, 'POST', '/v1/collectors/col-3/consent', { sha256: 'b'.repeat(64) })).status, 409);
    const revoked = await request(port, 'DELETE', '/v1/collectors/col-3/consent');
    assert.equal(revoked.body.enabled, false);
  });

  it('runs history, Already collected, Forget, Undo, create folder, schedule check', async () => {
    const runs = await request(port, 'GET', '/v1/collectors/col-1/runs?limit=1');
    assert.equal(runs.body.runs.length, 1);
    assert.deepEqual(last('listCollectorRuns')!.args, ['col-1', { limit: 1 }]);
    assert.equal((await request(port, 'GET', '/v1/collectors/col-1/runs?limit=0')).status, 400);
    const files = await request(port, 'GET', '/v1/collectors/col-1/collected?query=gyo');
    assert.equal(files.body.files.length, 1);
    assert.deepEqual(last('listCollected')!.args, ['col-1', 'gyo']);
    const one = await request(port, 'DELETE', `/v1/collectors/col-1/collected/${'a'.repeat(64)}`);
    assert.equal(one.body.forgotten.length, 1);
    assert.equal((await request(port, 'DELETE', '/v1/collectors/col-1/collected/not-a-hash')).status, 404);
    const undo = await request(port, 'POST', '/v1/collectors/col-1/collected/restore', { files: one.body.forgotten });
    assert.equal(undo.body.restored, 1);
    assert.equal((await request(port, 'POST', '/v1/collectors/col-1/collected/restore', { files: [{ sha256: 'x' }] })).status, 400);
    const all = await request(port, 'DELETE', '/v1/collectors/col-1/collected');
    assert.equal(all.body.forgotten.length, 1);
    assert.deepEqual(last('forgetCollected')!.args, ['col-1', undefined]);
    assert.equal((await request(port, 'POST', '/v1/collectors/col-1/create-folder', { which: 'queue' })).status, 200);
    assert.equal((await request(port, 'POST', '/v1/collectors/col-1/create-folder', { which: 'vault' })).status, 400);
    const check = await request(port, 'POST', '/v1/collectors/check-schedule', { cron: '0 * * * *' });
    assert.equal(check.body.valid, true);
    assert.equal((await request(port, 'POST', '/v1/collectors/check-schedule', {})).status, 400);
  });

  it('v6: script files, packages and the typescript language', async () => {
    const made = await request(port, 'POST', '/v1/collectors', {
      kind: 'script', script: { source: { inline: 'console.log(1 as number)' }, interpreter: 'typescript', manifest: '{"dependencies":{}}' },
    });
    assert.equal(made.status, 201);
    assert.deepEqual(last('createCollector')!.args[0], {
      kind: 'script', script: { source: { inline: 'console.log(1 as number)' }, interpreter: 'typescript', manifest: '{"dependencies":{}}' },
    });
    const id = made.body.id as string;
    const bad = await request(port, 'POST', '/v1/collectors', { kind: 'script', script: { source: { inline: 'x' }, interpreter: 'bash' } });
    assert.equal(bad.status, 400);

    const got = await request(port, 'GET', `/v1/collectors/${id}/script`);
    assert.equal(got.status, 200);
    assert.equal(got.body.managed, true);
    const put = await request(port, 'PUT', `/v1/collectors/${id}/script`, { code: 'x', manifest: null, baseSha256: 'a'.repeat(64), baseManifestSha256: null });
    assert.equal(put.status, 200);
    assert.deepEqual(last('writeCollectorScript')!.args, [id, { code: 'x', manifest: null, baseSha256: 'a'.repeat(64), baseManifestSha256: null }]);
    assert.equal((await request(port, 'PUT', `/v1/collectors/${id}/script`, {})).status, 400, 'nothing to save');

    const inst = await request(port, 'POST', `/v1/collectors/${id}/install`, { clean: true });
    assert.equal(inst.status, 200);
    assert.equal(inst.body.install.result, 'running');
    assert.deepEqual(last('installCollectorPackages')!.args, [id, { clean: true }]);
    assert.equal((await request(port, 'POST', `/v1/collectors/${id}/install`)).status, 200, 'an empty body is fine');
    assert.deepEqual(last('installCollectorPackages')!.args, [id, undefined]);
    assert.deepEqual((await request(port, 'POST', `/v1/collectors/${id}/install/stop`)).body, { install: null });
    assert.deepEqual((await request(port, 'GET', `/v1/collectors/${id}/install`)).body, { install: null });
    const test = await request(port, 'POST', `/v1/collectors/${id}/test`);
    assert.equal(test.status, 200);
    assert.equal(test.body.run.trigger, 'test');
    assert.deepEqual(last('testCollector')!.args, [id]);
    core.failNext('installCollectorPackages', new CoreError('invalid_state', 'Allow first.'));
    assert.equal((await request(port, 'POST', `/v1/collectors/${id}/install`, {})).status, 409);
  });
});
