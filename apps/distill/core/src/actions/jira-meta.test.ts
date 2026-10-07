/**
 * Jira pickers (actions.md, "Jira pickers"): what the account allows, paged and cached, and the
 * check before Create. A fake AtlassianClient stands in for the network; no real Jira is called.
 */
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { CoreError } from '../contracts.js';
import { ActionHandlerError, type AtlassianClient, type AtlassianRecord } from './atlassian.js';
import { checkJiraDraft, JIRA_META_TTL_MS, JiraMeta, jiraUnreachable, projectKey, sameName } from './jira-meta.js';

type Reply = { status: number; json: unknown } | Error;

/** A fake client: answers by path prefix (the first match wins) and records every GET. */
function fakeClient(routes: [string, Reply | ((p: string) => Reply)][], o: { rec?: AtlassianRecord | undefined; connected?: boolean } = {}) {
  const calls: string[] = [];
  const state = { rec: 'rec' in o ? o.rec : ({ site: 'acme.atlassian.net', account: 'Jin', accountId: 'acc-1' } as AtlassianRecord | undefined) };
  const client = {
    record: () => state.rec,
    isConnected: () => o.connected ?? true,
    call: async (method: string, p: string) => {
      assert.equal(method, 'GET');
      calls.push(p);
      const hit = routes.find(([prefix]) => p.startsWith(prefix));
      if (!hit) return { status: 404, json: {} };
      const r = typeof hit[1] === 'function' ? hit[1](p) : hit[1];
      if (r instanceof Error) throw r;
      return r;
    },
  } as unknown as AtlassianClient;
  return { client, calls, state };
}

const PROJECTS = '/rest/api/3/project/search';
const TYPES = (k: string) => `/rest/api/3/issue/createmeta/${k}/issuetypes`;
const clock = (start = Date.parse('2026-10-06T12:00:00.123Z')) => {
  const c = { t: start, now: () => new Date(c.t) };
  return c;
};
const jiraKind = (e: unknown) => (e instanceof CoreError ? e.details?.jira : undefined);

