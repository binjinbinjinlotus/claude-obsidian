import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, it } from 'node:test';
import { createFakeCore, type FakeCore } from './fake-core.js';
import { startServer, type RunningServer } from './http.js';

const TOKEN = 'a'.repeat(64);

interface Res {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: any; // eslint-disable-line @typescript-eslint/no-explicit-any
}

function request(
  port: number,
  method: string,
  path: string,
  opts: { headers?: Record<string, string>; body?: unknown; raw?: string; auth?: boolean } = {},
): Promise<Res> {
  return new Promise((resolve, reject) => {
    const payload = opts.raw ?? (opts.body === undefined ? undefined : JSON.stringify(opts.body));
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    if (opts.auth !== false && !('authorization' in headers)) headers.authorization = `Bearer ${TOKEN}`;
    if (payload !== undefined && !('content-type' in headers)) headers['content-type'] = 'application/json';
    const req = http.request({ host: '127.0.0.1', port, method, path, headers }, (res) => {
      const chunks: Buffer[] = [];
      res.on('data', (c: Buffer) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let body: unknown = text;
        try {
          body = JSON.parse(text);
        } catch {
          /* keep text */
        }
        resolve({ status: res.statusCode ?? 0, headers: res.headers, body });
      });
    });
    req.on('error', reject);
    if (payload !== undefined) req.write(payload);
    req.end();
  });
}

