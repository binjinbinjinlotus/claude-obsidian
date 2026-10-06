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
});
