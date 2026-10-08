/**
 * Action context (action-context.md): actions found in the batch before Review, each pointing at the
 * original's lines and the wiki; added when their source's pages apply; Ask actions get the closest
 * lines of the cited pages' archived original; additive decoding; no duplicates on re-read or repair.
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { ActionItem, AgentRunner, AskConversation, Job, JobActionsSummary, RunRequest, RunResult, RunnerCapability, Settings } from '../contracts.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { MemorySecretStore } from '../runners/secrets.js';
import { decodeSettings } from '../store/settings.js';
import { DRAFT_SCHEMA, FIND_SCHEMA } from './ai.js';
import { closestLines, coveredLines, locateQuote, parseLines, sourceLineOf, windowAround, windowsOf } from './context.js';
import { createActionsService, type ActionsService } from './index.js';
import { ActionStore, decodeAction, encodeAction } from './store.js';
import { loadFound } from './batch.js';

type Answer = (req: RunRequest) => Partial<RunResult>;

class FakeRunner implements AgentRunner {
  readonly displayName: string;
  readonly kind = 'modelAPI' as const;
  readonly models = [{ id: 'sonnet', label: 'Sonnet' }];
  readonly effortLevels = [];
  readonly defaultModel = 'sonnet';
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['structuredOutput']);
  readonly requests: RunRequest[] = [];
  find: Answer = () => ({ structured: { items: [] } });
  constructor(readonly id = 'fake') {
    this.displayName = id;
  }
  problems() {
    return [];
  }
  async run(req: RunRequest): Promise<RunResult> {
    this.requests.push(req);
    await new Promise((r) => setImmediate(r));
    const a = req.outputSchema === FIND_SCHEMA ? this.find(req) : req.outputSchema === DRAFT_SCHEMA ? { structured: { title: '', body: 'Draft.', fields: [] } } : { structured: { body: 'x' } };
    return { resultText: '', isError: false, costUSD: 0, denials: [], raw: '{}', ...a };
  }
}

let tmp: string;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-action-context-')));
});
afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

interface H {
  service: ActionsService;
  runner: FakeRunner;
  other: FakeRunner;
  settings: Settings;
  vault: string;
  jobs: Map<string, Job>;
  summaries: Map<string, JobActionsSummary>;
  conversations: Map<string, AskConversation>;
}

function harness(): H {
  const root = path.join(tmp, `h${Math.random().toString(36).slice(2)}`);
  const vault = path.join(root, 'vault');
  for (const d of ['inbox', 'wiki/sources', 'wiki/meta/ledgers', '.raw/captured']) fs.mkdirSync(path.join(vault, d), { recursive: true });
  const runner = new FakeRunner('fake');
  const other = new FakeRunner('other');
  const settings = decodeSettings({
    vaults: [{ path: vault, queueDirectory: path.join(root, 'queue') }],
    activeVaultPath: vault,
    enabledRunners: ['fake', 'other'],
    taskDefaults: Object.fromEntries(['actionFind', 'actionDraft', 'actionImprove'].map((t) => [t, { runnerID: 'fake', model: 'sonnet' }])),
  });
  const h: H = {
    runner,
    other,
    settings,
    vault,
    jobs: new Map(),
    summaries: new Map(),
    conversations: new Map(),
    service: undefined as unknown as ActionsService,
  };
  h.service = createActionsService({
    emit: () => undefined,
    getSettings: () => structuredClone(h.settings),
    runners: createRunnerRegistry([runner, other]),
    file: path.join(root, 'state', 'actions.json'),
    stateDir: path.join(root, 'state'),
    secrets: new MemorySecretStore(),
    now: () => new Date('2026-10-05T09:00:00Z'),
    getConversation: async (id) => h.conversations.get(id),
    setJobActions: (id, s) => h.summaries.set(id, s),
    getJob: (id) => h.jobs.get(id),
  });
  return h;
}

const MEETING = [
  '# Tomasz and Jin',
  '',
  '### **00:01:00**',
  'Tomasz: the payment client retries forever when the gateway times out.',
  'Jin: that is how we got the outage last week.',
  'Tomasz: I will file a ticket in PAY to cap the retries at 3.',
  'Jin: and tell Mei in Slack so the on-call knows.',
  '',
  '### **00:05:00**',
  'Small talk about the weather.',
];

const PAGE = `---
type: source
title: "Tomasz and Jin 2026-09-30"
source_path: inbox/meeting.md
---

# Tomasz and Jin 2026-09-30

## Retries
The payment client retries without a limit; this caused last week's outage. Decision: cap at 3.

## People
Tomasz, Jin, Mei.
`;

const FOUND = {
  items: [
    {
      type: 'jira', title: 'Cap payment client retries at 3', fields: [{ key: 'project', value: 'PAY' }],
      why: 'Unlimited retries caused last week’s outage', quote: 'I will file a ticket in PAY to cap the retries at 3.', lines: '6-6',
      wiki: [{ path: 'wiki/sources/meeting.md', heading: 'Retries' }],
    },
    {
      type: 'slack', title: 'Tell Mei about the retry cap', fields: [{ key: 'to', value: 'Mei' }],
      why: 'The on-call needs to know', quote: 'tell Mei in Slack so the on-call knows', lines: '2-3',
      wiki: [{ path: 'wiki/sources/nope.md', heading: 'X' }],
    },
  ],
};

function batch(h: H, id: string, files: string[], extra: Partial<Job> = {}): Job {
  const j: Job = {
    id, kind: 'ingest', vaultPath: h.vault, files, sessionID: 's', model: 'sonnet', state: 'awaitingApproval',
    createdAt: '2026-10-05T08:00:00Z', updatedAt: '2026-10-05T08:00:00Z', turns: [], grantedTools: [], changedPaths: [], ...extra,
  };
  h.jobs.set(id, j);
  return j;
}

const reviewInfo = (pages: { page: string; source: string; text: string }[]) => ({
  pages: pages.map((p) => ({ ...p, title: /title: "(.+)"/.exec(p.text)?.[1] ?? p.page })),
  written: pages.map((p) => ({ path: p.page, text: p.text })),
});

const sha = (s: string) => createHash('sha256').update(s).digest('hex');

describe('locating lines (pure)', () => {
  test('the quote is found by the core; the model’s range is only a hint', () => {
    assert.deepEqual(locateQuote(MEETING, 'I will file a ticket in PAY to cap the retries at 3', [1, 2]), [6, 6]);
    assert.deepEqual(locateQuote(MEETING, '“the payment client retries forever” when the gateway', null), [4, 4]);
    // Across lines (and an empty line between).
    assert.deepEqual(locateQuote(MEETING, 'cap the retries at 3. Jin: and tell Mei', null), [6, 7]);
    assert.equal(locateQuote(MEETING, 'something nobody said in this meeting', null), undefined);
    assert.equal(locateQuote(MEETING, 'short', null), undefined, 'too short to locate');
  });

  test('an appendix line of a long line maps back to its source line', () => {
    const copy = ['a', 'b → L2↪', 'c', 'L2↪ the rest of line two'];
    assert.equal(sourceLineOf(copy, 4, 3), 2);
    assert.equal(sourceLineOf(copy, 3, 3), 3);
  });

  test('windows cover every line, in order', () => {
    const lines = Array.from({ length: 5000 }, (_, i) => `line ${i + 1} ${'x'.repeat(60)}`);
    const sections = Array.from({ length: 13 }, (_, k) => ({ from: k * 400 + 1, to: Math.min(5000, (k + 1) * 400) }));
    const w = windowsOf(lines, sections);
    assert.ok(w.length > 1);
    assert.equal(w[0]!.from, 1);
    assert.equal(w.at(-1)!.to, 5000);
    for (let k = 1; k < w.length; k++) assert.equal(w[k]!.from, w[k - 1]!.to + 1);
    assert.equal(coveredLines(w.map((x) => [x.from, x.to])), 5000);
    assert.deepEqual(parseLines('210–214'), [210, 214]);
    assert.deepEqual(parseLines('L88'), [88, 88]);
    assert.equal(parseLines('soon'), undefined);
  });

  test('closest lines for Ask: the window sharing most words, at least 40%', () => {
    const hit = closestLines(MEETING, 'Cap payment client retries at 3 file ticket');
    assert.ok(hit);
    assert.ok(hit.from <= 6 && hit.to >= 4);
    assert.equal(closestLines(MEETING, 'quarterly marketing budget spreadsheet review'), undefined);
  });

  test('a window around lines stays under its size', () => {
    const lines = Array.from({ length: 2000 }, (_, i) => `${i + 1} ${'y'.repeat(50)}`);
    const w = windowAround(lines, 1500, 1500, 25, 2000);
    assert.ok(w.text.length <= 2000);
    assert.ok(w.from <= 1500 && w.to >= 1500);
  });
});

describe('actions.json: additive decoding', () => {
  test('an older item decodes as before; raw and wiki round-trip; a bad lines value is dropped; unknown source keys survive', () => {
    const old = {
      id: 'act-1', type: 'todo', status: 'open', title: 'Book the room', fields: {},
      source: { kind: 'note', jobID: 'job-1', notePath: 'wiki/sources/tea.md', quote: 'I’ll book it' },
      createdAt: '2026-10-01T10:00:00Z', updatedAt: '2026-10-01T10:00:00Z', events: [],
    };
    const a = decodeAction(old)!;
    assert.deepEqual(a.source, { kind: 'note', jobID: 'job-1', notePath: 'wiki/sources/tea.md', quote: 'I’ll book it' });

    const withRaw = {
      ...old,
      source: {
        ...old.source,
        raw: { path: '.raw/captured/abc.md', inboxPath: 'inbox/tea.md', sha256: 'abc', lines: [3, 4], excerpt: 'x', match: 'quote' },
        wiki: [{ path: 'wiki/sources/tea.md', title: 'Tea', heading: 'Plans', excerpt: 'y' }, { nope: 1 }],
        contextNote: null,
        futureKey: { kept: true },
      },
    };
    const b = decodeAction(withRaw)!;
    assert.equal(b.source.kind, 'note');
    const src = b.source as Extract<ActionItem['source'], { kind: 'note' }>;
    assert.deepEqual(src.raw, withRaw.source.raw);
    assert.deepEqual(src.wiki, [withRaw.source.wiki[0]]);
    const encoded = encodeAction(b, withRaw as never) as { source: Record<string, unknown> };
    assert.deepEqual(encoded.source.futureKey, { kept: true }, 'a later build’s key inside source survives a save');
    assert.deepEqual(encoded.source.raw, withRaw.source.raw);

    for (const bad of [[0, 3], [5, 2], ['1', '2'], [1], 'x']) {
      const c = decodeAction({ ...old, source: { ...old.source, raw: { path: 'inbox/a.md', lines: bad, match: 'weird' } } })!;
      const raw = (c.source as Extract<ActionItem['source'], { kind: 'note' }>).raw!;
      assert.equal(raw.lines, undefined, `lines ${JSON.stringify(bad)} dropped`);
      assert.equal(raw.match, undefined);
      assert.equal(raw.path, 'inbox/a.md');
    }
    const ask = decodeAction({ ...old, source: { kind: 'ask', conversationID: 'c1', raw: { lines: [1, 2] }, contextNote: 'wiki only' } })!;
    assert.deepEqual(ask.source, { kind: 'ask', conversationID: 'c1', contextNote: 'wiki only' }, 'a raw ref without a path is dropped');
  });

  test('the store saves and reloads the new fields', () => {
    const file = path.join(tmp, 'actions.json');
    const store = new ActionStore(file);
    const item = decodeAction({
      id: 'act-2', type: 'jira', status: 'pending', title: 'Cap retries', fields: { project: 'PAY' },
      source: { kind: 'note', notePath: 'wiki/sources/m.md', raw: { path: 'inbox/m.md', lines: [6, 6], match: 'quote' }, wiki: [{ path: 'wiki/sources/m.md', heading: 'Retries' }] },
      createdAt: '2026-10-05T09:00:00Z', updatedAt: '2026-10-05T09:00:00Z', events: [],
    })!;
    store.save([item]);
    const [back] = new ActionStore(file).load();
    assert.deepEqual(back!.source, item.source);
  });
});

describe('finding in the batch, before Review', () => {
  function setup(h: H) {
    fs.writeFileSync(path.join(h.vault, 'inbox', 'meeting.md'), MEETING.join('\n') + '\n');
    h.runner.find = () => ({ structured: FOUND });
  }

  test('found while the batch waits in Review: proposals only, nothing in Actions; added when the page applies', async () => {
    const h = harness();
    setup(h);
    const j = batch(h, 'job-1', ['inbox/meeting.md']);
    await h.service.findForReview(j, reviewInfo([{ page: 'wiki/sources/meeting.md', source: 'inbox/meeting.md', text: PAGE }]));
    await h.service.whenIdle();
    const prompt = h.runner.requests[0]!.prompt;
    assert.match(prompt, /<wiki path="wiki\/sources\/meeting.md" title="Tomasz and Jin 2026-09-30">/, 'the page this source became is the wiki context');
    assert.match(prompt, /<source path="inbox\/meeting.md"[^>]* lines="1–10" of="10">/);
    assert.equal(h.runner.requests[0]!.availableTools!.length, 0, 'no tools');
    assert.equal((await h.service.listActions()).length, 0, 'nothing is added before approval');
    const shown = await h.service.jobActions('job-1');
    assert.deepEqual(shown.proposals.map((p) => p.state), ['waiting', 'waiting']);
    assert.equal(shown.summary!.stage, 'review');
    assert.equal(shown.summary!.proposed, 2);
    assert.equal(shown.summary!.lines, 10);
    const jira = shown.proposals.find((p) => p.item.type === 'jira')!.item;
    const src = jira.source as Extract<ActionItem['source'], { kind: 'note' }>;
    assert.equal(src.notePath, 'wiki/sources/meeting.md');
    assert.deepEqual(src.raw?.lines, [6, 6]);
    assert.equal(src.raw?.excerpt, 'Tomasz: I will file a ticket in PAY to cap the retries at 3.');
    assert.equal(src.wiki?.[0]?.path, 'wiki/sources/meeting.md');
    assert.equal(src.wiki?.[0]?.heading, 'Retries');
    assert.match(src.wiki?.[0]?.excerpt ?? '', /cap at 3/);
    const slack = shown.proposals.find((p) => p.item.type === 'slack')!.item;
    const ss = slack.source as Extract<ActionItem['source'], { kind: 'note' }>;
    assert.deepEqual(ss.raw?.lines, [7, 7], 'the model said 2-3; the core found line 7');
    assert.equal(ss.wiki?.some((w) => w.path === 'wiki/sources/nope.md'), false, 'a page that doesn’t exist is dropped');

    // The archive copy exists once the change applied: raw.path points there.
    const content = fs.readFileSync(path.join(h.vault, 'inbox', 'meeting.md'));
    const archived = `.raw/captured/${createHash('sha256').update(content).digest('hex')}.md`;
    fs.writeFileSync(path.join(h.vault, archived), content);
    h.jobs.set('job-1', { ...j, state: 'completed', operationID: 'op-1', changedPaths: ['wiki/sources/meeting.md'], parts: [{ operationID: 'op-1', pages: ['wiki/sources/meeting.md'], labels: 'confirm', at: 'x' }] });
    await h.service.findInJob(h.jobs.get('job-1')!);
    const items = await h.service.listActions();
    assert.equal(items.length, 2);
    assert.ok(items.every((i) => i.status === 'pending'));
    const added = items.find((i) => i.type === 'jira')!.source as Extract<ActionItem['source'], { kind: 'note' }>;
    assert.equal(added.raw?.path, archived);
    assert.equal(added.raw?.inboxPath, 'inbox/meeting.md');
    assert.equal(h.runner.requests.filter((r) => r.outputSchema === FIND_SCHEMA).length, 1, 'not looked through again after apply');
    const after = await h.service.jobActions('job-1');
    assert.deepEqual(after.proposals.map((p) => p.state), ['added', 'added']);
    assert.equal(after.summary!.stage, 'applied');
    assert.equal(after.summary!.pending, 2);
    // Idempotent.
    await h.service.findInJob(h.jobs.get('job-1')!);
    assert.equal((await h.service.listActions()).length, 2);
  });

  test('part of a batch: only the applied source’s actions are added; the rest when their part applies; a removed source never', async () => {
    const h = harness();
    fs.writeFileSync(path.join(h.vault, 'inbox', 'a.md'), 'Ana: I will send the deck to Bo on Monday.\n');
    fs.writeFileSync(path.join(h.vault, 'inbox', 'b.md'), 'Bo: I will book the venue for the offsite.\n');
    fs.writeFileSync(path.join(h.vault, 'inbox', 'c.md'), 'Cy: I will renew the domain before it lapses.\n');
    h.runner.find = (req) => {
      const line = /\n1\t(.+)\n/.exec(req.prompt)![1]!;
      return { structured: { items: [{ type: 'todo', title: line.split(': I will ')[1]!.replace(/\.$/, ''), fields: [], why: 'w', quote: line.split(': ')[1]!, lines: '1-1' }] } };
    };
    const page = (n: string) => ({ page: `wiki/sources/${n}.md`, source: `inbox/${n}.md`, text: `---\ntype: source\ntitle: "${n}"\nsource_path: inbox/${n}.md\n---\n\n# ${n}\n` });
    const j = batch(h, 'job-p', ['inbox/a.md', 'inbox/b.md', 'inbox/c.md']);
    await h.service.findForReview(j, reviewInfo([page('a'), page('b'), page('c')]));
    await h.service.whenIdle();
    assert.equal((await h.service.jobActions('job-p')).proposals.length, 3);

    // Part 1: only a.md's page applied; the batch goes on (pendingPart: b is left for later, c removed).
    const part1 = { operationID: 'op-1', pages: ['wiki/sources/a.md'], labels: 'confirm' as const, at: 'x' };
    h.jobs.set('job-p', { ...j, state: 'completed', operationID: 'op-1', changedPaths: ['wiki/sources/a.md'], parts: [part1], pendingPart: { reason: 'remaining', expected: {}, excluded: [], labels: 'confirm' } });
    await h.service.findInJob(h.jobs.get('job-p')!);
    assert.deepEqual((await h.service.listActions()).map((i) => i.title), ['send the deck to Bo on Monday']);
    assert.deepEqual((await h.service.jobActions('job-p')).proposals.map((p) => p.state), ['added', 'waiting', 'waiting']);

    // Part 2: b applied; the batch is done; c was removed and is not added.
    const part2 = { operationID: 'op-2', pages: ['wiki/sources/b.md'], labels: 'confirm' as const, at: 'y' };
    h.jobs.set('job-p', { ...j, state: 'completed', operationID: 'op-2', changedPaths: ['wiki/sources/a.md', 'wiki/sources/b.md'], parts: [part1, part2] });
    await h.service.findInJob(h.jobs.get('job-p')!);
    assert.deepEqual((await h.service.listActions()).map((i) => i.title).sort(), ['book the venue for the offsite', 'send the deck to Bo on Monday']);
    assert.deepEqual((await h.service.jobActions('job-p')).proposals.map((p) => p.state), ['added', 'added', 'notApplied']);
  });

  test('a rejected batch adds nothing', async () => {
    const h = harness();
    setup(h);
    const j = batch(h, 'job-r', ['inbox/meeting.md']);
    await h.service.findForReview(j, reviewInfo([{ page: 'wiki/sources/meeting.md', source: 'inbox/meeting.md', text: PAGE }]));
    await h.service.whenIdle();
    h.jobs.set('job-r', { ...j, state: 'rejected' });
    await h.service.jobEnded(h.jobs.get('job-r')!);
    await h.service.whenIdle();
    assert.equal((await h.service.listActions()).length, 0);
    assert.deepEqual((await h.service.jobActions('job-r')).proposals.map((p) => p.state), ['notApplied', 'notApplied']);
  });

  test('a re-read or repair of the same content adds nothing again, even what was dismissed, done, or found before raw existed', async () => {
    const h = harness();
    setup(h);
    const content = MEETING.join('\n') + '\n';
    const j = batch(h, 'job-1', ['inbox/meeting.md'], { state: 'completed', operationID: 'op-1', changedPaths: ['wiki/sources/meeting.md'] });
    fs.writeFileSync(path.join(h.vault, 'wiki', 'sources', 'meeting.md'), PAGE);
    await h.service.findInJob(j);
    const first = await h.service.listActions();
    assert.equal(first.length, 2);
    await h.service.dismissActions([first.find((i) => i.type === 'slack')!.id]);
    await h.service.confirmActions([first.find((i) => i.type === 'jira')!.id]);
    await h.service.whenIdle();
    await h.service.performAction(first.find((i) => i.type === 'jira')!.id, 'complete');

    // The repair reads the archived original; the model words things differently this time.
    const archived = `.raw/captured/${sha(content)}.md`;
    fs.writeFileSync(path.join(h.vault, archived), content);
    fs.rmSync(path.join(h.vault, 'inbox', 'meeting.md'));
    h.runner.find = () => ({
      structured: {
        items: [
          { ...FOUND.items[0]!, title: 'Limit the payment client to 3 retries', quote: 'cap the retries at 3' },
          { ...FOUND.items[1]!, title: 'Message Mei about the cap' },
        ],
      },
    });
    const repair = batch(h, 'job-2', [archived], { state: 'completed', operationID: 'op-2', changedPaths: ['wiki/sources/meeting.md'] });
    await h.service.findInJob(repair);
    assert.equal((await h.service.listActions({ status: ['pending', 'open', 'ready'] })).length, 0, 'nothing new');
    const s = h.summaries.get('job-2')!;
    assert.equal(s.found, 0);
    assert.equal(s.duplicates, 2);

    // An item found before this build (no raw, quote only) is a duplicate too.
    const h2 = harness();
    setup(h2);
    fs.writeFileSync(path.join(h2.vault, 'wiki', 'sources', 'meeting.md'), PAGE);
    const legacy = path.join(path.dirname(h2.vault), 'state', 'actions.json');
    fs.mkdirSync(path.dirname(legacy), { recursive: true });
    fs.writeFileSync(legacy, JSON.stringify({
      version: 1, processedJobs: [],
      items: [{
        id: 'act-old', type: 'jira', status: 'done', title: 'Create a ticket for the retry cap', fields: {},
        source: { kind: 'note', jobID: 'job-0', notePath: 'inbox/meeting.md', quote: 'I will file a ticket in PAY to cap the retries at 3.' },
        vaultPath: h2.vault, createdAt: '2026-10-01T10:00:00Z', updatedAt: '2026-10-01T10:00:00Z', events: [{ at: '2026-10-01T10:00:00Z', event: 'done' }],
      }],
    }));
    const h3 = { ...h2 };
    h3.service = createActionsService({
      emit: () => undefined, getSettings: () => structuredClone(h2.settings), runners: createRunnerRegistry([h2.runner]),
      file: legacy, stateDir: path.dirname(legacy), secrets: new MemorySecretStore(), setJobActions: (id, x) => h2.summaries.set(id, x), getJob: (id) => h2.jobs.get(id),
    });
    h2.runner.find = () => ({ structured: { items: [{ ...FOUND.items[0]!, title: 'Cap the retries', quote: 'to cap the retries at 3' }] } });
    await h3.service.findInJob(batch(h2, 'job-3', ['inbox/meeting.md'], { state: 'completed', operationID: 'op-3', changedPaths: ['wiki/sources/meeting.md'] }));
    assert.equal(h2.summaries.get('job-3')!.duplicates, 1, 'the old item’s quote is on the same lines of the same content');
  });

  test('a repair in Review reads .raw/captured/<sha>.md while its page keeps the inbox path: matched by content, added on apply, no repeats', async () => {
    const h = harness();
    const content = MEETING.join('\n') + '\n';
    const s = sha(content);
    const archived = `.raw/captured/${s}.md`;
    fs.writeFileSync(path.join(h.vault, archived), content);
    // The first ingest's ledger record (the inbox file is gone: cleared after it was archived).
    fs.writeFileSync(path.join(h.vault, 'wiki', 'meta', 'ledgers', 'source-ledger.json'), JSON.stringify({
      sources: { 'src-1': { origin: { kind: 'file', locator: archived }, content_sha256: s, pages: ['wiki/sources/meeting.md'] } },
    }));
    h.runner.find = () => ({ structured: FOUND });
    const page = { page: 'wiki/sources/meeting.md', source: 'inbox/meeting.md', text: PAGE };
    const j = batch(h, 'job-rep', [archived]);
    await h.service.findForReview(j, reviewInfo([page]));
    await h.service.whenIdle();
    const shown = await h.service.jobActions('job-rep');
    assert.equal(shown.proposals.length, 2, 'the source is looked through, not dropped');
    assert.ok(shown.proposals.every((p) => p.page === 'wiki/sources/meeting.md'));
    assert.equal(shown.summary!.lines, MEETING.length);
    const part = { operationID: 'op-r', pages: ['wiki/sources/meeting.md'], labels: 'confirm' as const, at: 'x' };
    h.jobs.set('job-rep', { ...j, state: 'completed', operationID: 'op-r', changedPaths: ['wiki/sources/meeting.md'], parts: [part] });
    await h.service.findInJob(h.jobs.get('job-rep')!);
    const items = await h.service.listActions();
    assert.equal(items.length, 2);
    assert.equal((items[0]!.source as Extract<ActionItem['source'], { kind: 'note' }>).raw?.path, archived);

    // The next repair of the same content: duplicates, nothing added.
    const j2 = batch(h, 'job-rep2', [archived]);
    await h.service.findForReview(j2, reviewInfo([page]));
    await h.service.whenIdle();
    assert.deepEqual((await h.service.jobActions('job-rep2')).proposals.map((p) => p.state), ['duplicate', 'duplicate']);
    h.jobs.set('job-rep2', { ...j2, state: 'completed', operationID: 'op-r2', changedPaths: ['wiki/sources/meeting.md'], parts: [{ ...part, operationID: 'op-r2' }] });
    await h.service.findInJob(h.jobs.get('job-rep2')!);
    assert.equal((await h.service.listActions()).length, 2);
  });

  test('a hard-stopped source and the sources a fresh session reads next are not looked through with this part', async () => {
    const h = harness();
    setup(h);
    fs.writeFileSync(path.join(h.vault, 'inbox', 'later.md'), 'Bo: I will renew the domain.\n');
    fs.writeFileSync(path.join(h.vault, 'inbox', 'bad.md'), 'x\n');
    const j = batch(h, 'job-s', ['inbox/meeting.md', 'inbox/later.md', 'inbox/bad.md'], {
      stopped: [{ file: 'inbox/bad.md', reason: 'it isn’t valid UTF-8 text from line 1', at: 'x' }],
      pendingPart: { reason: 'covered', unread: ['inbox/later.md'], expected: {}, excluded: [], labels: 'confirm' },
    });
    await h.service.findForReview(j, reviewInfo([{ page: 'wiki/sources/meeting.md', source: 'inbox/meeting.md', text: PAGE }]));
    await h.service.whenIdle();
    assert.deepEqual(Object.keys(loadFound(j)!.sources), ['inbox/meeting.md']);
  });

  test('Try again in Review after a restart reads the change from the bundle', async () => {
    const h = harness();
    setup(h);
    h.runner.find = () => ({ isError: true, resultText: 'overloaded' });
    const dir = path.join(h.vault, '.vault-meta', 'worker', 'job-t');
    fs.mkdirSync(dir, { recursive: true });
    const bundle = path.join(dir, 'bundle.json');
    fs.writeFileSync(bundle, JSON.stringify({ writes: [{ path: 'wiki/sources/meeting.md', mode: 'create', content: PAGE }] }));
    const j = batch(h, 'job-t', ['inbox/meeting.md'], { approval: { summary: '', questions: [], denials: [], skipped: [], bundlePath: bundle } });
    await h.service.findForReview(j, reviewInfo([{ page: 'wiki/sources/meeting.md', source: 'inbox/meeting.md', text: PAGE }]));
    await h.service.whenIdle();
    // A new service: nothing in memory.
    const restarted = createActionsService({
      emit: () => undefined, getSettings: () => structuredClone(h.settings), runners: createRunnerRegistry([h.runner]),
      file: path.join(path.dirname(h.vault), 'state', 'actions.json'), stateDir: path.join(path.dirname(h.vault), 'state'),
      secrets: new MemorySecretStore(), setJobActions: (id, x) => h.summaries.set(id, x), getJob: (id) => h.jobs.get(id),
    });
    h.runner.find = () => ({ structured: FOUND });
    await restarted.findInJob(j, { retry: true });
    await restarted.whenIdle();
    const after = await restarted.jobActions('job-t');
    assert.equal(after.summary!.status, 'done');
    assert.equal(after.proposals.length, 2);
    assert.equal(after.proposals[0]!.page, 'wiki/sources/meeting.md');
  });

  test('the pass runs on the batch’s own runner when the finding model is another provider', async () => {
    const h = harness();
    setup(h);
    h.settings.actionPreferences = { ...(h.settings.actionPreferences ?? {}), findSelection: { runnerID: 'other', model: 'sonnet' } };
    h.other.find = () => ({ structured: FOUND });
    const j = batch(h, 'job-e', ['inbox/meeting.md'], { runnerID: 'fake' });
    await h.service.findForReview(j, reviewInfo([{ page: 'wiki/sources/meeting.md', source: 'inbox/meeting.md', text: PAGE }]));
    await h.service.whenIdle();
    assert.equal(h.other.requests.length, 0, 'the transcript never goes to the other provider');
    assert.equal(h.runner.requests.length, 1);
  });

  test('a window that fails twice names its lines; Try again in Review looks through only what failed', async () => {
    const h = harness();
    setup(h);
    h.runner.find = () => ({ isError: true, resultText: 'overloaded' });
    const j = batch(h, 'job-f', ['inbox/meeting.md']);
    await h.service.findForReview(j, reviewInfo([{ page: 'wiki/sources/meeting.md', source: 'inbox/meeting.md', text: PAGE }]));
    await h.service.whenIdle();
    const s = (await h.service.jobActions('job-f')).summary!;
    assert.equal(s.status, 'failed');
    assert.match(s.error ?? '', /lines 1–10 weren’t looked through: overloaded/);
    assert.equal(s.lines, 0);
    h.runner.find = () => ({ structured: FOUND });
    await h.service.findInJob(j, { retry: true });
    await h.service.whenIdle();
    const again = await h.service.jobActions('job-f');
    assert.equal(again.summary!.status, 'done');
    assert.equal(again.proposals.length, 2);
    assert.equal(loadFound(j)!.sources['inbox/meeting.md']!.status, 'done');
  });
});

describe('drafts read the original and the wiki', () => {
  test('a new item: the original’s lines around it and its wiki section; an older item: its note centred on the quote', async () => {
    const h = harness();
    // A long note: the action is far past 12,000 characters.
    const lines = Array.from({ length: 900 }, (_, i) => `Line ${i + 1}: notes about the migration plan and its many details.`);
    lines[800] = 'Mei: I will ping Bo in Slack about the cutover window on Thursday.';
    fs.writeFileSync(path.join(h.vault, 'inbox', 'long.md'), lines.join('\n') + '\n');
    fs.writeFileSync(path.join(h.vault, 'wiki', 'sources', 'long.md'), '---\ntitle: "Migration"\n---\n\n# Migration\n\n## Cutover\nThursday 02:00, Bo runs it.\n');
    const created = await h.service.createAction({
      type: 'slack', title: 'Ping Bo about the cutover', body: null,
      source: {
        kind: 'note', notePath: 'wiki/sources/long.md', quote: 'I will ping Bo in Slack about the cutover window',
        raw: { path: 'inbox/long.md', lines: [801, 801], match: 'quote' }, wiki: [{ path: 'wiki/sources/long.md', heading: 'Cutover' }],
      },
      vaultPath: h.vault,
    });
    await h.service.whenIdle();
    const draft = h.runner.requests.find((r) => r.outputSchema === DRAFT_SCHEMA)!.prompt;
    assert.match(draft, /<original path="inbox\/long.md" lines="776–826">/);
    assert.match(draft, /Mei: I will ping Bo in Slack about the cutover window on Thursday\./);
    assert.match(draft, /<wiki path="wiki\/sources\/long.md" heading="Cutover">\n## Cutover\nThursday 02:00, Bo runs it\./);
    assert.ok(created);

    // Older item: no raw; the note is long; the window is centred on the located quote.
    const h2 = harness();
    fs.writeFileSync(path.join(h2.vault, 'inbox', 'long.md'), lines.join('\n') + '\n');
    await h2.service.createAction({
      type: 'slack', title: 'Ping Bo', source: { kind: 'note', notePath: 'inbox/long.md', quote: 'I will ping Bo in Slack about the cutover window' }, vaultPath: h2.vault,
    });
    await h2.service.whenIdle();
    const old = h2.runner.requests.find((r) => r.outputSchema === DRAFT_SCHEMA)!.prompt;
    assert.match(old, /<source>\n\[lines \d+–\d+ of 900\]/);
    assert.match(old, /Mei: I will ping Bo in Slack/, 'the line far past 12,000 characters is in the draft’s context');
  });
});

describe('Ask: raw context from the cited pages', () => {
  function conversation(h: H, cited: string): AskConversation {
    return {
      id: 'conv-1', title: 'Retries', vaultPath: h.vault, createdAt: '2026-10-05T09:00:00Z', updatedAt: '2026-10-05T09:00:00Z', sessionID: 's', pinned: false, turnCount: 1,
      turns: [{
        askedAt: '2026-10-05T09:00:00Z', request: { question: 'What did we decide about retries?' },
        response: { conversationID: 'conv-1', answer: 'Cap the payment client retries at 3 and file a ticket [1].', citations: [{ n: 1, path: cited, title: 'Tomasz and Jin' }], gaps: [], selection: { runnerID: 'fake', model: 'sonnet' }, costUSD: 0 },
      }],
    } as AskConversation;
  }

  test('the cited page’s archived original gives the closest lines', async () => {
    const h = harness();
    const content = MEETING.join('\n') + '\n';
    const s = sha(content);
    fs.writeFileSync(path.join(h.vault, '.raw', 'captured', `${s}.md`), content);
    fs.writeFileSync(path.join(h.vault, 'wiki', 'sources', 'meeting.md'), PAGE);
    fs.writeFileSync(path.join(h.vault, 'wiki', 'meta', 'ledgers', 'source-ledger.json'), JSON.stringify({
      sources: { 'src-1': { origin: { kind: 'file', locator: `.raw/captured/${s}.md` }, content_sha256: s, pages: ['wiki/sources/meeting.md'] } },
    }));
    h.conversations.set('conv-1', conversation(h, 'wiki/sources/meeting.md'));
    h.runner.find = () => ({ structured: { items: [{ type: 'jira', title: 'Cap payment client retries at 3', fields: [], why: 'decided', quote: 'Cap the payment client retries at 3 and file a ticket' }] } });
    await h.service.afterAsk('conv-1');
    await h.service.whenIdle();
    const [item] = await h.service.listActions();
    const src = item!.source as Extract<ActionItem['source'], { kind: 'ask' }>;
    assert.equal(src.raw?.path, `.raw/captured/${s}.md`);
    assert.equal(src.raw?.match, 'closest');
    assert.ok(src.raw?.lines && src.raw.lines[0] <= 6 && src.raw.lines[1] >= 4);
    assert.equal(src.wiki?.[0]?.heading, 'Retries');
    assert.equal(src.contextNote, undefined);
  });

  test('no archived original: wiki only, with the reason', async () => {
    const h = harness();
    fs.writeFileSync(path.join(h.vault, 'wiki', 'sources', 'meeting.md'), PAGE.replace('source_path: inbox/meeting.md\n', ''));
    h.conversations.set('conv-1', conversation(h, 'wiki/sources/meeting.md'));
    h.runner.find = () => ({ structured: { items: [{ type: 'todo', title: 'Cap the retries', fields: [], why: 'decided', quote: 'Cap the payment client retries at 3' }] } });
    await h.service.afterAsk('conv-1');
    await h.service.whenIdle();
    const [item] = await h.service.listActions();
    const src = item!.source as Extract<ActionItem['source'], { kind: 'ask' }>;
    assert.equal(src.raw, undefined);
    assert.equal(src.wiki?.[0]?.path, 'wiki/sources/meeting.md');
    assert.match(src.contextNote ?? '', /no archived original/);
  });
});

describe('plain titles (action-summary.md)', () => {
  test('Markdown leaves source names; emoji stay', async () => {
    const { plainTitle } = await import('./context.js');
    assert.equal(plainTitle('**✍ Quick notes**'), '✍ Quick notes');
    assert.equal(plainTitle('# _Team_ `sync`'), 'Team sync');
    assert.equal(plainTitle('[[Polaris|Polaris stack]] notes'), 'Polaris stack notes');
    assert.equal(plainTitle('[Doc](https://x.y) review'), 'Doc review');
    assert.equal(plainTitle('snake_case_name'), 'snake_case_name');
    assert.equal(plainTitle('**'), '**');
  });
});