describe('JiraMeta lists', () => {
  test('projects: objects with a key only, sorted by key, with the site, account and fetch time', async () => {
    const { client, calls } = fakeClient([[PROJECTS, { status: 200, json: { isLast: true, values: [{ key: 'TLS', name: 'Telus', id: '10000' }, 'junk', null, { name: 'no key' }, { key: 'ABC', name: 1, id: 5 }, { key: 'OPS', name: 'Ops', id: '' }] } }]]);
    const r = await new JiraMeta(client, clock().now).projects();
    assert.deepEqual(r, { site: 'acme.atlassian.net', account: 'Jin', fetchedAt: '2026-10-06T12:00:00Z', projects: [{ key: 'ABC', name: '' }, { key: 'OPS', name: 'Ops' }, { key: 'TLS', name: 'Telus', id: '10000' }] }, 'the id only when it is text');
    assert.deepEqual(calls, [`${PROJECTS}?action=create&orderBy=key&startAt=0&maxResults=50`]);
  });

  test('pages follow startAt until total, isLast, an empty page, or a body that says neither', async () => {
    const page = (n: number, extra: object) => ({ status: 200, json: { values: Array.from({ length: n }, (_, i) => ({ key: `K${i}${Math.random()}` })), ...extra } });
    const byTotal = fakeClient([[PROJECTS, (p) => (p.includes('startAt=0&') ? page(2, { total: 3 }) : page(1, { total: 3 }))]]);
    assert.equal((await new JiraMeta(byTotal.client, clock().now).projects()).projects.length, 3);
    assert.deepEqual(byTotal.calls.map((c) => /startAt=(\d+)/.exec(c)![1]), ['0', '2']);

    const byLast = fakeClient([[PROJECTS, (p) => (p.includes('startAt=0&') ? page(2, { isLast: false }) : page(2, { isLast: true }))]]);
    assert.equal((await new JiraMeta(byLast.client, clock().now).projects()).projects.length, 4);
    assert.equal(byLast.calls.length, 2);

    const isLastWins = fakeClient([[PROJECTS, page(2, { isLast: true, total: 99 })]]);
    await new JiraMeta(isLastWins.client, clock().now).projects();
    assert.equal(isLastWins.calls.length, 1, 'isLast ends it even with a larger total');

    const bare = fakeClient([[PROJECTS, page(2, {})]]);
    await new JiraMeta(bare.client, clock().now).projects();
    assert.equal(bare.calls.length, 1, 'no isLast and no total: one page');

    const empty = fakeClient([[PROJECTS, (p) => (p.includes('startAt=0&') ? page(2, { isLast: false }) : page(0, { isLast: false }))]]);
    assert.equal((await new JiraMeta(empty.client, clock().now).projects()).projects.length, 2);
    assert.equal(empty.calls.length, 2);

    const textTotal = fakeClient([[PROJECTS, page(2, { total: '3' })]]);
    await new JiraMeta(textTotal.client, clock().now).projects();
    assert.equal(textTotal.calls.length, 1, 'a total that is not a number is no total');

    const noList = fakeClient([[PROJECTS, { status: 200, json: { values: 'nope', total: 5 } }]]);
    assert.deepEqual((await new JiraMeta(noList.client, clock().now).projects()).projects, []);
  });

  test('an endless list stops at 40 pages', async () => {
    let n = 0;
    const endless = fakeClient([[PROJECTS, () => ({ status: 200, json: { isLast: false, values: [{ key: `P${n++}` }] } })]]);
    assert.equal((await new JiraMeta(endless.client, clock().now).projects()).projects.length, 40);
    assert.equal(endless.calls.length, 40);
  });

  test('issue types: the project key trimmed and upper-cased, subtasks and nameless types left out', async () => {
    const { client, calls } = fakeClient([[TYPES('TLS'), { status: 200, json: { issueTypes: [null, { id: '5' }, { id: '1', name: 'Task' }, { id: '2', name: 'Sub-task', subtask: true }, { id: '3', name: '' }, { name: 'No id' }, { id: '4', name: 'Bug', subtask: false }] } }]]);
    const r = await new JiraMeta(client, clock().now).issueTypes('  tls ');
    assert.equal(r.project, 'TLS');
    assert.deepEqual(r.types, [{ id: '1', name: 'Task' }, { id: '4', name: 'Bug' }]);
    assert.deepEqual(calls, [`${TYPES('TLS')}?startAt=0&maxResults=50`]);
  });

  test('issue types also read a values list; a key with odd characters is encoded', async () => {
    const { client, calls } = fakeClient([['/rest/api/3/issue/createmeta/', { status: 200, json: { values: [{ id: '1', name: 'Task' }] } }]]);
    assert.deepEqual((await new JiraMeta(client, clock().now).issueTypes('a/b')).types, [{ id: '1', name: 'Task' }]);
    assert.ok(calls[0]!.startsWith('/rest/api/3/issue/createmeta/A%2FB/issuetypes?'));
  });

  test('fields: id from fieldId or key, allowed values by name or value, required only when true, a kind for each; the priority scheme and the extra fields', async () => {
    const { client, calls } = fakeClient([[`${TYPES('TLS')}/10001`, { status: 200, json: { values: [
      null,
      { fieldId: 'summary', name: 'Summary', required: true },
      { key: 'priority', name: 'Priority', required: 'yes', allowedValues: [{ name: 'High' }, null, { value: 'Low' }, {}, 'x'] },
      { required: true },
    ] } }]]);
    const r = await new JiraMeta(client, clock().now).fields(' tls ', '10001');
    assert.equal(r.project, 'TLS');
    assert.equal(r.typeId, '10001');
    assert.deepEqual(r.fields, [
      { id: 'summary', name: 'Summary', required: true, kind: 'unsupported' },
      { id: 'priority', name: 'Priority', required: false, allowed: ['High', 'Low'], kind: 'unsupported' },
      { id: '', name: '', required: true, kind: 'unsupported' },
    ]);
    assert.deepEqual(r.priorities, ['High', 'Low']);
    assert.deepEqual(r.extra, [], 'standard fields and a field without an id are not extra');
    assert.ok(calls[0]!.startsWith(`${TYPES('TLS')}/10001?startAt=0`));
  });

  test('no Priority field: priorities null; a Priority with no allowed list: none allowed', async () => {
    const none = fakeClient([['/rest/api/3/issue/createmeta/', { status: 200, json: { fields: [{ fieldId: 'summary', name: 'Summary' }] } }]]);
    assert.equal((await new JiraMeta(none.client, clock().now).fields('TLS', '1')).priorities, null);
    const open = fakeClient([['/rest/api/3/issue/createmeta/', { status: 200, json: { fields: [{ fieldId: 'priority', name: 'Priority' }] } }]]);
    assert.deepEqual((await new JiraMeta(open.client, clock().now).fields('TLS', '1')).priorities, []);
  });
});

