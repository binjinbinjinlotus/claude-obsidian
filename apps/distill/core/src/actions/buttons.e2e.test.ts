/**
 * Action buttons end to end (action-buttons.md): a real python3 script added as an automation with a
 * command, a Slack button bound to it, run through the HTTP API from "the app". Temp state, vault and
 * queue; nothing of the owner's is touched.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { createCore } from '../index.js';
import { startServer, type RunningServer } from '../server/http.js';
import { statePaths } from '../store/paths.js';

const TOKEN = 'd'.repeat(64);
let root: string;
let server: RunningServer;
let core: ReturnType<typeof createCore>;
let marker: string;

function request(method: string, p: string, body?: unknown, client = 'app'): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const headers: Record<string, string> = { authorization: `Bearer ${TOKEN}`, 'x-distill-client': client };
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

async function settle(id: string): Promise<any> {
  for (let i = 0; i < 300; i++) {
    const r = await request('GET', `/v1/actions/${id}`);
    if (r.body && !r.body.activeRun) return r.body;
    await new Promise((res) => setTimeout(res, 20));
  }
  throw new Error('the button run did not finish');
}

/** Echoes its argv as JSON, prints a Slack-like line, exits with $FAIL_WITH when the text says so. */
const SCRIPT = [
  'import json, sys',
  'args = sys.argv[1:]',
  'print(json.dumps({"argv": args}))',
  'if args and args[-1] == "please fail":',
  '    print("Error: channel not found", file=sys.stderr)',
  '    sys.exit(3)',
  'print("sent to #general (channel, ts 1759600000.123456)")',
].join('\n');

let collectorId = '';

before(async () => {
  root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-buttons-e2e-')));
  marker = path.join(root, 'pwned');
  const vault = path.join(root, 'vault');
  const queue = path.join(root, 'queue');
  const state = path.join(root, 'state');
  for (const d of [vault, queue, state]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(state, 'settings.json'), JSON.stringify({ vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault }));
  core = createCore({
    paths: statePaths(state),
    collectors: { homeDir: root, tmpDir: root, killGraceMs: 500, loginPath: async () => process.env.PATH ?? '/usr/bin:/bin', baseEnv: { ...process.env, HOME: root } },
  });
  await core.start();
  server = await startServer({ core, token: TOKEN, port: 0 });

  const created = await request('POST', '/v1/collectors', { kind: 'script', name: 'Slack CLI', script: { source: { inline: SCRIPT }, interpreter: 'python3', timeoutSeconds: 60 } });
  assert.equal(created.status, 201, JSON.stringify(created.body));
  collectorId = created.body.id;
  const commands = [
    {
      id: 'send',
      label: 'Send a message',
      args: [
        { name: 'send', kind: 'word', value: 'send' },
        { name: 'thread', kind: 'flag', flag: '--thread' },
        { name: 'target', kind: 'positional', pattern: '^(#\\S+|@\\S+|[CGDUW][A-Z0-9]+)$', hint: '#channel, @handle or an ID' },
        { name: 'text', kind: 'positional' },
      ],
      result: { keyPattern: 'ts ([0-9]+\\.[0-9]+)\\)' },
    },
  ];
  const patched = await request('PATCH', `/v1/collectors/${collectorId}`, { script: { collects: false, commands } });
  assert.equal(patched.status, 200, JSON.stringify(patched.body));
  const settings = (await request('GET', '/v1/settings')).body;
  const button = { id: 'btn-send', label: 'Send in Slack', enabled: true, scriptId: collectorId, commandId: 'send', bindings: { target: '{fields.to}', text: '{body}', thread: '' }, confirm: false, onSuccess: 'markSent', storeResult: true, slot: 'send' };
  const prefs = { ...(settings.actionPreferences ?? {}), types: { ...(settings.actionPreferences?.types ?? {}), slack: { ...(settings.actionPreferences?.types?.slack ?? {}), buttons: [button] } } };
  assert.equal((await request('PUT', '/v1/settings', { actionPreferences: prefs })).status, 200);
});

after(async () => {
  await server?.close();
  await core?.stop();
  fs.rmSync(root, { recursive: true, force: true });
});

