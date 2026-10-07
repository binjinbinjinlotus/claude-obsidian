/**
 * Where a Slack message goes (action-buttons.md): the To row's resolution, typed handles and the
 * remembered names. The cases file is shared with DistillKit's SlackTargetTests.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { CoreError } from '../contracts.js';
import { normalizeSlackTarget, normalName, parseThread, resolveSlackTarget, SlackPeople, vaultKey } from './slack-target.js';

const here = path.dirname(fileURLToPath(import.meta.url));
const shared = JSON.parse(fs.readFileSync(path.join(here, 'slack-target.cases.json'), 'utf8')) as {
  people: Record<string, string>;
  cases: { to: string; thread?: string; expect: Record<string, unknown> }[];
  typed: { in: string; out: string | null }[];
};

describe('where a Slack message goes', () => {
  test('every shared case resolves the same way (DistillKit passes the same file)', () => {
    for (const c of shared.cases) {
      const got = resolveSlackTarget(c.to, c.thread ?? null, (n) => shared.people[n]);
      assert.deepEqual({ ...got }, c.expect, `${c.to} / ${c.thread ?? ''}`);
    }
  });

  test('only an exact name matches: "Mei" is not "Mei Tanaka"', () => {
    const lookup = (n: string) => ({ 'mei tanaka': '@mei' })[n];
    assert.equal(resolveSlackTarget('Mei', null, lookup).target, null);
    assert.equal(resolveSlackTarget('MEI  tanaka', null, lookup).target, '@mei');
    assert.equal(normalName('  Mei \t Tanaka '), 'mei tanaka');
  });

  test('a message link gives the channel and the ts; a reply link gives its thread’s parent', () => {
    assert.deepEqual(parseThread('https://acme.slack.com/archives/C0123ABCD/p1759600000123456'), { channel: 'C0123ABCD', ts: '1759600000.123456' });
    assert.deepEqual(parseThread('https://app.slack.com/archives/G0ABC/p1759600111000222?thread_ts=1759600000.123456&cid=G0ABC'), { channel: 'G0ABC', ts: '1759600000.123456' });
    assert.equal(parseThread('https://example.com/archives/C0123ABCD/p1759600000123456'), undefined, 'not Slack');
    assert.equal(parseThread('https://evilslack.com/archives/C0123ABCD/p1759600000123456'), undefined, 'the host is slack.com exactly');
    assert.equal(parseThread('https://slack.com@evil.io/archives/C0123ABCD/p1759600000123456'), undefined);
    assert.equal(parseThread('yesterday’s thread'), undefined);
  });

  test('a typed handle gets its @; anything else is refused in plain words', () => {
    for (const t of shared.typed) {
      if (t.out === null) assert.throws(() => normalizeSlackTarget(t.in), (e: unknown) => e instanceof CoreError && e.code === 'invalid_request');
      else assert.equal(normalizeSlackTarget(t.in), t.out);
    }
    assert.throws(() => normalizeSlackTarget('Aditya Pradhan'), /isn’t an @handle, a #channel or a Slack ID/);
  });
});

describe('where a Slack message goes: edges', () => {
  const lookup = (n: string) => ({ 'aditya pradhan': '@aditya', 'ops room': 'C0123ABCD', 'mei tanaka': 'U01C2D3E4' })[n];

  test('a thread is a link, a ts, or a channel and a ts; anything around or after it is not', () => {
    assert.deepEqual(parseThread('  1759600000.123456\n'), { ts: '1759600000.123456' });
    assert.deepEqual(parseThread('C0123ABCD   1759600000.123456'), { channel: 'C0123ABCD', ts: '1759600000.123456' });
    assert.deepEqual(parseThread('#eng 1759600000.123456'), { channel: '#eng', ts: '1759600000.123456' });
    assert.deepEqual(parseThread('http://acme.slack.com/archives/D0123/p1759600000123456#x'), { channel: 'D0123', ts: '1759600000.123456' });
    assert.deepEqual(parseThread('https://acme.slack.com/archives/C0123ABCD/p1759600111000222?cid=C0123ABCD&thread_ts=1759600000.123456'), { channel: 'C0123ABCD', ts: '1759600000.123456' }, 'thread_ts as the last parameter');
    assert.deepEqual(parseThread('https://acme.slack.com/archives/C0123ABCD/p1759600111000222?xthread_ts=1759600000.123456'), { channel: 'C0123ABCD', ts: '1759600111.000222' }, 'only a whole thread_ts parameter');
    for (const bad of [
      '', '   ', '1759600000.1234567', '17596000001.123456', 'x #eng 1759600000.123456', '#eng 1759600000.1234567', 'U0123 1759600000.123456', 'C0 1759600000.123456',
      'see https://acme.slack.com/archives/C0123ABCD/p1759600000123456',
      'https://acme.slack.com/archives/C0123ABCD/p17596000001234567',
      'https://acme.slack.com/archives/C0123ABCD/p1759600000123456 and more',
    ]) assert.equal(parseThread(bad), undefined, bad);
  });

  test('a thread that is not a Slack message link says why, about the trimmed text', () => {
    const problem = (thread: string) => resolveSlackTarget('#eng', thread, lookup).problem;
    assert.equal(problem(' the standup thread '), '“the standup thread” isn’t a Slack message link, so Distill can’t tell which thread to reply in.');
    assert.match(problem('https://slack.com/messages/C0123ABCD')!, /isn’t a Slack message link/, 'slack.com itself is Slack');
    assert.match(problem('https://a.b.slack.com/messages/C0123ABCD')!, /isn’t a Slack message link/);
    assert.match(problem('see https://evil.io/x')!, /isn’t a Slack message link/, 'a link in the middle of text has no host');
    assert.match(problem('http://evil.io/x')!, /isn’t a link on slack\.com/);
    assert.equal(resolveSlackTarget('#eng', 'http://evil.io/x', lookup).target, null);
  });

  test('a link keeps the remembered name the To row used; no To row is asked for first', () => {
    assert.deepEqual(resolveSlackTarget('Aditya Pradhan', 'https://acme.slack.com/archives/C0123ABCD/p1759600000123456', lookup), {
      kind: 'thread', written: 'Aditya Pradhan', target: 'C0123ABCD', threadTs: '1759600000.123456', name: 'Aditya Pradhan',
    });
    assert.equal(resolveSlackTarget(null, undefined, lookup).problem, 'Choose who gets it first.');
  });

  test('IDs must be whole: lower case or a prefix is a name, not an ID', () => {
    for (const w of ['C0123abcd', 'XC0123ABCD', 'U0456efgh']) {
      const t = resolveSlackTarget(w, null, lookup);
      assert.equal(t.target, null, w);
      assert.equal(t.ask, `Who is ${w} in Slack?`, w);
    }
  });

  test('a remembered channel ID is a channel; a remembered user ID is a person', () => {
    assert.deepEqual(resolveSlackTarget('Ops room', null, lookup), { kind: 'channel', written: 'Ops room', target: 'C0123ABCD', name: 'Ops room' });
    assert.deepEqual(resolveSlackTarget('Mei Tanaka', null, lookup), { kind: 'person', written: 'Mei Tanaka', target: 'U01C2D3E4', name: 'Mei Tanaka' });
  });

  test('typed handles: only a whole lower-case handle gets an @; the refusal quotes the trimmed text', () => {
    for (const bad of ['Team #general', 'mei/tanaka', 'mei tanaka', 'Mei']) assert.throws(() => normalizeSlackTarget(bad), CoreError, bad);
    assert.throws(() => normalizeSlackTarget('  Bad Name '), (e: unknown) => e instanceof CoreError && e.message.startsWith('“Bad Name” isn’t'));
    assert.equal(normalizeSlackTarget('C0123ABCD'), 'C0123ABCD');
  });

  test('a vault key is the first 16 hex characters of the resolved path’s SHA-256', () => {
    assert.match(vaultKey('/vaults/work'), /^[0-9a-f]{16}$/);
    assert.equal(vaultKey('/vaults/work/../work'), vaultKey('/vaults/work'));
    assert.notEqual(vaultKey('/vaults/home'), vaultKey('/vaults/work'));
  });
});

describe('remembered Slack names', () => {
  function tmp(): string {
    return fs.mkdtempSync(path.join(os.tmpdir(), 'distill-slack-people-'));
  }

  test('a name is remembered per vault, survives a restart, and can be changed or forgotten', () => {
    const dir = tmp();
    const file = path.join(dir, 'actions', 'slack-people.json');
    const at = new Date('2026-10-06T12:00:00Z');
    const a = new SlackPeople(file);
    a.remember('/vaults/work', 'Aditya  Pradhan', '@aditya', at);
    a.remember('/vaults/home', 'Aditya Pradhan', '@adi', at);
    const b = new SlackPeople(file);
    assert.equal(b.lookup('/vaults/work', 'aditya pradhan'), '@aditya');
    assert.equal(b.lookup('/vaults/home', 'Aditya Pradhan'), '@adi', 'each vault has its own');
    assert.equal(b.lookup('/vaults/other', 'Aditya Pradhan'), undefined);
    assert.equal(b.lookup(null, 'Aditya Pradhan'), undefined, 'no vault, no names');
    assert.deepEqual(b.list('/vaults/work'), [{ vaultPath: path.resolve('/vaults/work'), name: 'Aditya Pradhan', target: '@aditya', savedAt: at.toISOString() }]);
    assert.equal(b.list().length, 2);
    b.remember('/vaults/work', 'aditya pradhan', 'U0456EFGH', at);
    assert.equal(new SlackPeople(file).lookup('/vaults/work', 'Aditya Pradhan'), 'U0456EFGH', 'changed, not added');
    assert.equal(b.forget('/vaults/work', 'ADITYA PRADHAN'), true);
    assert.equal(b.forget('/vaults/work', 'Aditya Pradhan'), false);
    assert.equal(new SlackPeople(file).lookup('/vaults/work', 'Aditya Pradhan'), undefined);
    assert.equal(new SlackPeople(file).lookup('/vaults/home', 'Aditya Pradhan'), '@adi');
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(raw.version, 1);
    assert.ok(raw.vaults[vaultKey('/vaults/home')], 'keyed by the vault id');
    fs.rmSync(dir, { recursive: true, force: true });
  });

  test('a file this build can’t read is set aside before a save; unknown keys survive', () => {
    const dir = tmp();
    const file = path.join(dir, 'slack-people.json');
    fs.writeFileSync(file, '{ not json');
    const p = new SlackPeople(file);
    assert.equal(p.lookup('/v', 'x'), undefined);
    p.remember('/v', 'Mei', '@mei', new Date());
    const copies = fs.readdirSync(dir).filter((f) => f.startsWith('slack-people.json.unreadable-'));
    assert.equal(copies.length, 1);
    assert.equal(fs.readFileSync(path.join(dir, copies[0]!), 'utf8'), '{ not json');

    fs.writeFileSync(file, JSON.stringify({ version: 1, future: { keep: true }, vaults: { [vaultKey('/v')]: { vaultPath: '/v', extra: 1, people: { odd: 'not an entry', mei: { name: 'Mei', target: '@mei', savedAt: 'x' } } } } }));
    const q = new SlackPeople(file);
    q.remember('/v', 'Aditya', '@aditya', new Date());
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(raw.future, { keep: true });
    assert.equal(raw.vaults[vaultKey('/v')].extra, 1);
    assert.equal(raw.vaults[vaultKey('/v')].people.odd, 'not an entry', 'an entry it can’t read is kept');
    assert.deepEqual(q.list('/v').map((x) => x.name), ['Aditya', 'Mei']);
    fs.rmSync(dir, { recursive: true, force: true });
  });

  test('looking up or forgetting in an unknown vault writes nothing for it', () => {
    const dir = tmp();
    const file = path.join(dir, 'slack-people.json');
    const p = new SlackPeople(file);
    assert.equal(p.lookup('/vaults/other', 'Mei'), undefined);
    assert.equal(p.forget('/vaults/gone', 'Mei'), false);
    assert.equal(fs.existsSync(file), false, 'nothing saved');
    p.remember('/vaults/work', '  Mei   Tanaka ', '@mei', new Date('2026-10-06T00:00:00Z'));
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(Object.keys(raw.vaults), [vaultKey('/vaults/work')]);
    assert.deepEqual(p.list(), [{ vaultPath: path.resolve('/vaults/work'), name: 'Mei Tanaka', target: '@mei', savedAt: '2026-10-06T00:00:00.000Z' }]);
    fs.rmSync(dir, { recursive: true, force: true });
  });

  test('list skips entries it can’t read and sorts by name', () => {
    const dir = tmp();
    const file = path.join(dir, 'slack-people.json');
    fs.writeFileSync(file, JSON.stringify({ version: 1, vaults: {
      nul: null,
      nopeople: { vaultPath: '/a' },
      nopath: { people: { x: { name: 'X', target: '@x' } } },
      [vaultKey('/v')]: { vaultPath: '/v', people: { z: { name: 'Zed', target: '@zed', savedAt: 's' }, n: null, half: { name: 'Half' }, t: { target: '@t' }, a: { name: 'Ann', target: '@ann' } } },
    } }));
    assert.deepEqual(new SlackPeople(file).list(), [
      { vaultPath: '/v', name: 'Ann', target: '@ann', savedAt: '' },
      { vaultPath: '/v', name: 'Zed', target: '@zed', savedAt: 's' },
    ]);
    fs.writeFileSync(file, JSON.stringify({ version: 1, vaults: [] }));
    const q = new SlackPeople(file);
    assert.deepEqual(q.list(), []);
    assert.equal(fs.readdirSync(dir).filter((f) => f.includes('.unreadable-')).length, 1, 'vaults that are not an object: set aside');
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