describe('JiraMeta users', () => {
  const USERS = '/rest/api/3/user/assignable/search';
  const projects: [string, Reply] = [PROJECTS, { status: 200, json: { isLast: true, values: [{ key: 'TLS' }] } }];

  test('active people with an account id, the name falling back to the id; the project and query trimmed and encoded', async () => {
    const f = fakeClient([projects, [USERS, { status: 200, json: [{ accountId: 'a1', displayName: 'Mei Chen' }, { accountId: 'a2', active: false, displayName: 'Gone' }, { accountId: 'a3', active: true }, { displayName: 'No id' }, { accountId: 7 }, null, 'x'] }]]);
    const r = await new JiraMeta(f.client, clock().now).users(' t/ls ', '  mei & co ');
    assert.deepEqual(r, { users: [{ accountId: 'a1', name: 'Mei Chen' }, { accountId: 'a3', name: 'a3' }] });
    assert.deepEqual(f.calls, [`${PROJECTS}?action=create&orderBy=key&startAt=0&maxResults=50`, `${USERS}?project=T%2FLS&query=mei%20%26%20co&maxResults=20`]);
  });

  test('a blank query asks nothing; a body that is not a list is nobody', async () => {
    const f = fakeClient([projects, [USERS, { status: 200, json: { values: [{ accountId: 'a1' }] } }]]);
    const meta = new JiraMeta(f.client, clock().now);
    assert.deepEqual(await meta.users('TLS', '   '), { users: [] });
    assert.equal(f.calls.length, 0);
    assert.deepEqual(await meta.users('TLS', 'mei'), { users: [] });
  });

  test('not connected: the connection words, and no search; a failed search is a Jira error', async () => {
    const off = fakeClient([], { connected: false });
    await assert.rejects(new JiraMeta(off.client, clock().now).users('TLS', 'mei'), (e: unknown) => jiraKind(e) === 'not_connected');
    assert.equal(off.calls.length, 0);
    const bad = fakeClient([projects, [USERS, { status: 403, json: [] }]]);
    await assert.rejects(new JiraMeta(bad.client, clock().now).users('TLS', 'mei'), (e: unknown) => jiraKind(e) === 'error' && e instanceof CoreError && e.details?.status === 403);
  });

  test('a search is never cached', async () => {
    const f = fakeClient([projects, [USERS, { status: 200, json: [] }]]);
    const meta = new JiraMeta(f.client, clock().now);
    await meta.users('TLS', 'mei');
    await meta.users('TLS', 'mei');
    assert.equal(f.calls.filter((c) => c.startsWith(USERS)).length, 2);
  });
});

describe('JiraMeta cache', () => {
  test('an hour per account and site; refresh reloads; the hour boundary reloads', async () => {
    assert.equal(JIRA_META_TTL_MS, 3_600_000);
    const c = clock();
    const f = fakeClient([[PROJECTS, { status: 200, json: { isLast: true, values: [{ key: 'A' }] } }]]);
    const meta = new JiraMeta(f.client, c.now);
    await meta.projects();
    c.t += JIRA_META_TTL_MS - 1;
    await meta.projects();
    assert.equal(f.calls.length, 1, 'within the hour: cached');
    await meta.projects({ refresh: true });
    assert.equal(f.calls.length, 2, 'refresh reloads');
    c.t += JIRA_META_TTL_MS;
    await meta.projects();
    assert.equal(f.calls.length, 3, 'an hour later: reloaded');
    f.state.rec = { site: 'acme.atlassian.net', account: 'Jin', accountId: 'acc-2' };
    await meta.projects();
    assert.equal(f.calls.length, 4, 'another account has its own cache');
    f.state.rec = { site: 'other.atlassian.net', account: 'Jin', accountId: 'acc-2' };
    await meta.projects();
    assert.equal(f.calls.length, 5, 'another site too');
  });

  test('a create screen is cached per project and type', async () => {
    const f = fakeClient([['/rest/api/3/issue/createmeta/', (p) => ({ status: 200, json: { fields: [{ fieldId: p.includes('/issuetypes/1?') ? 'one' : 'two', name: 'F' }] } })]]);
    const meta = new JiraMeta(f.client, clock().now);
    assert.equal((await meta.fields('TLS', '1')).fields[0]!.id, 'one');
    assert.equal((await meta.fields('TLS', '2')).fields[0]!.id, 'two');
    assert.equal((await meta.fields('tls', '1')).fields[0]!.id, 'one');
    assert.equal(f.calls.length, 2);
  });

  test('each list is cached on its own; an account without an id is keyed by its name', async () => {
    const f = fakeClient([[PROJECTS, { status: 200, json: { isLast: true, values: [{ key: 'A' }] } }], [TYPES('A'), { status: 200, json: { values: [{ id: '1', name: 'Task' }] } }], [TYPES('B'), { status: 200, json: { values: [] } }]], { rec: { site: 's', account: 'Jin' } });
    const meta = new JiraMeta(f.client, clock().now);
    await meta.projects();
    await meta.issueTypes('a');
    await meta.issueTypes('A');
    await meta.issueTypes('b');
    assert.equal(f.calls.length, 3);
    f.state.rec = { site: 's', account: 'Mei' };
    await meta.projects();
    assert.equal(f.calls.length, 4);
  });

  test('a record without an account gives account null', async () => {
    const f = fakeClient([[PROJECTS, { status: 200, json: { isLast: true, values: [] } }]], { rec: { site: 's' } });
    assert.equal((await new JiraMeta(f.client, clock().now).projects()).account, null);
  });
});