test('a button runs its command with the exact argv, never through a shell, and marks the item sent', async () => {
  const body = `Hi "Mei" $(touch ${marker}) \`touch ${marker}\`; it's --done`;
  const item = (await request('POST', '/v1/actions', { type: 'slack', title: 'Tell Mei', body, fields: { to: '@mei' } })).body;

  // The Send slot replaces the reserved "Send in Slack · Later".
  const types = (await request('GET', '/v1/action-types')).body;
  const slack = (types.types ?? types).find((t: any) => t.id === 'slack');
  assert.ok(slack.buttons?.some((b: any) => b.id === 'btn-send'));
  assert.ok(!slack.handlers.some((h: any) => h.id === 'send'));
  assert.match(slack.buttons[0].reason ?? '', /needs your OK/, 'not allowed yet');

  // The script needs consent first.
  const before = await request('POST', `/v1/actions/${item.id}/buttons/btn-send/run`, {});
  assert.equal(before.status, 409);
  assert.equal(before.body.error.needsConsent, true);
  const status = (await request('GET', `/v1/collectors/${collectorId}`)).body.status;
  assert.equal((await request('POST', `/v1/collectors/${collectorId}/consent`, { sha256: status.currentSha256 })).status, 200);

  const preview = (await request('POST', `/v1/actions/${item.id}/buttons/btn-send/preview`)).body;
  assert.deepEqual(preview.argv.slice(2), ['send', '--', '@mei', body]);
  assert.deepEqual(preview.problems, []);
  assert.equal(preview.needsApproval, true);

  // Only the app runs buttons; the first run needs the run sheet's approval.
  assert.equal((await request('POST', `/v1/actions/${item.id}/buttons/btn-send/run`, {}, 'cli')).status, 403);
  const unapproved = await request('POST', `/v1/actions/${item.id}/buttons/btn-send/run`, {});
  assert.equal(unapproved.status, 409);
  assert.equal(unapproved.body.error.needsApproval, true);
  assert.deepEqual(unapproved.body.error.preview.argv.slice(2), ["send", "--", "@mei", body]);
  const started = await request('POST', `/v1/actions/${item.id}/buttons/btn-send/run`, { approve: true });
  assert.equal(started.status, 202, JSON.stringify(started.body));

  const done = await settle(item.id);
  const run = done.runs[0];
  assert.equal(run.result, 'success', JSON.stringify(run));
  assert.deepEqual(JSON.parse(run.stdoutTail.split('\n')[0]).argv, ['send', '--', '@mei', body], 'byte for byte');
  assert.equal(fs.existsSync(marker), false, 'nothing in the text ran');
  assert.equal(done.status, 'sent');
  assert.equal(done.external.key, '1759600000.123456');
  assert.equal(done.events.at(-1).event, 'ran');

  // Approved now and confirm is off: the next run starts without the sheet.
  const second = await request('POST', '/v1/actions', { type: 'slack', title: 'Again', body: 'please fail', fields: { to: '#team' } });
  const failed = await request('POST', `/v1/actions/${second.body.id}/buttons/btn-send/run`, {});
  assert.equal(failed.status, 202, JSON.stringify(failed.body));
  const after = await settle(second.body.id);
  assert.equal(after.runs[0].result, 'failed');
  assert.equal(after.runs[0].exitCode, 3);
  assert.match(after.runs[0].stderrTail, /channel not found/);
  assert.match(after.error.message, /^Send in Slack failed \(exit 3\)/);
  assert.equal(after.status, second.body.status, 'a failure keeps the status');

  // The run is in the automation's history as an action run, and never its lastRun.
  const runs = (await request('GET', `/v1/collectors/${collectorId}/runs?limit=5`)).body.runs;
  assert.ok(runs.every((r: any) => r.trigger === 'action'));
  assert.equal((await request('GET', `/v1/collectors/${collectorId}`)).body.status.lastRun, null);
});

