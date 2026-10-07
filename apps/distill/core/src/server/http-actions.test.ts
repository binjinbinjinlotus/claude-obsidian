import assert from 'node:assert/strict';
import http from 'node:http';
import { after, before, describe, it } from 'node:test';
import { sampleAction, createFakeCore, type FakeCore } from './fake-core.js';
import { startServer, type RunningServer } from './http.js';

const TOKEN = 'b'.repeat(64);

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

describe('HTTP API: actions and connections', () => {
  let core: FakeCore;
  let server: RunningServer;
  let port: number;
  before(async () => {
    core = createFakeCore();
    core.actions.push(sampleAction({ id: 'act-ask', source: { kind: 'ask', conversationID: 'conv-1', quote: 'x' } }));
    server = await startServer({ core, token: TOKEN, port: 0 });
    port = server.port;
  });
  after(() => server.close());
  const last = (m: string) => core.calls.filter((c) => c.method === m).at(-1);

  it('GET /v1/action-types and /v1/actions with filters', async () => {
    const types = await request(port, 'GET', '/v1/action-types');
    assert.equal(types.status, 200);
    assert.deepEqual(types.body.types.map((t: { id: string }) => t.id), ['todo', 'slack']);
    const list = await request(port, 'GET', '/v1/actions?type=todo&status=pending,open&history=1&vault=/tmp/vault&q=tea');
    assert.equal(list.status, 200);
    assert.ok(Array.isArray(list.body.actions));
    assert.deepEqual(last('listActions')!.args[0], { type: 'todo', status: ['pending', 'open'], history: true, vaultPath: '/tmp/vault', text: 'tea' });
    assert.equal((await request(port, 'GET', '/v1/actions?status=bogus')).status, 400);
  });

  it('POST /v1/actions creates (201) and validates', async () => {
    const res = await request(port, 'POST', '/v1/actions', { type: 'todo', title: 'Buy the tin', fields: { due: '2026-10-05', person: null } });
    assert.equal(res.status, 201);
    assert.equal(res.body.title, 'Buy the tin');
    assert.deepEqual(last('createAction')!.args[0], { type: 'todo', title: 'Buy the tin', fields: { due: '2026-10-05', person: null } });
    assert.equal((await request(port, 'POST', '/v1/actions', { type: 'todo' })).status, 400);
    assert.equal((await request(port, 'POST', '/v1/actions', { title: 'x', fields: { due: 3 } })).status, 400);
    const defaulted = await request(port, 'POST', '/v1/actions', { title: 'Default type' });
    assert.equal(defaulted.body.type, 'todo');
  });

  it('Jira pickers: projects, types and fields, with ?refresh=1 (actions.md)', async () => {
    const projects = await request(port, 'GET', '/v1/jira/projects');
    assert.equal(projects.status, 200);
    assert.deepEqual(projects.body.projects, [{ key: 'TLS', name: 'Telus Platform' }]);
    assert.deepEqual(last('jiraProjects')!.args, [undefined]);
    await request(port, 'GET', '/v1/jira/projects?refresh=1');
    assert.deepEqual(last('jiraProjects')!.args, ['refresh']);
    assert.equal((await request(port, 'GET', '/v1/jira/projects/TLS/types')).body.types[0].name, 'Task');
    assert.deepEqual(last('jiraIssueTypes')!.args, ['TLS', undefined]);
    const fields = await request(port, 'GET', '/v1/jira/projects/TLS/types/10001/fields?refresh=1');
    assert.deepEqual(fields.body.priorities, ['P1', 'P2']);
    assert.deepEqual(last('jiraFields')!.args, ['TLS', '10001', 'refresh']);
  });

  it('Jira required fields: people search and the create page (actions.md)', async () => {
    const people = await request(port, 'GET', '/v1/jira/projects/TLS/users?q=adi');
    assert.deepEqual(people.body.users, [{ accountId: 'acc-aditya', name: 'Aditya Pradhan' }]);
    assert.deepEqual(last('jiraUsers')!.args, ['TLS', 'adi']);
    const page = await request(port, 'GET', '/v1/actions/act-1/jira-create-url');
    assert.equal(page.status, 200);
    assert.match(page.body.url, /CreateIssueDetails!init\.jspa/);
    assert.deepEqual(last('jiraCreateURL')!.args, ['act-1']);
    await request(port, 'GET', '/v1/jira/projects/TLS/users');
    assert.deepEqual(last('jiraUsers')!.args, ['TLS', ''], 'no ?q=: an empty search');
    for (const p of ['/v1/jira/projects/TLS/users/x', '/x/v1/jira/projects/TLS/users', '/v1/actions/act-1/jira-create-url/x', '/x/v1/actions/act-1/jira-create-url']) {
      assert.equal((await request(port, 'GET', p)).status, 404, p);
    }
  });

  it('whose items: owner, Pending, Highlights, preview and ?route= (actions-routing.md)', async () => {
    await request(port, 'GET', '/v1/actions?route=waiting');
    assert.deepEqual(last('listActions')!.args, [{ route: 'waiting' }]);
    assert.equal((await request(port, 'GET', '/v1/actions?route=mine')).status, 400);
    assert.equal((await request(port, 'POST', '/v1/actions/act-1/owner', { owner: 'you' })).status, 200);
    assert.deepEqual(last('assignActionOwner')!.args, ['act-1', 'you']);
    await request(port, 'POST', '/v1/actions/act-1/owner', { owner: null });
    assert.deepEqual(last('assignActionOwner')!.args, ['act-1', null]);
    assert.equal((await request(port, 'POST', '/v1/actions/act-1/owner', { owner: 3 })).status, 400);
    for (const [route, method] of [['track-pending', 'trackAsPending'], ['claim', 'claimAction'], ['received', 'markReceived'], ['stop-waiting', 'stopWaiting']] as const) {
      assert.equal((await request(port, 'POST', `/v1/actions/act-1/${route}`)).status, 200, route);
      assert.deepEqual(last(method)!.args, ['act-1']);
    }
    // Track as Pending from To confirm / To do: who and, optionally, by when.
    const tracked = await request(port, 'POST', '/v1/actions/act-1/track-pending', { waitingOn: 'p-aditya', by: '2026-10-09' });
    assert.equal(tracked.status, 200);
    assert.deepEqual(last('trackAsPending')!.args, ['act-1', { waitingOn: 'p-aditya', by: '2026-10-09' }]);
    await request(port, 'POST', '/v1/actions/act-1/track-pending', { waitingOn: 'Mei', by: null });
    assert.deepEqual(last('trackAsPending')!.args, ['act-1', { waitingOn: 'Mei', by: null }]);
    await request(port, 'POST', '/v1/actions/act-1/track-pending', {});
    assert.deepEqual(last('trackAsPending')!.args, ['act-1'], 'an empty body is Highlights’ call');
    const empty = await request(port, 'POST', '/v1/actions/act-1/track-pending', { waitingOn: '  ' });
    assert.equal(empty.status, 400);
    assert.match(JSON.stringify(empty.body), /Fill in who you’re waiting on/);
    assert.equal((await request(port, 'POST', '/v1/actions/act-1/track-pending', { waitingOn: 3 })).status, 400);
    assert.equal((await request(port, 'POST', '/v1/actions/act-1/track-pending', { waitingOn: 'Mei', by: 5 })).status, 400);
    assert.equal((await request(port, 'POST', '/v1/actions/act-1/track-pending', [])).status, 400);
    const nudge = await request(port, 'POST', '/v1/actions/act-1/nudge', { to: '@aditya', text: 'Hi Aditya, any update?' });
    assert.equal(nudge.body.message.type, 'slack');
    assert.deepEqual(last('nudgeAction')!.args, ['act-1', { to: '@aditya', text: 'Hi Aditya, any update?' }]);
    assert.equal((await request(port, 'POST', '/v1/actions/act-1/nudge', { to: '@aditya' })).status, 400);
    const preview = await request(port, 'POST', '/v1/actions/routing-preview', { people: [{ id: 'you', name: 'Jin', aliases: [] }] });
    assert.deepEqual(preview.body, { days: 7, lists: 14, waiting: 6, others: 31, beforeRouting: 0 });
    assert.deepEqual(last('routingPreview')!.args, [{ people: [{ id: 'you', name: 'Jin', aliases: [] }] }]);
    await request(port, 'POST', '/v1/actions/routing-preview');
    assert.deepEqual(last('routingPreview')!.args, [undefined]);
    assert.deepEqual((await request(port, 'GET', '/v1/highlights')).body, { notes: [] });
    assert.equal((await request(port, 'GET', '/v1/highlights/note?path=wiki%2Fsources%2Fx.md')).status, 404);
    assert.deepEqual(last('getHighlight')!.args, ['wiki/sources/x.md']);
  });

  it('get, patch, confirm, dismiss, delete', async () => {
    assert.equal((await request(port, 'GET', '/v1/actions/act-1')).body.id, 'act-1');
    const missing = await request(port, 'GET', '/v1/actions/nope');
    assert.equal(missing.status, 404);
    assert.equal(missing.body.error.code, 'action_not_found');
    const patched = await request(port, 'PATCH', '/v1/actions/act-1', { title: 'Book it', body: null, fields: { due: null } });
    assert.equal(patched.status, 200);
    assert.deepEqual(last('updateAction')!.args, ['act-1', { title: 'Book it', body: null, fields: { due: null } }]);
    const confirmed = await request(port, 'POST', '/v1/actions/confirm', { ids: ['act-1'] });
    assert.equal(confirmed.body.actions[0].status, 'open');
    assert.equal((await request(port, 'POST', '/v1/actions/confirm', { ids: [] })).status, 400);
    // Add as (actions.md): the target type and the owner's edits reach the core as one object.
    const as = { type: 'slack', title: 'Tell Mei', body: 'Hi Mei', fields: { to: 'Mei Tanaka', thread: null } };
    assert.equal((await request(port, 'POST', '/v1/actions/confirm', { ids: ['act-1'], as })).status, 200);
    assert.deepEqual(last('confirmActions')!.args, [['act-1'], as]);
    assert.equal((await request(port, 'POST', '/v1/actions/confirm', { ids: ['act-1'], as: { title: 'no type' } })).status, 400);
    assert.equal((await request(port, 'POST', '/v1/actions/confirm', { ids: ['act-1'], as: { type: 'slack', fields: { to: 3 } } })).status, 400);
    assert.deepEqual((await request(port, 'POST', '/v1/actions/dismiss', { ids: ['act-ask'] })).body, { ids: ['act-ask'], dismissed: true });
    assert.equal((await request(port, 'POST', '/v1/actions/dismiss', { ids: ['nope'] })).status, 404);
    const notHistory = await request(port, 'DELETE', '/v1/actions/act-1');
    assert.equal(notHistory.status, 409);
    await request(port, 'POST', '/v1/actions/act-1/remove');
    assert.deepEqual((await request(port, 'DELETE', '/v1/actions/act-1')).body, { id: 'act-1', deleted: true });
    assert.equal((await request(port, 'POST', '/v1/actions/act-1')).status, 405, 'no POST on an item: confirm/dismiss stay routable');
  });

  it('draft, improve (with a signal), undo, perform, send, remove, restore', async () => {
    const t = (await request(port, 'POST', '/v1/actions', { type: 'slack', title: 'Tell Mei' })).body;
    const drafted = await request(port, 'POST', `/v1/actions/${t.id}/draft`);
    assert.equal(drafted.body.status, 'ready');
    assert.deepEqual(last('draftAction')!.args, [t.id, 'signal']);
    assert.equal((await request(port, 'POST', `/v1/actions/${t.id}/improve`)).body.previousBody, 'Drafted.');
    assert.equal((await request(port, 'POST', `/v1/actions/${t.id}/undo-improve`)).body.body, 'Drafted.');
    assert.equal((await request(port, 'POST', `/v1/actions/${t.id}/undo-improve`)).status, 409);
    const failed = await request(port, 'POST', `/v1/actions/${t.id}/perform`, { handler: 'create' });
    assert.equal(failed.status, 200, 'a handler failure is the item with error set, not an HTTP error');
    assert.equal(failed.body.error.code, 'not_connected');
    assert.equal((await request(port, 'POST', `/v1/actions/${t.id}/perform`, {})).status, 400);
    const sent = await request(port, 'POST', `/v1/actions/${t.id}/send`, { type: 'jira' });
    assert.equal(sent.body.fromActionID, t.id);
    assert.equal((await request(port, 'POST', `/v1/actions/${t.id}/remove`)).body.status, 'removed');
    assert.equal((await request(port, 'POST', `/v1/actions/${t.id}/restore`)).body.status, 'open');
  });

  it('POST /v1/jobs/:id/actions/find (Try again)', async () => {
    const id = core.jobs[0]!.id;
    assert.equal((await request(port, 'POST', `/v1/jobs/${id}/actions/find`)).status, 409, 'not applied yet');
    core.jobs[0]!.state = 'completed';
    const res = await request(port, 'POST', `/v1/jobs/${id}/actions/find`);
    assert.equal(res.status, 200);
    assert.equal(res.body.job.actionsFound.status, 'finding');
    assert.equal((await request(port, 'POST', '/v1/jobs/nope/actions/find')).status, 404);
  });

  it('GET /v1/jobs/:id/actions (v11: what Review shows)', async () => {
    const id = core.jobs[0]!.id;
    const res = await request(port, 'GET', `/v1/jobs/${id}/actions`);
    assert.equal(res.status, 200);
    assert.ok(Array.isArray(res.body.proposals));
    assert.ok('summary' in res.body);
    assert.deepEqual(last('jobActions')!.args, [id]);
    assert.equal((await request(port, 'GET', '/v1/jobs/nope/actions')).status, 404);
  });

  it('POST /v1/conversations/:id/actions/detect', async () => {
    const res = await request(port, 'POST', '/v1/conversations/conv-1/actions/detect', { turnIndex: 0 });
    assert.equal(res.status, 200);
    assert.deepEqual(last('detectAskActions')!.args, ['conv-1', 0]);
    assert.equal((await request(port, 'POST', '/v1/conversations/conv-1/actions/detect')).status, 200);
    assert.equal((await request(port, 'POST', '/v1/conversations/conv-1/actions/detect', { turnIndex: -1 })).status, 400);
    assert.equal((await request(port, 'POST', '/v1/conversations/nope/actions/detect')).status, 404);
  });

  it('connections: list, sign-in URL, connect (secrets redacted), disconnect', async () => {
    const list = await request(port, 'GET', '/v1/connections');
    assert.deepEqual(list.body.connections.map((c: { id: string }) => c.id), ['atlassian', 'slack']);
    const url = await request(port, 'GET', '/v1/connections/atlassian/sign-in-url?site=https://acme.atlassian.net');
    assert.deepEqual(url.body, { url: 'https://id.atlassian.com/manage-profile/security/api-tokens' });
    assert.deepEqual(last('signInURL')!.args, ['atlassian', 'https://acme.atlassian.net']);
    const bad = await request(port, 'POST', '/v1/connections/atlassian/connect', { site: 'https://acme.atlassian.net', email: 'jin@example.com', token: 'bad' });
    assert.equal(bad.status, 400);
    assert.doesNotMatch(bad.body.error.message, /jin@example\.com/);
    const ok = await request(port, 'POST', '/v1/connections/atlassian/connect', { site: 'https://acme.atlassian.net', email: 'jin@example.com', token: 'tok' });
    assert.equal(ok.body.status, 'connected');
    assert.doesNotMatch(JSON.stringify(ok.body), /tok"|jin@example/);
    assert.equal((await request(port, 'POST', '/v1/connections/atlassian/disconnect')).body.status, 'not_connected');
    assert.equal((await request(port, 'POST', '/v1/connections/nope/disconnect')).status, 404);
  });
});
