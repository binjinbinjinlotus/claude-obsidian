/**
 * The HTTP API's request checks, one rule at a time: bad bodies and queries get a 400 with a plain message
 * and never reach the core; good ones reach it in the shape the core expects (defaults filled, junk dropped).
 */
import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, it } from 'node:test';
import { CoreError } from '../contracts.js';
import { createFakeCore, sampleCollector, type FakeCore } from './fake-core.js';
import { startServer, type RunningServer } from './http.js';

const TOKEN = 'b'.repeat(64);

interface Res {
  status: number;
  headers: http.IncomingHttpHeaders;
  body: any; // eslint-disable-line @typescript-eslint/no-explicit-any
}

function request(port: number, method: string, path: string, opts: { headers?: Record<string, string>; body?: unknown; raw?: string } = {}): Promise<Res> {
  return new Promise((resolve, reject) => {
    const payload = opts.raw ?? (opts.body === undefined ? undefined : JSON.stringify(opts.body));
    const headers: Record<string, string> = { ...(opts.headers ?? {}) };
    if (!('authorization' in headers)) headers.authorization = `Bearer ${TOKEN}`;
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

describe('HTTP request checks', () => {
  let core: FakeCore;
  let server: RunningServer;
  let port: number;

  before(async () => {
    core = createFakeCore();
    core.collectors.push(sampleCollector({ id: 'col-s', kind: 'script', folder: undefined, script: { source: { inline: 'print hi' }, interpreter: 'zsh', timeoutSeconds: 300 } } as never));
    server = await startServer({ core, token: TOKEN, port: 0, keepAliveMs: 50 });
    port = server.port;
  });
  after(() => server.close());

  const send = (method: string, path: string, body?: unknown) => request(port, method, path, body === undefined ? {} : { body });
  /** The args of the last call to `method`, or undefined when it was never called. */
  const argsOf = (method: string) => core.calls.filter((c) => c.method === method).at(-1)?.args;
  const callCount = (method: string) => core.calls.filter((c) => c.method === method).length;

  /** A 400 invalid_request with exactly this message, and the core never called. */
  async function rejects(method: string, path: string, body: unknown, message: string, coreMethod?: string) {
    const before = coreMethod ? callCount(coreMethod) : 0;
    const res = await send(method, path, body);
    assert.equal(res.status, 400, `${path} ${JSON.stringify(body)} → ${JSON.stringify(res.body)}`);
    assert.equal(res.body.error.code, 'invalid_request');
    assert.equal(res.body.error.message, message);
    if (coreMethod) assert.equal(callCount(coreMethod), before, `${coreMethod} must not be called`);
  }
  async function ok(method: string, path: string, body?: unknown, status = 200) {
    const res = await send(method, path, body);
    assert.equal(res.status, status, `${path} ${JSON.stringify(body)} → ${JSON.stringify(res.body)}`);
    return res;
  }

  describe('Host, Origin and token', () => {
    it('Host names are compared without the port and case', async () => {
      for (const host of ['LOCALHOST:9', 'localhost', '[::1]', '[::1]:9']) assert.equal((await request(port, 'GET', '/v1/status', { headers: { host } })).status, 200, host);
      for (const host of ['[::1', 'localhost.evil:1', '127.0.0.2', 'evil:localhost']) assert.equal((await request(port, 'GET', '/v1/status', { headers: { host } })).status, 403, host);
    });
    it('Origin must be http(s) on a local host name', async () => {
      for (const origin of ['https://localhost', 'http://[::1]:5', 'http://127.0.0.1:80']) assert.equal((await request(port, 'GET', '/v1/status', { headers: { origin } })).status, 200, origin);
      for (const origin of ['ftp://localhost', 'ws://127.0.0.1', 'http://localhost.evil', 'not a url']) assert.equal((await request(port, 'GET', '/v1/status', { headers: { origin } })).status, 403, origin);
    });
    it('the bearer scheme is case-insensitive and trailing space is allowed; other schemes are not', async () => {
      assert.equal((await request(port, 'GET', '/v1/status', { headers: { authorization: `bearer ${TOKEN}  ` } })).status, 200);
      assert.equal((await request(port, 'GET', '/v1/status', { headers: { authorization: `Bearer   ${TOKEN}` } })).status, 200, 'several spaces');
      for (const authorization of [`Basic ${TOKEN}`, `Bearer`, `Bearer ${TOKEN} extra`, TOKEN, `xBearer ${TOKEN}`]) {
        assert.equal((await request(port, 'GET', '/v1/status', { headers: { authorization } })).status, 401, authorization);
      }
    });
  });

  describe('bodies', () => {
    it('a route that needs a body rejects none, a list, null and a string', async () => {
      for (const body of [undefined, [], null, 'x', 3]) await rejects('POST', '/v1/ask', body, 'request body must be a JSON object', 'ask');
      // Not a missing-field error: an empty body is not an object.
      for (const [method, path, coreMethod] of [
        ['POST', '/v1/notes', 'addNote'], ['POST', '/v1/actions', 'createAction'], ['PATCH', '/v1/actions/act-1', 'updateAction'],
        ['POST', '/v1/collectors', 'createCollector'], ['PATCH', '/v1/collectors/col-1', 'updateCollector'], ['PUT', '/v1/collectors/col-s/script', 'writeCollectorScript'],
      ] as const) {
        await rejects(method, path, undefined, 'request body must be a JSON object', coreMethod);
      }
    });
    it('a route that allows an empty body takes none', async () => {
      await ok('POST', '/v1/queue/scan');
      assert.deepEqual(argsOf('scanQueue'), [{}]);
      await ok('POST', '/v1/collectors/col-1/install');
      assert.deepEqual(argsOf('installCollectorPackages'), ['col-1', undefined]);
      await ok('POST', '/v1/collectors/col-1/install', { clean: true });
      assert.deepEqual(argsOf('installCollectorPackages'), ['col-1', { clean: true }]);
      await rejects('POST', '/v1/collectors/col-1/install', { clean: 'yes' }, '"clean" must be a boolean');
    });
  });

  describe('POST /v1/ask', () => {
    it('question is required and must be text', async () => {
      await rejects('POST', '/v1/ask', {}, '"question" is required', 'ask');
      await rejects('POST', '/v1/ask', { question: '   ' }, '"question" is required', 'ask');
      await rejects('POST', '/v1/ask', { question: 5 }, '"question" must be a string', 'ask');
    });
    it('each optional field is type-checked', async () => {
      await rejects('POST', '/v1/ask', { question: 'q', conversationID: 1 }, '"conversationID" must be a string', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', labels: ['a', 1] }, '"labels" must be an array of strings', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', sources: 'web' }, '"sources" must be an array of strings', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', labelMatch: 'some' }, '"labelMatch" must be one of "any", "all"', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', includeUnconfirmed: 'yes' }, '"includeUnconfirmed" must be a boolean', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', newSession: 1 }, '"newSession" must be a boolean', 'ask');
    });
    it('selection needs runnerID and model; effort may be null', async () => {
      await rejects('POST', '/v1/ask', { question: 'q', selection: 'opus' }, 'request body must be a JSON object', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', selection: { model: 'm' } }, '"runnerID" is required', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', selection: { runnerID: 'r', model: '' } }, '"model" is required', 'ask');
      await rejects('POST', '/v1/ask', { question: 'q', selection: { runnerID: 'r', model: 'm', effort: 3 } }, '"effort" must be a string', 'ask');
      await ok('POST', '/v1/ask', { question: 'q', selection: { runnerID: 'r', model: 'm', effort: null } });
      assert.deepEqual(argsOf('ask'), [{ question: 'q', selection: { runnerID: 'r', model: 'm', effort: null } }]);
      await ok('POST', '/v1/ask', { question: 'q', selection: { runnerID: 'r', model: 'm' } });
      assert.deepEqual(argsOf('ask'), [{ question: 'q', selection: { runnerID: 'r', model: 'm' } }]);
    });
    it('passes what was given; empty strings, null and newSession false are left out', async () => {
      await ok('POST', '/v1/ask', { question: 'q', conversationID: null, vaultPath: '', selection: null, labels: null, newSession: false, includeUnconfirmed: null });
      assert.deepEqual(argsOf('ask'), [{ question: 'q' }]);
      await ok('POST', '/v1/ask', { question: 'q', conversationID: 'c', vaultPath: '/v', labels: [], sources: ['s'], labelMatch: 'all', includeUnconfirmed: false, newSession: true });
      assert.deepEqual(argsOf('ask'), [{ question: 'q', conversationID: 'c', vaultPath: '/v', labels: [], sources: ['s'], labelMatch: 'all', includeUnconfirmed: false, newSession: true }]);
    });
  });

  describe('POST /v1/notes', () => {
    it('title is required; text may be empty only with an image', async () => {
      await rejects('POST', '/v1/notes', { text: 'x' }, '"title" is required', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T' }, '"text" is required', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: '  ' }, 'a note needs "text" or at least one image', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: '', images: [] }, 'a note needs "text" or at least one image', 'addNote');
      await ok('POST', '/v1/notes', { title: 'T', text: '', images: [{ path: '/i.png' }] }, 201);
      assert.deepEqual(argsOf('addNote'), [{ title: 'T', text: '', images: [{ path: '/i.png', mode: 'keep' }] }]);
    });
    it('images: a list of {path, mode keep|extract}', async () => {
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', images: '/i.png' }, '"images" must be an array', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', images: ['/i.png'] }, 'request body must be a JSON object', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', images: [{ path: '/i.png', mode: 'ocr' }] }, 'image "mode" must be "keep" or "extract"', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', images: [{ mode: 'extract' }] }, '"path" is required', 'addNote');
      await ok('POST', '/v1/notes', { title: 'T', text: 'x', images: null }, 201);
      assert.deepEqual(argsOf('addNote'), [{ title: 'T', text: 'x' }]);
      await ok('POST', '/v1/notes', { title: 'T', text: 'x', images: [{ path: '/i.png', mode: 'extract' }] }, 201);
      assert.deepEqual((argsOf('addNote')![0] as { images: unknown }).images, [{ path: '/i.png', mode: 'extract' }]);
    });
    it('labels: "#" and spaces trimmed, duplicates dropped, empty or spaced names rejected', async () => {
      await ok('POST', '/v1/notes', { title: 'T', text: 'x', labels: ['#tea', ' tea ', '# green ', 'Tea', ' #oolong', 'c#'] }, 201);
      assert.deepEqual((argsOf('addNote')![0] as { labels: unknown }).labels, ['tea', 'green', 'Tea', 'oolong', 'c#']);
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', labels: ['#'] }, '"labels" must not contain empty labels', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', labels: ['  '] }, '"labels" must not contain empty labels', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', labels: ['green tea'] }, 'label "green tea" must not contain spaces', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', labels: 'tea' }, '"labels" must be an array of strings', 'addNote');
    });
    it('suggest and origin are enums; empty source fields are left out', async () => {
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', suggest: 'now' }, '"suggest" must be one of "wait", "background", "none"', 'addNote');
      await rejects('POST', '/v1/notes', { title: 'T', text: 'x', origin: 'web' }, '"origin" must be one of "app", "cli"', 'addNote');
      await ok('POST', '/v1/notes', { title: 'T', text: 'x', source: '', sourceRef: '', vaultPath: '' }, 201);
      assert.deepEqual(argsOf('addNote'), [{ title: 'T', text: 'x' }]);
      await ok('POST', '/v1/notes', { title: 'T', text: 'x', source: 'slack', sourceRef: 'ref', vaultPath: '/v', suggest: 'none', origin: 'cli' }, 201);
      assert.deepEqual(argsOf('addNote'), [{ title: 'T', text: 'x', source: 'slack', sourceRef: 'ref', vaultPath: '/v', suggest: 'none', origin: 'cli' }]);
    });
  });

  describe('labels', () => {
    it('POST /v1/notes/:id/labels needs a list of labels', async () => {
      await rejects('POST', '/v1/notes/req-x/labels', {}, '"labels" must be an array of strings', 'labelNote');
      const res = await send('POST', '/v1/notes/req-x/labels', { labels: ['tea'] });
      assert.equal(res.status, 404, 'a core not_found is a 404');
    });
    it('POST /v1/labels/suggest needs non-empty paths', async () => {
      for (const paths of [undefined, [], ['a.md', ' ']]) {
        await rejects('POST', '/v1/labels/suggest', { paths }, '"paths" must be a non-empty array of non-empty strings', 'suggestLabelsForPages');
      }
      await ok('POST', '/v1/labels/suggest', { paths: ['a.md'], vaultPath: '/v', selection: { runnerID: 'r', model: 'm' } });
      assert.deepEqual(argsOf('suggestLabelsForPages'), [['a.md'], { vaultPath: '/v', selection: { runnerID: 'r', model: 'm' } }]);
      await ok('POST', '/v1/labels/suggest', { paths: ['a.md'] });
      assert.deepEqual(argsOf('suggestLabelsForPages'), [['a.md'], {}]);
    });
    it('POST /v1/labels/confirm needs items with a path and labels', async () => {
      for (const items of [undefined, [], 'x']) {
        await rejects('POST', '/v1/labels/confirm', { items }, '"items" must be a non-empty array of {path, labels}', 'confirmLabels');
      }
      await rejects('POST', '/v1/labels/confirm', { items: [{ path: 'a.md' }] }, '"labels" must be an array of strings', 'confirmLabels');
      await rejects('POST', '/v1/labels/confirm', { items: [{ labels: [] }] }, '"path" is required', 'confirmLabels');
      await ok('POST', '/v1/labels/confirm', { items: [{ path: 'a.md', labels: ['#tea'] }] });
      assert.deepEqual(argsOf('confirmLabels'), [[{ path: 'a.md', labels: ['tea'] }], undefined]);
      await ok('POST', '/v1/labels/confirm', { items: [{ path: 'a.md', labels: [] }], vaultPath: '/v' });
      assert.deepEqual(argsOf('confirmLabels'), [[{ path: 'a.md', labels: [] }], '/v']);
    });
  });

  describe('actions', () => {
    it('POST /v1/actions: title required, type defaults to todo, body string or null', async () => {
      await rejects('POST', '/v1/actions', { type: 'todo' }, '"title" is required', 'createAction');
      await rejects('POST', '/v1/actions', { title: 'T', body: 3 }, '"body" must be a string or null', 'createAction');
      await ok('POST', '/v1/actions', { title: 'T', body: null, why: '', vaultPath: '' }, 201);
      assert.deepEqual(argsOf('createAction'), [{ type: 'todo', title: 'T', body: null }]);
      await ok('POST', '/v1/actions', { type: 'jira', title: 'T', body: 'b', why: 'w', vaultPath: '/v', labels: ['x'], fields: { a: 'b', c: null } }, 201);
      assert.deepEqual(argsOf('createAction'), [{ type: 'jira', title: 'T', body: 'b', why: 'w', vaultPath: '/v', labels: ['x'], fields: { a: 'b', c: null } }]);
    });
    it('fields: an object of strings or null', async () => {
      await rejects('POST', '/v1/actions', { title: 'T', fields: ['a'] }, '"fields" must be an object of strings', 'createAction');
      await rejects('POST', '/v1/actions', { title: 'T', fields: 'a' }, '"fields" must be an object of strings', 'createAction');
      await rejects('POST', '/v1/actions', { title: 'T', fields: { due: 3 } }, '"fields.due" must be a string or null', 'createAction');
    });
    it('source: manual by default, agent only when said; ask needs a conversation; note keeps its strings', async () => {
      const sourceOf = async (source: unknown) => {
        await ok('POST', '/v1/actions', { title: 'T', source }, 201);
        return (argsOf('createAction')![0] as { source?: unknown }).source;
      };
      assert.equal(await sourceOf(null), undefined);
      assert.deepEqual(await sourceOf({}), { kind: 'manual' });
      assert.deepEqual(await sourceOf({ kind: 'manual', by: 'user' }), { kind: 'manual' });
      assert.deepEqual(await sourceOf({ by: 'agent' }), { kind: 'manual', by: 'agent' });
      await rejects('POST', '/v1/actions', { title: 'T', source: { by: 'bot' } }, '"by" must be one of "user", "agent"', 'createAction');
      await rejects('POST', '/v1/actions', { title: 'T', source: { kind: 'web' } }, '"kind" must be one of "note", "ask", "manual"', 'createAction');
      await rejects('POST', '/v1/actions', { title: 'T', source: { kind: 'ask' } }, '"conversationID" is required', 'createAction');
      assert.deepEqual(await sourceOf({ kind: 'ask', conversationID: 'c', question: '', quote: '', turnIndex: -1, gap: 'yes' }), { kind: 'ask', conversationID: 'c' });
      assert.deepEqual(await sourceOf({ kind: 'ask', conversationID: 'c', turnIndex: 1.5 }), { kind: 'ask', conversationID: 'c' });
      assert.deepEqual(await sourceOf({ kind: 'ask', conversationID: 'c', question: 'q', quote: 'x', citedPaths: ['a.md'], turnIndex: 0, gap: true }), {
        kind: 'ask', conversationID: 'c', question: 'q', quote: 'x', citedPaths: ['a.md'], turnIndex: 0, gap: true,
      });
      assert.deepEqual(await sourceOf({ kind: 'note', jobID: 'j', notePath: 'n.md', pageTitle: '', quote: 'q', extra: 'x' }), { kind: 'note', jobID: 'j', notePath: 'n.md', quote: 'q' });
    });
    it('PATCH /v1/actions/:id: only what was sent', async () => {
      await rejects('PATCH', '/v1/actions/act-1', { body: 1 }, '"body" must be a string or null', 'updateAction');
      await rejects('PATCH', '/v1/actions/act-1', { title: 1 }, '"title" must be a string', 'updateAction');
      await ok('PATCH', '/v1/actions/act-1', {});
      assert.deepEqual(argsOf('updateAction'), ['act-1', {}]);
      await ok('PATCH', '/v1/actions/act-1', { title: '', body: null, type: '', fields: null });
      assert.deepEqual(argsOf('updateAction'), ['act-1', { title: '', body: null }]);
      await ok('PATCH', '/v1/actions/act-1', { title: 'T', body: 'b', type: 'jira', labels: ['l'], fields: { a: 'b' } });
      assert.deepEqual(argsOf('updateAction'), ['act-1', { title: 'T', body: 'b', type: 'jira', labels: ['l'], fields: { a: 'b' } }]);
    });
    it('confirm and dismiss need ids; confirm "as" needs a type', async () => {
      for (const ids of [undefined, [], ['act-1', '  ']]) {
        await rejects('POST', '/v1/actions/confirm', { ids }, '"ids" must be a non-empty array of action ids', 'confirmActions');
        await rejects('POST', '/v1/actions/dismiss', { ids }, '"ids" must be a non-empty array of action ids', 'dismissActions');
      }
      await rejects('POST', '/v1/actions/confirm', { ids: ['act-1'], as: {} }, '"type" is required', 'confirmActions');
      await rejects('POST', '/v1/actions/confirm', { ids: ['act-1'], as: 'jira' }, 'request body must be a JSON object', 'confirmActions');
      await rejects('POST', '/v1/actions/confirm', { ids: ['act-1'], as: { type: 'jira', fields: { a: 1 } } }, '"as.fields.a" must be a string or null', 'confirmActions');
      await rejects('POST', '/v1/actions/confirm', { ids: ['act-1'], as: { type: 'jira', fields: [] } }, 'request body must be a JSON object', 'confirmActions');
      await rejects('POST', '/v1/actions/confirm', { ids: ['act-1'], as: { type: 'jira', body: 2 } }, '"body" must be a string', 'confirmActions');
      await ok('POST', '/v1/actions/confirm', { ids: ['act-1'], as: null });
      assert.deepEqual(argsOf('confirmActions'), [['act-1']]);
      await ok('POST', '/v1/actions/confirm', { ids: ['act-1'], as: { type: 'jira' } });
      assert.deepEqual(argsOf('confirmActions'), [['act-1'], { type: 'jira' }]);
      await ok('POST', '/v1/actions/confirm', { ids: ['act-1'], as: { type: 'jira', body: null, fields: null } });
      assert.deepEqual(argsOf('confirmActions'), [['act-1'], { type: 'jira', body: null }]);
      await ok('POST', '/v1/actions/confirm', { ids: ['act-1'], as: { type: 'jira', title: '', body: '', fields: { a: null, b: 'x' } } });
      assert.deepEqual(argsOf('confirmActions'), [['act-1'], { type: 'jira', title: '', body: '', fields: { a: null, b: 'x' } }]);
    });
    it('GET /v1/actions: status and route are checked; history, vault and q parsed', async () => {
      const query = async (qs: string) => {
        await ok('GET', `/v1/actions${qs}`);
        return argsOf('listActions')![0];
      };
      assert.deepEqual(await query(''), {});
      assert.deepEqual(await query('?type=jira&status=open,%20ready,,&history=1&vault=%2Fv&q=tea&route=waiting'), {
        type: 'jira', status: ['open', 'ready'], history: true, vaultPath: '/v', text: 'tea', route: 'waiting',
      });
      assert.deepEqual(await query('?history=true'), { history: true });
      assert.deepEqual(await query('?history=0'), { history: false });
      assert.deepEqual(await query('?history=&vault=%20&q=%20&type=&status=&route='), { history: false });
      for (const route of ['list', 'others', 'all']) assert.deepEqual(await query(`?route=${route}`), { route });
      await rejects('GET', '/v1/actions?status=open,lost', undefined, 'unknown status "lost"', undefined);
      await rejects('GET', '/v1/actions?route=mine', undefined, 'unknown route "mine"', undefined);
    });
  });

  describe('GET /v1/activity', () => {
    const query = async (qs: string) => {
      await ok('GET', `/v1/activity${qs}`);
      return argsOf('listActivity')![0];
    };
    it('lists, kind, object, dates, text, outcome, limit and cursor', async () => {
      assert.deepEqual(await query(''), {});
      assert.deepEqual(
        await query('?type=collector,%20chat.deleted&source=app,cli&kind=chat&object=%20c1%20&since=2026-10-01&until=2026-10-02T10:00:00%2B02:00&q=%20tea%20&outcome=failed&limit=500&cursor=%20e9%20'),
        {
          types: ['collector', 'chat.deleted'], sources: ['app', 'cli'], objectKind: 'chat', objectID: 'c1', since: '2026-10-01T00:00:00.000Z', until: '2026-10-02T08:00:00.000Z',
          text: 'tea', outcome: 'failed', limit: 500, cursor: 'e9',
        },
      );
      assert.deepEqual(await query('?outcome=ok&limit=1&since=%20&object=%20&q=%20&cursor=%20&kind='), { outcome: 'ok', limit: 1 });
      assert.deepEqual(await query('?limit=%20'), {});
    });
    it('every known source and object kind is accepted', async () => {
      const sources = ['app', 'cli', 'agent', 'scheduler', 'api', 'core'];
      assert.deepEqual(await query(`?source=${sources.join(',')}`), { sources });
      for (const kind of ['chat', 'collector', 'action', 'batch', 'queue', 'note', 'connection', 'settings', 'runner', 'labels', 'core']) {
        assert.deepEqual(await query(`?kind=${kind}`), { objectKind: kind });
      }
    });
    it('bad values are 400s', async () => {
      await rejects('GET', '/v1/activity?source=app,robot', undefined, 'unknown source "robot"');
      await rejects('GET', '/v1/activity?kind=planet', undefined, 'unknown object kind "planet"');
      await rejects('GET', '/v1/activity?since=yesterday', undefined, '"since" must be an ISO-8601 date or time');
      await rejects('GET', '/v1/activity?until=later', undefined, '"until" must be an ISO-8601 date or time');
      await rejects('GET', '/v1/activity?outcome=maybe', undefined, '"outcome" must be "ok" or "failed"');
      for (const limit of ['0', '501', '1.5', 'ten', '-1']) {
        await rejects('GET', `/v1/activity?limit=${limit}`, undefined, 'limit must be an integer from 1 to 500');
      }
    });
  });

  describe('collectors', () => {
    it('POST /v1/collectors: kind is required', async () => {
      await rejects('POST', '/v1/collectors', {}, '"kind" is required ("folder" or "script")', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'email' }, '"kind" must be one of "folder", "script"', 'createCollector');
    });
    it('a folder collector with its options', async () => {
      await ok('POST', '/v1/collectors', { kind: 'folder' }, 201);
      assert.deepEqual(argsOf('createCollector'), [{ kind: 'folder' }]);
      await ok('POST', '/v1/collectors', { kind: 'folder', name: '', vaultPath: '/v', enabled: false, schedule: { cron: '0 * * * *', preset: 'hourly' }, folder: { source: '/in', afterCollect: 'move' } }, 201);
      assert.deepEqual(argsOf('createCollector'), [{ kind: 'folder', name: '', vaultPath: '/v', enabled: false, schedule: { cron: '0 * * * *', preset: 'hourly' }, folder: { source: '/in', afterCollect: 'move' } }]);
      await ok('POST', '/v1/collectors', { kind: 'folder', schedule: null, folder: null, name: null }, 201);
      assert.deepEqual(argsOf('createCollector'), [{ kind: 'folder' }]);
      await ok('POST', '/v1/collectors', { kind: 'folder', schedule: { cron: '* * * * *' }, folder: {} }, 201);
      assert.deepEqual(argsOf('createCollector'), [{ kind: 'folder', schedule: { cron: '* * * * *' }, folder: {} }]);
      await rejects('POST', '/v1/collectors', { kind: 'folder', schedule: {} }, '"cron" is required', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'folder', schedule: { cron: 'x', preset: 'monthly' } }, '"preset" must be one of "every15", "hourly", "daily", "weekdays", "custom"', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'folder', folder: { afterCollect: 'delete' } }, '"afterCollect" must be one of "copy", "move"', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'folder', enabled: 'yes' }, '"enabled" must be a boolean', 'createCollector');
    });
    it('a script collector needs a script with one source and an interpreter', async () => {
      await rejects('POST', '/v1/collectors', { kind: 'script' }, 'a script collector needs "script"', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'script', script: null }, 'a script collector needs "script"', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'script', script: { interpreter: 'zsh' } }, '"script.source" is required', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'script', script: { source: null, interpreter: 'zsh' } }, '"script.source" is required', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'script', script: { source: { inline: 'x' } } }, '"script.interpreter" is required (zsh, python3, node or typescript)', 'createCollector');
      for (const source of [{}, { inline: 'x', file: '/f' }]) {
        await rejects('POST', '/v1/collectors', { kind: 'script', script: { source, interpreter: 'zsh' } }, '"source" must be {"file": path} or {"inline": code}', 'createCollector');
      }
      await rejects('POST', '/v1/collectors', { kind: 'script', script: { source: { inline: 'x' }, interpreter: 'zsh', timeoutSeconds: '60' } }, '"timeoutSeconds" must be a number', 'createCollector');
      await rejects('POST', '/v1/collectors', { kind: 'script', script: { source: { inline: 'x' }, interpreter: 'zsh', collects: 'no' } }, '"collects" must be a boolean', 'createCollector');
      await ok('POST', '/v1/collectors', { kind: 'script', script: { source: { file: '/f.py' }, interpreter: 'python3', timeoutSeconds: 60, manifest: '{}', collects: false } }, 201);
      assert.deepEqual(argsOf('createCollector'), [{ kind: 'script', script: { source: { file: '/f.py' }, interpreter: 'python3', timeoutSeconds: 60, manifest: '{}', collects: false } }]);
      await ok('POST', '/v1/collectors', { kind: 'script', script: { source: { inline: '' }, interpreter: 'typescript', timeoutSeconds: null } }, 201);
      assert.deepEqual(argsOf('createCollector'), [{ kind: 'script', script: { source: { inline: '' }, interpreter: 'typescript' } }]);
    });
    it('an infinite timeout or size (1e999 in JSON) is not a number', async () => {
      for (const [method, path, raw, message] of [
        ['POST', '/v1/collectors', '{"kind":"script","script":{"source":{"inline":"x"},"interpreter":"zsh","timeoutSeconds":1e999}}', '"timeoutSeconds" must be a number'],
        ['PATCH', '/v1/collectors/col-s', '{"script":{"timeoutSeconds":-1e999}}', '"timeoutSeconds" must be a number'],
        ['POST', '/v1/collectors/col-1/collected/restore', `{"files":[{"sha256":"${'a'.repeat(64)}","name":"n","sourcePath":"/s","size":1e999,"mtime":"m","collectedAt":"c"}]}`, 'each file needs a numeric "size"'],
      ] as const) {
        const res = await request(port, method, path, { raw });
        assert.deepEqual([res.status, res.body.error.message], [400, message], path);
      }
    });
    it('PATCH /v1/collectors/:id: only what was sent; commands must be a list', async () => {
      await ok('PATCH', '/v1/collectors/col-1', {});
      assert.deepEqual(argsOf('updateCollector'), ['col-1', {}]);
      await ok('PATCH', '/v1/collectors/col-1', { name: 'N', vaultPath: '/v', enabled: true, schedule: { cron: 'c' }, folder: { source: '/s' } });
      assert.deepEqual(argsOf('updateCollector'), ['col-1', { name: 'N', vaultPath: '/v', enabled: true, schedule: { cron: 'c' }, folder: { source: '/s' } }]);
      await ok('PATCH', '/v1/collectors/col-s', { script: null, schedule: null, folder: null });
      assert.deepEqual(argsOf('updateCollector'), ['col-s', {}]);
      await ok('PATCH', '/v1/collectors/col-s', { script: {} });
      assert.deepEqual(argsOf('updateCollector'), ['col-s', { script: {} }]);
      await ok('PATCH', '/v1/collectors/col-s', { script: { source: { inline: 'y' }, interpreter: 'node', timeoutSeconds: 5, collects: true, commands: [] } });
      assert.deepEqual(argsOf('updateCollector'), ['col-s', { script: { source: { inline: 'y' }, interpreter: 'node', timeoutSeconds: 5, collects: true, commands: [] } }]);
      await rejects('PATCH', '/v1/collectors/col-s', { script: { commands: {} } }, '"commands" must be a list', 'updateCollector');
      await rejects('PATCH', '/v1/collectors/col-s', { script: { collects: 1 } }, '"collects" must be a boolean', 'updateCollector');
      await rejects('PATCH', '/v1/collectors/col-s', { script: { interpreter: 'ruby' } }, '"interpreter" must be one of "zsh", "python3", "node", "typescript"', 'updateCollector');
      await rejects('PATCH', '/v1/collectors/col-s', { script: { timeoutSeconds: 'x' } }, '"timeoutSeconds" must be a number', 'updateCollector');
      await rejects('PATCH', '/v1/collectors/col-s', { script: 'x' }, 'request body must be a JSON object', 'updateCollector');
    });
    it('PUT /v1/collectors/:id/script needs code or a manifest; null manifests are kept', async () => {
      await rejects('PUT', '/v1/collectors/col-s/script', {}, 'send "code" and/or "manifest"', 'writeCollectorScript');
      await rejects('PUT', '/v1/collectors/col-s/script', { baseSha256: 'x' }, 'send "code" and/or "manifest"', 'writeCollectorScript');
      await rejects('PUT', '/v1/collectors/col-s/script', { code: 1 }, '"code" must be a string', 'writeCollectorScript');
      await ok('PUT', '/v1/collectors/col-s/script', { code: 'x' });
      assert.deepEqual(argsOf('writeCollectorScript'), ['col-s', { code: 'x' }]);
      await ok('PUT', '/v1/collectors/col-s/script', { manifest: null, baseManifestSha256: null });
      assert.deepEqual(argsOf('writeCollectorScript'), ['col-s', { manifest: null, baseManifestSha256: null }]);
      await ok('PUT', '/v1/collectors/col-s/script', { code: '', manifest: '{}', baseSha256: 'a', baseManifestSha256: 'b' });
      assert.deepEqual(argsOf('writeCollectorScript'), ['col-s', { code: '', manifest: '{}', baseSha256: 'a', baseManifestSha256: 'b' }]);
    });
    it('POST /v1/collectors/:id/collected/restore checks each file', async () => {
      const file = { sha256: 'a'.repeat(64), name: 'n.md', sourcePath: '/s/n.md', size: 0, mtime: 'm', collectedAt: 'c' };
      await rejects('POST', '/v1/collectors/col-1/collected/restore', { files: 'x' }, '"files" must be an array', 'restoreCollected');
      await rejects('POST', '/v1/collectors/col-1/collected/restore', { files: [{ ...file, size: '1' }] }, 'each file needs a numeric "size"', 'restoreCollected');
      await rejects('POST', '/v1/collectors/col-1/collected/restore', { files: [{ ...file, name: '' }] }, '"name" is required', 'restoreCollected');
      await rejects('POST', '/v1/collectors/col-1/collected/restore', { files: [{ ...file, outcome: 'deleted' }] }, '"outcome" must be one of "copied", "moved"', 'restoreCollected');
      await ok('POST', '/v1/collectors/col-1/collected/restore', { files: [file, { ...file, collectorId: 'col-1', queueName: 'q.md', outcome: 'moved' }] });
      assert.deepEqual(argsOf('restoreCollected'), ['col-1', [{ ...file, collectorId: '', queueName: '', outcome: 'copied' }, { ...file, collectorId: 'col-1', queueName: 'q.md', outcome: 'moved' }]]);
    });
    it('create-folder needs which', async () => {
      await rejects('POST', '/v1/collectors/col-1/create-folder', {}, '"which" must be "source" or "queue"', 'createCollectorFolder');
      await ok('POST', '/v1/collectors/col-1/create-folder', { which: 'queue' });
      assert.deepEqual(argsOf('createCollectorFolder'), ['col-1', 'queue']);
    });
  });

  describe('core errors → status', () => {
    const fail = async (method: string, err: unknown, path = '/v1/ask', body: unknown = { question: 'q' }) => {
      core.failNext(method, err as Error);
      return send('POST', path, body);
    };
    it('a declared 4xx/5xx status wins, with its code or "error"', async () => {
      let res = await fail('ask', Object.assign(new Error('teapot'), { statusCode: 418 }));
      assert.deepEqual([res.status, res.body.error.code, res.body.error.message], [418, 'error', 'teapot']);
      res = await fail('ask', Object.assign(new Error('x'), { status: 599, code: 'odd' }));
      assert.deepEqual([res.status, res.body.error.code], [599, 'odd']);
      res = await fail('ask', Object.assign(new Error('x'), { status: 400 }));
      assert.equal(res.status, 400);
    });
    it('a status outside 400–599 is ignored', async () => {
      for (const status of [200, 399, 600]) {
        const res = await fail('ask', Object.assign(new Error('x'), { status }));
        assert.deepEqual([res.status, res.body.error.code], [500, 'internal_error'], String(status));
      }
      const res = await fail('ask', Object.assign(new Error('x'), { status: '404', code: 'not_found' }));
      assert.equal(res.status, 404, 'a non-number status falls back to the code');
    });
    it('known codes map to their status; unknown codes are 500', async () => {
      const codes: Record<string, number> = {
        not_found: 404, invalid_request: 400, invalid: 400, conflict: 409, busy: 409, invalid_state: 409, no_vault: 409, session_unavailable: 409, not_implemented: 501,
      };
      for (const [code, status] of Object.entries(codes)) {
        const res = await fail('ask', new CoreError(code as never, `m-${code}`));
        assert.deepEqual([res.status, res.body.error.code, res.body.error.message], [status, code, `m-${code}`], code);
      }
      const res = await fail('ask', Object.assign(new Error('x'), { code: 'gremlins' }));
      assert.deepEqual([res.status, res.body.error.code], [500, 'internal_error']);
    });
    it('a plain Error is the route\'s untyped status, else 500; no message reads "internal error"', async () => {
      let res = await fail('addNote', new Error('no vault selected'), '/v1/notes', { title: 'T', text: 'x' });
      assert.deepEqual([res.status, res.body.error.code], [400, 'invalid_request']);
      // A coded error on an untyped route still maps by its code, not the route's default.
      res = await fail('addNote', Object.assign(new Error('x'), { code: 'gremlins' }), '/v1/notes', { title: 'T', text: 'x' });
      assert.deepEqual([res.status, res.body.error.code], [500, 'internal_error']);
      // A thrown non-Error on an untyped route is a 500.
      res = await fail('addNote', { message: 'plain object' }, '/v1/notes', { title: 'T', text: 'x' });
      assert.deepEqual([res.status, res.body.error.code, res.body.error.message], [500, 'internal_error', 'plain object']);
      res = await fail('ask', new Error('boom'));
      assert.deepEqual([res.status, res.body.error.code, res.body.error.message], [500, 'internal_error', 'boom']);
      res = await fail('ask', new Error(''));
      assert.equal(res.body.error.message, 'internal error');
      // A non-string message, a string status or a numeric code are not trusted.
      res = await fail('ask', { message: 5, code: 'not_found' });
      assert.deepEqual([res.status, res.body.error.message], [404, 'internal error']);
      res = await fail('ask', Object.assign(new Error('x'), { status: '404' }));
      assert.deepEqual([res.status, res.body.error.code], [500, 'internal_error']);
      res = await fail('ask', Object.assign(new Error('x'), { statusCode: '418' }));
      assert.deepEqual([res.status, res.body.error.code], [500, 'internal_error']);
      res = await fail('addNote', Object.assign(new Error('x'), { code: 7 }), '/v1/notes', { title: 'T', text: 'x' });
      assert.deepEqual([res.status, res.body.error.code], [400, 'invalid_request']);
      res = await fail('ask', 'a string');
      assert.deepEqual([res.status, res.body.error.message], [500, 'internal error']);
    });
    it('throwing null or undefined is a 500, not a crash', async () => {
      const ask = core.ask;
      try {
        for (const thrown of [null, undefined]) {
          core.ask = async () => {
            throw thrown;
          };
          const res = await send('POST', '/v1/ask', { question: 'q' });
          assert.deepEqual([res.status, res.body.error.code, res.body.error.message], [500, 'internal_error', 'internal error']);
        }
      } finally {
        core.ask = ask;
      }
    });
  });
});
