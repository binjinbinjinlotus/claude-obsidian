import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, it } from 'node:test';
import { CoreError, type CoreEvent } from '../contracts.js';
import { createFakeCore, sampleConversation, sampleJob, type FakeCore } from './fake-core.js';
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
    // Node sends a GET/DELETE body unframed unless the length is given.
    if (payload !== undefined && (method === 'DELETE' || method === 'GET') && !('content-length' in headers)) {
      headers['content-length'] = String(Buffer.byteLength(payload));
    }
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
    it('413 for an oversized chunked body (no Content-Length)', async () => {
      const res = await new Promise<Res>((resolve, reject) => {
        const req = http.request(
          {
            host: '127.0.0.1',
            port,
            method: 'POST',
            path: '/v1/ask',
            headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json', 'transfer-encoding': 'chunked' },
          },
          (r) => {
            let text = '';
            r.on('data', (c: Buffer) => (text += c));
            r.on('end', () => resolve({ status: r.statusCode ?? 0, headers: r.headers, body: JSON.parse(text) }));
          },
        );
        req.on('error', reject);
        for (let i = 0; i < 4; i++) req.write('x'.repeat(2048));
        req.end();
      });
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
    it('POST /v1/batches/reread: files or jobId (not both), perBatch, vault; 201 with the groups', async () => {
      const ok = await request(port, 'POST', '/v1/batches/reread', { body: { files: ['inbox/a.md', 'inbox/b.md'], perBatch: 1, vault: '/tmp/vault', instruction: 'x' } });
      assert.equal(ok.status, 201);
      assert.deepEqual(lastCall()?.args, [{ files: ['inbox/a.md', 'inbox/b.md'], vaultPath: '/tmp/vault', perBatch: 1, instruction: 'x' }]);
      assert.equal(ok.body.groups.length, 2);
      assert.equal(ok.body.started[0].reread.group, 1);
      for (const body of [{}, { files: ['inbox/a.md'], jobId: 'job-20261001-120000-abcd' }, { files: 'inbox/a.md' }, { files: ['inbox/a.md'], perBatch: 1.5 }, { jobId: '' }]) {
        const bad = await request(port, 'POST', '/v1/batches/reread', { body });
        assert.equal(bad.status, 400, JSON.stringify(body));
      }
      const gone = await request(port, 'POST', '/v1/batches/reread', { body: { jobId: 'job-nope' } });
      assert.equal(gone.status, 404);
    });
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
    it('POST /v1/queue/scan: Refresh (manual by default) and the window-active scan; a bad trigger is 400', async () => {
      const scan = await request(port, 'POST', '/v1/queue/scan');
      assert.equal(scan.status, 200);
      assert.deepEqual([scan.body.added, scan.body.removed, scan.body.changed, scan.body.trigger], [0, 0, 0, 'manual']);
      assert.ok(Array.isArray(scan.body.entries) && typeof scan.body.checkedAt === 'string');
      assert.deepEqual(lastCall(), { method: 'scanQueue', args: [{}] });
      const win = await request(port, 'POST', '/v1/queue/scan', { body: { trigger: 'window' } });
      assert.equal(win.body.trigger, 'window');
      assert.deepEqual(lastCall(), { method: 'scanQueue', args: [{ trigger: 'window' }] });
      assert.equal((await request(port, 'POST', '/v1/queue/scan', { body: { trigger: 'periodic' } })).status, 400);
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

  describe('v2 routes', () => {
    it('POST /v1/notes passes labels, suggest and origin, and validates them', async () => {
      const body = { title: 'L', text: 'x', labels: ['#tea', ' green ', 'tea'], suggest: 'none', origin: 'cli' };
      const res = await request(port, 'POST', '/v1/notes', { body });
      assert.equal(res.status, 201);
      assert.deepEqual(lastCall()?.args[0], { title: 'L', text: 'x', labels: ['tea', 'green'], suggest: 'none', origin: 'cli' });
      const wait = await request(port, 'POST', '/v1/notes', { body: { title: 'W', text: 'x', suggest: 'wait', origin: 'cli' } });
      assert.equal(wait.status, 201);
      assert.match(wait.body.requestID, /^req-\d+$/);
      assert.deepEqual(wait.body.suggestedLabels, [
        { name: 'tea', existing: true },
        { name: 'gyokuro', existing: false },
      ]);
      for (const bad of [{ suggest: 'later' }, { origin: 'web' }, { labels: 'tea' }, { labels: [''] }, { labels: ['two words'] }]) {
        const r = await request(port, 'POST', '/v1/notes', { body: { title: 't', text: 'x', ...bad } });
        assert.equal(r.status, 400, JSON.stringify(bad));
        assert.equal(r.body.error.code, 'invalid_request');
      }
    });
    it('POST /v1/notes/:requestID/labels maps to labelNote (200, not 201)', async () => {
      const added = await request(port, 'POST', '/v1/notes', { body: { title: 'Lab', text: 'x' } });
      const id = added.body.requestID as string;
      const res = await request(port, 'POST', `/v1/notes/${encodeURIComponent(id)}/labels`, { body: { labels: ['tea', '#gyokuro'] } });
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { notePath: added.body.notePath, labels: ['tea', 'gyokuro'] });
      assert.deepEqual(lastCall(), { method: 'labelNote', args: [id, ['tea', 'gyokuro']] });
      const missing = await request(port, 'POST', '/v1/notes/req-nope/labels', { body: { labels: ['tea'] } });
      assert.equal(missing.status, 404);
      assert.equal(missing.body.error.code, 'not_found');
      const noLabels = await request(port, 'POST', `/v1/notes/${id}/labels`, { body: {} });
      assert.equal(noLabels.status, 400);
      core.failNext('labelNote', new Error('the batch already picked this note up'));
      const late = await request(port, 'POST', `/v1/notes/${id}/labels`, { body: { labels: ['tea'] } });
      assert.equal(late.status, 409);
      assert.equal(late.body.error.code, 'invalid_state');
    });
    it('GET /v1/labels and /v1/labels/review pass ?vault=', async () => {
      const all = await request(port, 'GET', '/v1/labels');
      assert.equal(all.status, 200);
      assert.equal(all.body.labels[0].name, 'tea');
      assert.deepEqual(lastCall(), { method: 'listLabels', args: [undefined] });
      await request(port, 'GET', '/v1/labels?vault=%2Ftmp%2Fother');
      assert.deepEqual(lastCall(), { method: 'listLabels', args: ['/tmp/other'] });
      await request(port, 'GET', '/v1/labels?vault=');
      assert.deepEqual(lastCall(), { method: 'listLabels', args: [undefined] });
      const review = await request(port, 'GET', '/v1/labels/review?vault=/tmp/v2');
      assert.equal(review.status, 200);
      assert.deepEqual(Object.keys(review.body).sort(), ['toReview', 'unlabeled']);
      assert.deepEqual(lastCall(), { method: 'labelReview', args: ['/tmp/v2'] });
    });
    it('GET /v1/pages passes q, ?vault= and limit to searchPages', async () => {
      const res = await request(port, 'GET', '/v1/pages?q=sen');
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { pages: [{ path: 'wiki/sources/sencha.md', title: 'Sencha basics' }] });
      assert.deepEqual(lastCall(), { method: 'searchPages', args: ['sen', {}] });
      await request(port, 'GET', '/v1/pages?q=Kyoto%20tea&vault=%2Ftmp%2Fv&limit=5');
      assert.deepEqual(lastCall(), { method: 'searchPages', args: ['Kyoto tea', { vaultPath: '/tmp/v', limit: 5 }] });
      await request(port, 'GET', '/v1/pages');
      assert.deepEqual(lastCall(), { method: 'searchPages', args: ['', {}] });
      for (const bad of ['abc', '0', '-2', '1.5']) {
        const r = await request(port, 'GET', `/v1/pages?q=x&limit=${bad}`);
        assert.equal(r.status, 400, bad);
        assert.equal(r.body.error.code, 'invalid_request');
      }
    });
    it('POST /v1/labels/suggest and /v1/labels/confirm return {job}', async () => {
      const sel = { runnerID: 'claude-code', model: 'haiku' };
      const sug = await request(port, 'POST', '/v1/labels/suggest', { body: { paths: ['wiki/a.md'], vaultPath: '/tmp/v', selection: sel } });
      assert.equal(sug.status, 200);
      assert.equal(sug.body.job.id, 'job-label-suggest');
      assert.deepEqual(lastCall(), { method: 'suggestLabelsForPages', args: [['wiki/a.md'], { vaultPath: '/tmp/v', selection: sel }] });
      await request(port, 'POST', '/v1/labels/suggest', { body: { paths: ['wiki/b.md'] } });
      assert.deepEqual(lastCall(), { method: 'suggestLabelsForPages', args: [['wiki/b.md'], {}] });
      for (const bad of [{}, { paths: [] }, { paths: ['a'], selection: { model: 'x' } }]) {
        assert.equal((await request(port, 'POST', '/v1/labels/suggest', { body: bad })).status, 400, JSON.stringify(bad));
      }
      const items = [{ path: 'wiki/a.md', labels: ['tea'] }];
      const conf = await request(port, 'POST', '/v1/labels/confirm', { body: { items, vaultPath: '/tmp/v' } });
      assert.equal(conf.status, 200);
      assert.equal(conf.body.job.id, 'job-label-confirm');
      assert.deepEqual(lastCall(), { method: 'confirmLabels', args: [items, '/tmp/v'] });
      await request(port, 'POST', '/v1/labels/confirm', { body: { items } });
      assert.deepEqual(lastCall(), { method: 'confirmLabels', args: [items, undefined] });
      for (const bad of [{}, { items: [] }, { items: [{ path: 'a' }] }, { items: [{ labels: ['x'] }] }]) {
        assert.equal((await request(port, 'POST', '/v1/labels/confirm', { body: bad })).status, 400, JSON.stringify(bad));
      }
    });
    it('conversation routes', async () => {
      const list = await request(port, 'GET', '/v1/conversations');
      assert.equal(list.status, 200);
      assert.equal(list.body.conversations[0].id, 'conv-1');
      assert.equal(list.body.conversations[0].turns, undefined);
      const one = await request(port, 'GET', '/v1/conversations/conv-1');
      assert.equal(one.status, 200);
      assert.equal(one.body.turns.length, 1);
      assert.deepEqual(lastCall(), { method: 'getConversation', args: ['conv-1'] });
      const missing = await request(port, 'GET', '/v1/conversations/conv-x');
      assert.equal(missing.status, 404);
      assert.equal(missing.body.error.code, 'conversation_not_found');
      const pin = await request(port, 'POST', '/v1/conversations/conv-1/pin', { body: { pinned: true } });
      assert.equal(pin.status, 200);
      assert.equal(pin.body.pinned, true);
      assert.deepEqual(lastCall(), { method: 'setConversationPinned', args: ['conv-1', true] });
      assert.equal((await request(port, 'POST', '/v1/conversations/conv-1/pin', { body: { pinned: 'yes' } })).status, 400);
      assert.equal((await request(port, 'POST', '/v1/conversations/conv-1/pin', { body: {} })).status, 400);
      const del = await request(port, 'DELETE', '/v1/conversations/conv-1');
      assert.equal(del.status, 200);
      assert.deepEqual(del.body, { id: 'conv-1', deleted: true });
      assert.deepEqual(lastCall(), { method: 'deleteConversation', args: ['conv-1'] });
      const again = await request(port, 'DELETE', '/v1/conversations/conv-1');
      assert.equal(again.status, 404);
      core.conversations.push(sampleConversation());
    });
    it('GET /v1/runners', async () => {
      const res = await request(port, 'GET', '/v1/runners');
      assert.equal(res.status, 200);
      assert.deepEqual(res.body.runners.map((r: { id: string }) => r.id), ['claude-code', 'openrouter']);
      assert.equal(lastCall()?.method, 'listRunners');
    });
    it('PUT /v1/runners/:id/secrets/:name sets and clears, and never echoes the value', async () => {
      const SECRET = 'sk-LEAK-123';
      const raw = (r: Res) => (typeof r.body === 'string' ? r.body : JSON.stringify(r.body)) + JSON.stringify(r.headers);
      const set = await request(port, 'PUT', '/v1/runners/openrouter/secrets/apiKey', { body: { value: SECRET } });
      assert.equal(set.status, 200);
      assert.deepEqual(set.body, { runnerID: 'openrouter', name: 'apiKey', isSet: true });
      assert.ok(!raw(set).includes(SECRET));
      assert.deepEqual(lastCall(), { method: 'setRunnerSecret', args: ['openrouter', 'apiKey', SECRET] });
      const runners = await request(port, 'GET', '/v1/runners');
      assert.ok(!raw(runners).includes(SECRET));
      assert.equal(runners.body.runners[1].secrets[0].isSet, true);

      const cleared = await request(port, 'PUT', '/v1/runners/openrouter/secrets/apiKey', { body: { value: null } });
      assert.deepEqual(cleared.body, { runnerID: 'openrouter', name: 'apiKey', isSet: false });
      assert.deepEqual(lastCall(), { method: 'setRunnerSecret', args: ['openrouter', 'apiKey', null] });

      for (const bad of [{}, { value: '' }, { value: 42 }, { value: [SECRET] }]) {
        const r = await request(port, 'PUT', '/v1/runners/openrouter/secrets/apiKey', { body: bad });
        assert.equal(r.status, 400, JSON.stringify(bad));
        assert.ok(!raw(r).includes(SECRET));
      }
      const bj = await request(port, 'PUT', '/v1/runners/openrouter/secrets/apiKey', { raw: `{"value":"${SECRET}"` });
      assert.equal(bj.status, 400);
      assert.ok(!raw(bj).includes(SECRET));

      core.failNext('setRunnerSecret', new Error(`keychain rejected ${SECRET} for openrouter`));
      const failed = await request(port, 'PUT', '/v1/runners/openrouter/secrets/apiKey', { body: { value: SECRET } });
      assert.equal(failed.status, 500);
      assert.ok(!raw(failed).includes(SECRET), raw(failed));
      assert.match(failed.body.error.message, /\[redacted\]/);

      const unknown = await request(port, 'PUT', '/v1/runners/nope/secrets/apiKey', { body: { value: SECRET } });
      assert.equal(unknown.status, 404);
      assert.ok(!raw(unknown).includes(SECRET));
      assert.equal((await request(port, 'GET', '/v1/runners/openrouter/secrets/apiKey')).status, 405);
    });
    it('POST /v1/ask passes labelMatch and includeUnconfirmed, and validates them', async () => {
      const body = { question: 'q', labels: ['tea', 'green'], labelMatch: 'all', includeUnconfirmed: false };
      const res = await request(port, 'POST', '/v1/ask', { body });
      assert.equal(res.status, 200);
      assert.deepEqual(lastCall(), { method: 'ask', args: [body] });
      assert.equal((await request(port, 'POST', '/v1/ask', { body: { question: 'q', labelMatch: 'some' } })).status, 400);
      assert.equal((await request(port, 'POST', '/v1/ask', { body: { question: 'q', includeUnconfirmed: 'no' } })).status, 400);
    });
    it('CoreError not_implemented maps to 501', async () => {
      core.failNext('listLabels', new CoreError('not_implemented', 'listLabels: not implemented'));
      const res = await request(port, 'GET', '/v1/labels');
      assert.equal(res.status, 501);
      assert.deepEqual(res.body, { error: { code: 'not_implemented', message: 'listLabels: not implemented' } });
    });
    it('new routes keep auth and Host/Origin checks', async () => {
      assert.equal((await request(port, 'GET', '/v1/conversations', { auth: false })).status, 401);
      assert.equal((await request(port, 'GET', '/v1/runners', { headers: { origin: 'https://evil.example' } })).status, 403);
      const before = core.calls.length;
      const r = await request(port, 'PUT', '/v1/runners/openrouter/secrets/apiKey', { auth: false, body: { value: 'sk-x' } });
      assert.equal(r.status, 401);
      assert.equal(core.calls.length, before);
    });
  });

  describe('v3 routes', () => {
    const denials = [
      { toolName: 'Bash', input: { command: 'ls /tmp' } },
      { toolName: 'Bash', input: { command: 'cd /x && rm -rf y' } },
      { toolName: 'Read', input: { file_path: '/Users/me/notes/a.md' } },
    ];
    const withDenials = () =>
      sampleJob({
        id: 'job-denied',
        approval: { summary: 's', questions: [], denials: denials.map((d) => ({ ...d })), skipped: [] },
      });
    const rules = (list: { suggestedRule: unknown }[]) => list.map((d) => d.suggestedRule);
    const EXPECTED = ['Bash(ls /tmp)', null, 'Read(//Users/me/notes/a.md)'];

    it('job responses carry suggestedRule on each denial (null when none), without touching the core job', async () => {
      core.jobs.push(withDenials());
      const one = await request(port, 'GET', '/v1/jobs/job-denied');
      assert.equal(one.status, 200);
      assert.deepEqual(rules(one.body.approval.denials), EXPECTED);
      assert.deepEqual(one.body.approval.denials[0].input, { command: 'ls /tmp' });
      const list = await request(port, 'GET', '/v1/jobs');
      const listed = list.body.jobs.find((j: { id: string }) => j.id === 'job-denied');
      assert.deepEqual(rules(listed.approval.denials), EXPECTED);
      const acted = await request(port, 'POST', '/v1/jobs/job-denied/reject');
      assert.deepEqual(rules(acted.body.job.approval.denials), EXPECTED);
      assert.ok(!('suggestedRule' in core.jobs.find((j) => j.id === 'job-denied')!.approval!.denials[0]!), 'core job unchanged');
      core.jobs = core.jobs.filter((j) => j.id !== 'job-denied');
    });

    it('POST /v1/conversations/:id/cancel calls cancelAsk', async () => {
      const res = await request(port, 'POST', '/v1/conversations/conv-9/cancel');
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { id: 'conv-9', cancelled: true });
      assert.deepEqual(lastCall(), { method: 'cancelAsk', args: ['conv-9'] });
    });

    it('POST /v1/ask passes a client-chosen conversationID; a Stopped turn is 409', async () => {
      const ok = await request(port, 'POST', '/v1/ask', { body: { question: 'q', conversationID: 'new-chat-1' } });
      assert.equal(ok.status, 200);
      assert.equal(ok.body.conversationID, 'new-chat-1');
      core.failNext('ask', new CoreError('invalid_state', 'Stopped'));
      const stopped = await request(port, 'POST', '/v1/ask', { body: { question: 'q', conversationID: 'new-chat-1' } });
      assert.equal(stopped.status, 409);
      assert.deepEqual(stopped.body, { error: { code: 'invalid_state', message: 'Stopped' } });
    });

    it('GET /v1/progress lists in-flight progress', async () => {
      core.progress = [
        { key: 'ask:c1', kind: 'ask', message: 'Reading your notes', startedAt: '2026-10-01T12:00:00Z', runnerID: 'claude-code', model: 'haiku' },
      ];
      const res = await request(port, 'GET', '/v1/progress');
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { progress: core.progress });
      core.progress = [];
    });

    it('DELETE /v1/jobs/:id deletes finished jobs; 409 otherwise; 404 unknown', async () => {
      core.jobs.push(sampleJob({ id: 'job-done', state: 'completed' }), sampleJob({ id: 'job-busy', state: 'running' }));
      const ok = await request(port, 'DELETE', '/v1/jobs/job-done');
      assert.equal(ok.status, 200);
      assert.deepEqual(ok.body, { id: 'job-done', deleted: true });
      assert.equal(core.getJob('job-done'), undefined);
      const busy = await request(port, 'DELETE', '/v1/jobs/job-busy');
      assert.equal(busy.status, 409);
      assert.equal(busy.body.error.code, 'invalid_state');
      const missing = await request(port, 'DELETE', '/v1/jobs/job-nope');
      assert.equal(missing.status, 404);
      core.jobs = core.jobs.filter((j) => j.id !== 'job-busy');
    });

    it('GET /v1/jobs/:id/resume returns argv, 404 when the job has no session', async () => {
      core.jobs.push(sampleJob({ id: 'job-labels', kind: 'labels', state: 'completed' }));
      const ok = await request(port, 'GET', '/v1/jobs/job-20261001-120000-abcd/resume');
      assert.equal(ok.status, 200);
      assert.deepEqual(ok.body, { argv: ['claude', '--resume', '00000000-0000-0000-0000-000000000001', '--model', 'sonnet'] });
      const none = await request(port, 'GET', '/v1/jobs/job-labels/resume');
      assert.equal(none.status, 404);
      assert.equal(none.body.error.code, 'no_resume_command');
      assert.equal((await request(port, 'GET', '/v1/jobs/job-nope/resume')).status, 404);
      core.jobs = core.jobs.filter((j) => j.id !== 'job-labels');
    });

    it('DELETE /v1/queue/entries trashes an entry; path is required; outside the queue is 400', async () => {
      const target = '/tmp/vault/queue/remove-me.md';
      core.queue.push({ path: target, name: 'remove-me.md', modified: '2026-10-01T12:00:00Z', size: 1, settled: true });
      const ok = await request(port, 'DELETE', '/v1/queue/entries', { body: { path: target } });
      assert.equal(ok.status, 200, JSON.stringify(ok.body));
      assert.ok(Array.isArray(ok.body.entries));
      assert.ok(!ok.body.entries.some((e: { path: string }) => e.path === target));
      assert.deepEqual(lastCall(), { method: 'removeQueueEntry', args: [target] });
      assert.equal((await request(port, 'DELETE', '/v1/queue/entries', { body: {} })).status, 400);
      const outside = await request(port, 'DELETE', '/v1/queue/entries', { body: { path: '/etc/hosts' } });
      assert.equal(outside.status, 400);
      assert.equal(outside.body.error.code, 'invalid_request');
    });

    it('extras missing from a core are 501', async () => {
      const bare = createFakeCore();
      const { deleteJob: _d, jobResumeCommand: _j, removeQueueEntry: _r, ...rest } = bare;
      const s = await startServer({ core: rest, token: TOKEN });
      try {
        const res = await request(s.port, 'DELETE', '/v1/jobs/job-20261001-120000-abcd');
        assert.equal(res.status, 501);
        assert.equal(res.body.error.code, 'not_implemented');
      } finally {
        await s.close();
      }
    });

    it('POST /v1/images/extract passes the request and returns { text, model }', async () => {
      const res = await request(port, 'POST', '/v1/images/extract', { body: { imagePath: '/tmp/card.png', vaultPath: '/tmp/vault' } });
      assert.equal(res.status, 200);
      assert.deepEqual(res.body, { text: '', model: 'Haiku' });
      assert.deepEqual(lastCall()?.args[0], { imagePath: '/tmp/card.png', vaultPath: '/tmp/vault' });
      const missing = await request(port, 'POST', '/v1/images/extract', { body: {} });
      assert.equal(missing.status, 400);
      core.failNext('extractImageText', new CoreError('invalid_request', 'Image not found: /x.png'));
      const bad = await request(port, 'POST', '/v1/images/extract', { body: { imagePath: '/x.png' } });
      assert.equal(bad.status, 400);
      assert.equal(bad.body.error.message, 'Image not found: /x.png');
      core.failNext('extractImageText', new Error('Claude Code isn’t signed in.'));
      const failed = await request(port, 'POST', '/v1/images/extract', { body: { imagePath: '/x.png' } });
      assert.equal(failed.status, 400);
      assert.equal(failed.body.error.message, 'Claude Code isn’t signed in.');
    });

    it('closing the extract request aborts the reading', async () => {
      let aborted!: () => void;
      const wasAborted = new Promise<void>((r) => (aborted = r));
      let started!: () => void;
      const didStart = new Promise<void>((r) => (started = r));
      const base = createFakeCore();
      const s = await startServer({
        core: {
          ...base,
          extractImageText: (_req, opts) =>
            new Promise((_resolve, reject) => {
              started();
              opts?.signal?.addEventListener('abort', () => {
                aborted();
                reject(new Error('Cancelled.'));
              });
            }),
        },
        token: TOKEN,
      });
      try {
        const req = http.request({
          host: '127.0.0.1', port: s.port, method: 'POST', path: '/v1/images/extract',
          headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
        });
        req.on('error', () => {});
        req.end(JSON.stringify({ imagePath: '/tmp/card.png' }));
        await didStart;
        req.destroy();
        await wasAborted;
      } finally {
        await s.close();
      }
    });

    it('GET /v1/events forwards progress, and job events carry suggestedRule', async () => {
      const progress: CoreEvent = {
        type: 'progress',
        progress: {
          key: 'job-1',
          kind: 'batch',
          message: 'Reading 3 sources into vault',
          steps: ['Moved to inbox', 'Read sources'],
          stepIndex: 1,
          startedAt: '2026-10-01T12:00:00Z',
        },
      };
      const job: CoreEvent = { type: 'job', job: withDenials() };
      const received = await new Promise<string>((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port, path: '/v1/events', headers: { authorization: `Bearer ${TOKEN}` } }, (res) => {
          let text = '';
          let emitted = false;
          res.on('data', (c: Buffer) => {
            text += c.toString('utf8');
            if (!emitted && text.includes(': connected')) {
              emitted = true;
              core.emit(progress);
              core.emit(job);
            }
            if (text.includes('event: progress') && text.includes('event: job')) {
              req.destroy();
              resolve(text);
            }
          });
        });
        req.on('error', (e) => ((e as NodeJS.ErrnoException).code === 'ECONNRESET' ? undefined : reject(e)));
        req.end();
      });
      assert.ok(received.includes(`event: progress\ndata: ${JSON.stringify(progress)}\n\n`));
      const line = received.split('\n').find((l) => l.startsWith('data: {"type":"job"'))!;
      const sent = JSON.parse(line.slice('data: '.length));
      assert.deepEqual(rules(sent.job.approval.denials), EXPECTED);
    });
  });

  it('GET /v1/events forwards labelSuggestions and conversation events', async () => {
    const { turns: _t, ...summary } = sampleConversation();
    const events: CoreEvent[] = [
      { type: 'labelSuggestions', requestID: 'req-9', notePath: '/tmp/vault/inbox/a.md', labels: [{ name: 'tea', existing: true }] },
      { type: 'conversation', conversation: summary, deleted: true },
    ];
    const received = await new Promise<string>((resolve, reject) => {
      const req = http.request({ host: '127.0.0.1', port, path: '/v1/events', headers: { authorization: `Bearer ${TOKEN}` } }, (res) => {
        let text = '';
        let emitted = false;
        res.on('data', (c: Buffer) => {
          text += c.toString('utf8');
          if (!emitted && text.includes(': connected')) {
            emitted = true;
            for (const e of events) core.emit(e);
          }
          if (text.includes('event: labelSuggestions') && text.includes('event: conversation')) {
            req.destroy();
            resolve(text);
          }
        });
      });
      req.on('error', (e) => ((e as NodeJS.ErrnoException).code === 'ECONNRESET' ? undefined : reject(e)));
      req.end();
    });
    assert.ok(received.includes(`event: labelSuggestions\ndata: ${JSON.stringify(events[0])}\n\n`));
    assert.ok(received.includes(`event: conversation\ndata: ${JSON.stringify(events[1])}\n\n`));
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