describe('JiraMeta errors', () => {
  test('not connected: invalid_state with jira not_connected, and nothing is fetched', async () => {
    for (const o of [{ rec: undefined }, { connected: false }]) {
      const f = fakeClient([], o);
      await assert.rejects(new JiraMeta(f.client, clock().now).projects(), (e: unknown) => e instanceof CoreError && e.code === 'invalid_state' && jiraKind(e) === 'not_connected' && /Settings → Connections/.test(e.message));
      assert.equal(f.calls.length, 0);
    }
  });

  test('a handler error becomes a CoreError that says which kind', async () => {
    const cases: [string, string][] = [['unreachable', 'unreachable'], ['auth_expired', 'auth_expired'], ['refused', 'not_connected'], ['not_connected', 'not_connected']];
    for (const [code, kind] of cases) {
      const f = fakeClient([[PROJECTS, new ActionHandlerError({ code: code as 'unreachable', message: `msg ${code}` })]]);
      await assert.rejects(new JiraMeta(f.client, clock().now).projects(), (e: unknown) => e instanceof CoreError && e.code === 'invalid_state' && jiraKind(e) === kind && e.message === `msg ${code}`);
    }
  });

  test('any other thrown error passes through unchanged', async () => {
    const boom = new TypeError('boom');
    const f = fakeClient([[PROJECTS, boom]]);
    await assert.rejects(new JiraMeta(f.client, clock().now).projects(), (e: unknown) => e === boom);
  });

  test('a non-2xx status or no body is a Jira error with the status; a list where an object belongs is a Jira error', async () => {
    for (const [status, json] of [[500, {}], [199, {}], [300, {}], [200, null], [200, undefined]] as [number, unknown][]) {
      const f = fakeClient([[PROJECTS, { status, json }]]);
      await assert.rejects(new JiraMeta(f.client, clock().now).projects(), (e: unknown) => e instanceof CoreError && e.code === 'invalid_state' && jiraKind(e) === 'error' && e.details?.status === status && e.message === `Jira answered ${status} for the list of choices.`, `${status}`);
    }
    for (const json of [[], 'text', 3]) {
      const f = fakeClient([[PROJECTS, { status: 200, json }]]);
      await assert.rejects(new JiraMeta(f.client, clock().now).projects(), (e: unknown) => e instanceof CoreError && e.code === 'invalid_state' && jiraKind(e) === 'error' && e.details?.status === undefined && e.message === 'Jira answered with something other than a list of choices.', JSON.stringify(json));
    }
    const ok = fakeClient([[PROJECTS, { status: 299, json: { values: [] } }]]);
    assert.deepEqual((await new JiraMeta(ok.client, clock().now).projects()).projects, [], '299 is success');
  });

  test('jiraUnreachable: only a CoreError that names a jira kind', () => {
    assert.equal(jiraUnreachable(new CoreError('invalid_state', 'x', { jira: 'unreachable' })), true);
    assert.equal(jiraUnreachable(new CoreError('invalid_state', 'x', { jira: 3 })), false);
    assert.equal(jiraUnreachable(new CoreError('invalid_state', 'x')), false);
    assert.equal(jiraUnreachable(new Error('x')), false);
    assert.equal(jiraUnreachable(undefined), false);
  });
});

describe('names', () => {
  test('projectKey: the first word, upper case; "·" separates', () => {
    assert.equal(projectKey('TLS · Telus Platform'), 'TLS');
    assert.equal(projectKey('  tls '), 'TLS');
    assert.equal(projectKey('abc·def'), 'ABC');
  });

  test("sameName: case and spacing ignored; the list's spelling returned", () => {
    assert.equal(sameName('  high   priority ', ['Low', 'High Priority']), 'High Priority');
    assert.equal(sameName('high priority', ['  High \t Priority ']), '  High \t Priority ', 'the list side is folded too');
    assert.equal(sameName('High', ['Highest']), undefined);
    assert.equal(sameName('x', []), undefined);
  });
});