test('a pattern miss is shown in the preview and refuses the run', async () => {
  const item = (await request('POST', '/v1/actions', { type: 'slack', title: 'Tell Mei', body: 'hi', fields: { to: '@' } })).body;
  const preview = (await request('POST', `/v1/actions/${item.id}/buttons/btn-send/preview`)).body;
  assert.match(preview.problems[0], /“@” isn’t #channel, @handle or an ID/);
  assert.equal((await request('POST', `/v1/actions/${item.id}/buttons/btn-send/run`, { approve: true })).status, 400);
});

test('a plain name is never sent: it asks who they are, and a remembered name resolves the next item', async () => {
  const item = (await request('POST', '/v1/actions', { type: 'slack', title: 'Tell Aditya', body: 'hi', fields: { to: 'Aditya Pradhan' } })).body;
  const where = (await request('GET', `/v1/actions/${item.id}/slack-target`)).body;
  assert.equal(where.target, null);
  assert.equal(where.ask, 'Who is Aditya Pradhan in Slack?');
  const preview = (await request('POST', `/v1/actions/${item.id}/buttons/btn-send/preview`)).body;
  assert.deepEqual(preview.problems, ['Distill doesn’t know who Aditya Pradhan is in Slack yet. Add their @handle or ID in the To row.'], 'plain words, not the pattern line');
  const refused = await request('POST', `/v1/actions/${item.id}/buttons/btn-send/run`, { approve: true });
  assert.equal(refused.status, 400);
  assert.doesNotMatch(refused.body.error.message, /target:|isn’t #channel/);

  // A name that isn't a handle is refused; a bare handle gets its @.
  assert.equal((await request('PUT', '/v1/slack-people', { name: 'Aditya Pradhan', target: 'Aditya P' })).status, 400);
  const saved = await request('PUT', '/v1/slack-people', { name: 'Aditya Pradhan', target: 'aditya' });
  assert.equal(saved.status, 200, JSON.stringify(saved.body));
  assert.equal(saved.body.target, '@aditya');
  assert.deepEqual((await request('GET', '/v1/slack-people')).body.map((p: any) => [p.name, p.target]), [['Aditya Pradhan', '@aditya']]);

  const next = (await request('POST', '/v1/actions', { type: 'slack', title: 'Tell Aditya again', body: 'hello', fields: { to: 'aditya pradhan' } })).body;
  const resolved = (await request('GET', `/v1/actions/${next.id}/slack-target`)).body;
  assert.deepEqual([resolved.kind, resolved.target, resolved.name], ['person', '@aditya', 'aditya pradhan']);
  const ok = (await request('POST', `/v1/actions/${next.id}/buttons/btn-send/preview`)).body;
  assert.deepEqual(ok.problems, []);
  assert.deepEqual(ok.argv.slice(2), ['send', '--', '@aditya', 'hello']);
  assert.equal((await request('GET', `/v1/actions/${next.id}`)).body.fields.to, 'aditya pradhan', 'the item keeps the name');

  // Another vault doesn't see it; forgetting asks again.
  assert.deepEqual((await request('GET', `/v1/slack-people?vault=${encodeURIComponent(path.join(root, 'elsewhere'))}`)).body, []);
  assert.deepEqual((await request('POST', '/v1/slack-people/forget', { name: 'ADITYA PRADHAN' })).body, { forgotten: true });
  assert.equal((await request('GET', `/v1/actions/${next.id}/slack-target`)).body.target, null);
  assert.equal((await request('GET', '/v1/slack-people')).status, 200);
});

test('a thread reply goes to the link’s channel with --thread, and never as a top-level post', async () => {
  const link = 'https://acme.slack.com/archives/C0123ABCD/p1759600000123456';
  const item = (await request('POST', '/v1/actions', { type: 'slack', title: 'Reply', body: 'on it', fields: { to: '#eng', thread: link } })).body;
  const where = (await request('GET', `/v1/actions/${item.id}/slack-target`)).body;
  assert.deepEqual([where.kind, where.target, where.threadTs], ['thread', 'C0123ABCD', '1759600000.123456']);
  // The button leaves thread empty: refused rather than posted to the channel.
  const refused = (await request('POST', `/v1/actions/${item.id}/buttons/btn-send/preview`)).body;
  assert.deepEqual(refused.problems, ['This message replies in a thread, but Send in Slack doesn’t fill in a thread. Edit the button and set thread to {fields.thread}.']);

  const settings = (await request('GET', '/v1/settings')).body;
  const slack = settings.actionPreferences.types.slack;
  const buttons = slack.buttons.map((b: any) => (b.id === 'btn-send' ? { ...b, bindings: { ...b.bindings, thread: '{fields.thread}' } } : b));
  const prefs = { ...settings.actionPreferences, types: { ...settings.actionPreferences.types, slack: { ...slack, buttons } } };
  assert.equal((await request('PUT', '/v1/settings', { actionPreferences: prefs })).status, 200);
  const preview = (await request('POST', `/v1/actions/${item.id}/buttons/btn-send/preview`)).body;
  assert.deepEqual(preview.problems, []);
  assert.deepEqual(preview.argv.slice(2), ['send', '--thread', '1759600000.123456', '--', 'C0123ABCD', 'on it']);

  // Without a thread the same button leaves --thread out.
  const plain = (await request('POST', '/v1/actions', { type: 'slack', title: 'Post', body: 'hi', fields: { to: '#eng' } })).body;
  assert.deepEqual((await request('POST', `/v1/actions/${plain.id}/buttons/btn-send/preview`)).body.argv.slice(2), ['send', '--', '#eng', 'hi']);
});

test('a commands-only automation never collects', async () => {
  assert.equal((await request('POST', `/v1/collectors/${collectorId}/run`)).status, 400);
});