describe('HTTP API', () => {
  let core: FakeCore;
  let server: RunningServer;
  let port: number;

  before(async () => {
    core = createFakeCore();
    server = await startServer({ core, token: TOKEN, port: 0, keepAliveMs: 50, maxBodyBytes: 4096 });
    port = server.port;
  });
  after(() => server.close());

  const lastCall = () => core.calls.at(-1);
  const callsOf = (m: string) => core.calls.filter((c) => c.method === m);

  it('binds 127.0.0.1 only', async () => {
    await assert.rejects(startServer({ core, token: TOKEN, host: '0.0.0.0' }), /127\.0\.0\.1/);
  });

  describe('security', () => {
    it('requires a bearer token (401)', async () => {
      const res = await request(port, 'GET', '/v1/status', { auth: false });
      assert.equal(res.status, 401);
      assert.deepEqual(Object.keys(res.body), ['error']);
      assert.equal(res.body.error.code, 'unauthorized');
      assert.equal(typeof res.body.error.message, 'string');
    });
    it('rejects a wrong token, including one of different length', async () => {
      for (const t of ['b'.repeat(64), 'short', `${TOKEN}x`]) {
        const res = await request(port, 'GET', '/v1/status', { headers: { authorization: `Bearer ${t}` } });
        assert.equal(res.status, 401, t);
      }
    });
    it('rejects a non-local Host (403)', async () => {
      const res = await request(port, 'GET', '/v1/status', { headers: { host: 'evil.example:80' } });
      assert.equal(res.status, 403);
      assert.equal(res.body.error.code, 'forbidden_host');
    });
    it('accepts localhost and [::1] Host headers', async () => {
      for (const host of [`localhost:${port}`, `[::1]:${port}`, '127.0.0.1']) {
        const res = await request(port, 'GET', '/v1/status', { headers: { host } });
        assert.equal(res.status, 200, host);
      }
    });
    it('rejects non-local or null Origin (403), allows local Origin', async () => {
      for (const origin of ['https://evil.example', 'null', 'http://127.0.0.1.evil.example', 'file://']) {
        const res = await request(port, 'GET', '/v1/status', { headers: { origin } });
        assert.equal(res.status, 403, origin);
        assert.equal(res.body.error.code, 'forbidden_origin');
      }
      const ok = await request(port, 'GET', '/v1/status', { headers: { origin: 'http://localhost:3000' } });
      assert.equal(ok.status, 200);
      assert.equal(ok.headers['access-control-allow-origin'], undefined);
    });
    it('checks Host/Origin before the token', async () => {
      const res = await request(port, 'GET', '/v1/status', { auth: false, headers: { origin: 'https://evil.example' } });
      assert.equal(res.status, 403);
    });
  });

  describe('errors', () => {
    it('404 for unknown routes, 405 for wrong methods', async () => {
      const nf = await request(port, 'GET', '/v1/nope');
      assert.equal(nf.status, 404);
      assert.equal(nf.body.error.code, 'not_found');
      const na = await request(port, 'DELETE', '/v1/settings');
      assert.equal(na.status, 405);
      assert.equal(na.body.error.code, 'method_not_allowed');
      assert.match(String(na.headers.allow), /GET/);
    });
    it('400 for invalid JSON and invalid shapes', async () => {
      const bj = await request(port, 'POST', '/v1/ask', { raw: '{nope' });
      assert.equal(bj.status, 400);
      assert.equal(bj.body.error.code, 'invalid_json');
      const bs = await request(port, 'POST', '/v1/ask', { body: { question: 42 } });
      assert.equal(bs.status, 400);
      assert.equal(bs.body.error.code, 'invalid_request');
      const bq = await request(port, 'POST', '/v1/queue/files', { body: { paths: [] } });
      assert.equal(bq.status, 400);
    });
    it('415 for a non-JSON body', async () => {
      const res = await request(port, 'POST', '/v1/ask', { raw: 'question=hi', headers: { 'content-type': 'application/x-www-form-urlencoded' } });
      assert.equal(res.status, 415);
    });
    it('413 for an oversized body', async () => {
      const res = await request(port, 'POST', '/v1/ask', { body: { question: 'x'.repeat(10_000) } });
      assert.equal(res.status, 413);
      assert.equal(res.body.error.code, 'payload_too_large');
    });
    it('maps core errors: status/code when given, else 500', async () => {
      core.failNext('status', Object.assign(new Error('boom'), {}));
      const e500 = await request(port, 'GET', '/v1/status');
      assert.equal(e500.status, 500);
      assert.deepEqual(e500.body, { error: { code: 'internal_error', message: 'boom' } });
      core.failNext('ask', Object.assign(new Error('no vault selected'), { code: 'no_vault' }));
      const e409 = await request(port, 'POST', '/v1/ask', { body: { question: 'q' } });
      assert.equal(e409.status, 409);
      assert.equal(e409.body.error.code, 'no_vault');
      core.failNext('addNote', Object.assign(new Error('bad image'), { status: 422, code: 'bad_image' }));
      const e422 = await request(port, 'POST', '/v1/notes', { body: { title: 't', text: 'x' } });
      assert.equal(e422.status, 422);
    });
    it('maps plain precondition Errors: job actions 409, notes/queue files 400; system errors stay 500', async () => {
      const id = core.jobs[0]!.id;
      core.failNext('approve', new Error('Another job holds this vault.'));
      const e409 = await request(port, 'POST', `/v1/jobs/${id}/approve`);
      assert.equal(e409.status, 409);
      assert.deepEqual(e409.body, { error: { code: 'invalid_state', message: 'Another job holds this vault.' } });
      core.failNext('addNote', new Error('no vault selected'));
      const e400 = await request(port, 'POST', '/v1/notes', { body: { title: 't', text: 'x' } });
      assert.equal(e400.status, 400);
      assert.equal(e400.body.error.code, 'invalid_request');
      core.failNext('addQueueFiles', Object.assign(new Error('EACCES: permission denied'), { code: 'EACCES' }));
      const e500 = await request(port, 'POST', '/v1/queue/files', { body: { paths: ['/x'] } });
      assert.equal(e500.status, 500);
    });
  });

  describe('routes', () => {
    it('GET /v1/status', async () => {
      const res = await request(port, 'GET', '/v1/status');
      assert.equal(res.status, 200);
      assert.equal(res.body.version, '0.1.0-fake');
      assert.equal(lastCall()?.method, 'status');
    });
    it('GET and PUT /v1/settings', async () => {
      const get = await request(port, 'GET', '/v1/settings');
      assert.equal(get.status, 200);
      assert.equal(get.body.model, 'sonnet');
      const put = await request(port, 'PUT', '/v1/settings', { body: { batchIntervalMinutes: 5 } });
      assert.equal(put.status, 200);
      assert.equal(put.body.batchIntervalMinutes, 5);
      assert.deepEqual(lastCall(), { method: 'updateSettings', args: [{ batchIntervalMinutes: 5 }] });
      const bad = await request(port, 'PUT', '/v1/settings', { body: [1] });
      assert.equal(bad.status, 400);
    });
    it('queue routes', async () => {
      const add = await request(port, 'POST', '/v1/queue/files', { body: { paths: ['/tmp/a.md'] } });
      assert.equal(add.status, 200);
      assert.equal(add.body.entries[0].path, '/tmp/a.md');
      assert.deepEqual(lastCall(), { method: 'addQueueFiles', args: [['/tmp/a.md']] });
      const list = await request(port, 'GET', '/v1/queue');
      assert.equal(list.body.entries.length, 1);
      const none = await request(port, 'POST', '/v1/queue/process');
      assert.deepEqual(none.body, { job: null });
      assert.deepEqual(lastCall(), { method: 'processQueue', args: [{ force: false }] });
      const forced = await request(port, 'POST', '/v1/queue/process', { body: { force: true } });
      assert.equal(forced.body.job.id, 'job-processed');
      assert.deepEqual(lastCall(), { method: 'processQueue', args: [{ force: true }] });
    });
    it('POST /v1/notes returns 201 with AddNoteResult', async () => {
      const body = {
        title: 'Gyokuro at 60 °C',
        text: 'Steep 2 min.',
        images: [{ path: '/tmp/card.png', mode: 'extract' }, { path: '/tmp/setup.jpg' }],
        source: 'in-person',
        sourceRef: 'with Mei',
      };
      const res = await request(port, 'POST', '/v1/notes', { body });
      assert.equal(res.status, 201);
      assert.match(res.body.notePath, /gyokuro/);
      assert.deepEqual(lastCall()?.args[0], { ...body, images: [{ path: '/tmp/card.png', mode: 'extract' }, { path: '/tmp/setup.jpg', mode: 'keep' }] });
      const noText = await request(port, 'POST', '/v1/notes', { body: { title: 't', text: '' } });
      assert.equal(noText.status, 400);
    });
    it('jobs list and detail, 404 for unknown id', async () => {
      const list = await request(port, 'GET', '/v1/jobs');
      assert.equal(list.body.jobs.length, 1);
      const id = list.body.jobs[0].id as string;
      const one = await request(port, 'GET', `/v1/jobs/${id}`);
      assert.equal(one.body.id, id);
      const missing = await request(port, 'GET', '/v1/jobs/job-missing');
      assert.equal(missing.status, 404);
      assert.equal(missing.body.error.code, 'job_not_found');
    });
    it('job review actions map to core calls', async () => {
      const id = core.jobs[0]!.id;
      const cases: [string, unknown, unknown[]][] = [
        ['approve', undefined, [id]],
        ['reply', { text: 'use the tea folder' }, [id, 'use the tea folder']],
        ['allow', { rules: ['Bash(ls:*)'] }, [id, ['Bash(ls:*)']]],
        ['reject', undefined, [id]],
        ['cancel', {}, [id]],
      ];
      for (const [action, body, args] of cases) {
        const res = await request(port, 'POST', `/v1/jobs/${id}/${action}`, { body });
        assert.equal(res.status, 200, action);
        assert.equal(res.body.job.id, id);
        assert.deepEqual(callsOf(action).at(-1)?.args, args, action);
      }
      const before = core.calls.length;
      const missing = await request(port, 'POST', '/v1/jobs/job-missing/approve');
      assert.equal(missing.status, 404);
      assert.equal(core.calls.slice(before).some((c) => c.method === 'approve'), false);
      const noText = await request(port, 'POST', `/v1/jobs/${id}/reply`, { body: {} });
      assert.equal(noText.status, 400);
    });
    it('POST /v1/ask passes filters and selection', async () => {
      const body = {
        question: 'How hot for sencha?',
        labels: ['tea'],
        sources: ['slack'],
        selection: { runnerID: 'claude-code', model: 'opus', effort: 'high' },
        conversationID: 'conv-9',
      };
      const res = await request(port, 'POST', '/v1/ask', { body });
      assert.equal(res.status, 200);
      assert.equal(res.body.conversationID, 'conv-9');
      assert.deepEqual(lastCall(), { method: 'ask', args: [body] });
    });
  });

  it('GET /v1/events streams CoreEvents with keep-alive, and unsubscribes on close', async () => {
    const received = await new Promise<string>((resolve, reject) => {
      const req = http.request(
        { host: '127.0.0.1', port, path: '/v1/events', headers: { authorization: `Bearer ${TOKEN}` } },
        (res) => {
          assert.equal(res.statusCode, 200);
          assert.match(String(res.headers['content-type']), /text\/event-stream/);
          let text = '';
          let emitted = false;
          res.on('data', (c: Buffer) => {
            text += c.toString('utf8');
            if (!emitted && text.includes(': connected')) {
              emitted = true;
              core.emit({ type: 'log', level: 'info', message: 'hello' });
            }
            if (text.includes('event: log') && text.includes(': keep-alive')) {
              req.destroy();
              resolve(text);
            }
          });
        },
      );
      req.on('error', (e) => ((e as NodeJS.ErrnoException).code === 'ECONNRESET' ? undefined : reject(e)));
      req.end();
    });
    assert.match(received, /event: log\ndata: \{"type":"log","level":"info","message":"hello"\}\n\n/);
    for (let i = 0; i < 50 && core.listenerCount() > 0; i++) await new Promise((r) => setTimeout(r, 10));
    assert.equal(core.listenerCount(), 0);
  });

  it('close() ends open event streams', async () => {
    const s = await startServer({ core, token: TOKEN, keepAliveMs: 1000 });
    await new Promise<void>((resolve, reject) => {
      const req = http.request({ host: '127.0.0.1', port: s.port, path: '/v1/events', headers: { authorization: `Bearer ${TOKEN}` } }, (res) => {
        res.once('data', () => void s.close());
        res.on('end', () => resolve());
        res.resume();
      });
      req.on('error', reject);
      req.end();
    });
  });
});