describe('checkJiraDraft', () => {
  const meta = (routes: [string, Reply | ((p: string) => Reply)][] = []) =>
    new JiraMeta(
      fakeClient([
        ...routes,
        [PROJECTS, { status: 200, json: { isLast: true, values: [{ key: 'TLS', name: 'Telus Platform' }, { key: 'OPS', name: 'Operations', id: '200' }] } }],
        [`${TYPES('TLS')}/10`, { status: 200, json: { fields: [{ fieldId: 'priority', name: 'Priority', allowedValues: [{ name: 'High' }, { name: 'Low' }] }] } }],
        [`${TYPES('TLS')}/20`, { status: 200, json: { fields: [{ fieldId: 'summary', name: 'Summary' }] } }],
        [TYPES('TLS'), { status: 200, json: { values: [{ id: '10', name: 'Task' }, { id: '20', name: 'Bug' }] } }],
        [`${TYPES('OPS')}/30`, { status: 200, json: { fields: [] } }],
        [TYPES('OPS'), { status: 200, json: { values: [{ id: '30', name: 'Story' }] } }],
      ]).client,
      clock().now,
    );

  test('no project: nothing to check', async () => {
    assert.deepEqual(await checkJiraDraft(meta(), {}), {});
    assert.deepEqual(await checkJiraDraft(meta(), { project: '   ', issueType: 'Nope' }), {});
  });

  test("a project by key or by name, a type (Task by default) and a priority get Jira's spelling", async () => {
    const taskFields = [{ id: 'priority', name: 'Priority', required: false, allowed: ['High', 'Low'], kind: 'unsupported' }];
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'tls · whatever', priority: ' high ' }), { project: 'TLS', issueType: 'Task', typeId: '10', fields: taskFields, priority: 'High' });
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'operations', issueType: 'story' }), { project: 'OPS', projectId: '200', issueType: 'Story', typeId: '30', fields: [] }, 'the screen is read even without a priority');
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'TLS', issueType: '  ', priority: '   ' }), { project: 'TLS', issueType: 'Task', typeId: '10', fields: taskFields }, 'a blank priority is no priority');
  });

  test('a type whose screen has no Priority drops the priority', async () => {
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'TLS', issueType: 'bug', priority: 'High' }), { project: 'TLS', issueType: 'Bug', typeId: '20', fields: [{ id: 'summary', name: 'Summary', required: false, kind: 'unsupported' }], dropPriority: true });
  });

  test('a value outside the lists is a problem on that field, in plain words', async () => {
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'NOPE' }), { problem: { field: 'project', message: 'NOPE isn’t a Jira project you can create tickets in. Pick one.' } });
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'TLS', issueType: 'Epic' }), { project: 'TLS', problem: { field: 'issueType', message: 'Epic isn’t an issue type in TLS. Pick one.' } });
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'OPS' }), { project: 'OPS', projectId: '200', problem: { field: 'issueType', message: 'Task isn’t an issue type in OPS. Pick one.' } });
    assert.deepEqual(await checkJiraDraft(meta(), { project: 'TLS', priority: '  Urgent ' }), { project: 'TLS', issueType: 'Task', typeId: '10', fields: [{ id: 'priority', name: 'Priority', required: false, allowed: ['High', 'Low'], kind: 'unsupported' }], problem: { field: 'priority', message: 'Urgent isn’t a priority in TLS. Pick one.' } });
  });

  test("Jira can't be asked: nothing is blocked, what was checked is kept", async () => {
    const down = new ActionHandlerError({ code: 'unreachable', message: 'offline' });
    assert.deepEqual(await checkJiraDraft(meta([[PROJECTS, down]]), { project: 'TLS' }), { unchecked: true });
    assert.deepEqual(await checkJiraDraft(meta([[TYPES('TLS'), down]]), { project: 'TLS' }), { project: 'TLS', unchecked: true });
    assert.deepEqual(await checkJiraDraft(meta([[`${TYPES('TLS')}/10`, { status: 503, json: {} }]]), { project: 'TLS', priority: 'High' }), { project: 'TLS', issueType: 'Task', typeId: '10', unchecked: true });
    assert.deepEqual(await checkJiraDraft(meta([[`${TYPES('TLS')}/10`, { status: 503, json: {} }]]), { project: 'TLS' }), { project: 'TLS', issueType: 'Task', typeId: '10', unchecked: true }, 'the screen is read without a priority too');
  });

  test('any other error is thrown', async () => {
    await assert.rejects(checkJiraDraft(meta([[PROJECTS, new RangeError('bug')]]), { project: 'TLS' }), RangeError);
  });
});
