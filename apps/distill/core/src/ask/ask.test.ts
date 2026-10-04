import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import type {
  AgentRunner,
  AITask,
  CoreEvent,
  RunnerCapability,
  RunRequest,
  RunResult,
  RunnerRegistry,
  Settings,
} from '../contracts.js';
import { runnerSupports } from '../contracts.js';
import { createAskService } from './index.js';
import { ASK_OUTPUT_SCHEMA } from './prompt.js';

// ───────────── fixtures ─────────────

const ASK_CAPS: RunnerCapability[] = ['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput'];

class FakeRunner implements AgentRunner {
  readonly displayName: string;
  readonly capabilities: ReadonlySet<RunnerCapability>;
  readonly models = [{ id: 'haiku', label: 'Haiku' }];
  readonly effortLevels = ['low', 'high'];
  readonly defaultModel = 'haiku';
  requests: RunRequest[] = [];
  reply: (req: RunRequest) => Partial<RunResult> = () => ({});

  constructor(
    readonly id: string,
    caps: RunnerCapability[] = ASK_CAPS,
  ) {
    this.displayName = id;
    this.capabilities = new Set(caps);
  }
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    const session = 'start' in request.session ? request.session.start : request.session.resume;
    return {
      sessionID: session,
      resultText: 'plain text',
      isError: false,
      costUSD: 0.0123,
      denials: [],
      raw: '{}',
      ...this.reply(request),
    };
  }
}

function registry(...runners: AgentRunner[]): RunnerRegistry {
  return {
    all: () => runners,
    get: (id) => runners.find((r) => r.id === id),
    candidates: (task: AITask, settings: Settings) =>
      runners.filter((r) => settings.enabledRunners.includes(r.id) && runnerSupports(r, task)),
  };
}

function page(fm: string[], body = 'Body.'): string {
  return ['---', ...fm, '---', '', body, ''].join('\n');
}

interface Fixture {
  vault: string; // real path
  productRoot: string;
  stateDir: string;
  settings: Settings;
}

// Every fixture root is removed once the file's tests finish, so repeated runs
// do not pile distill-ask-* directories into the shared system temp root.
const fixtureRoots: string[] = [];
after(() => {
  for (const root of fixtureRoots) rmSync(root, { recursive: true, force: true });
});

function fixture(): Fixture {
  const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'distill-ask-')));
  fixtureRoots.push(root);
  const vault = path.join(root, 'vault');
  const productRoot = path.join(root, 'product');
  mkdirSync(path.join(productRoot, 'skills', 'wiki-query'), { recursive: true });
  writeFileSync(path.join(productRoot, 'skills', 'wiki-query', 'SKILL.md'), '# skill\n');
  const write = (rel: string, text: string) => {
    mkdirSync(path.dirname(path.join(vault, rel)), { recursive: true });
    writeFileSync(path.join(vault, rel), text);
  };
  write('wiki/hot.md', page(['type: meta', 'title: Hot Cache', 'tags:', '  - meta']));
  write('wiki/sources/Sencha Slack.md', page(['type: source', 'title: Sencha thread', 'source_type: slack', 'tags:', '  - tea/green']));
  write('wiki/sources/Oolong Paper.md', page(['type: source', 'title: Oolong paper', 'source_type: Paper', 'tags: [tea, research]']));
  write('wiki/sources/Standup.md', page(['type: source', 'title: Standup', 'source_type: meeting', 'tags:', '  - "#work"']));
  write(
    'wiki/concepts/Green tea.md',
    page(['type: concept', 'title: Green tea', 'tags:', '  - concept', 'sources:', '  - "[[Sencha Slack]]"']),
  );
  write('wiki/.hidden/Secret.md', page(['title: Secret', 'tags:', '  - tea']));
  // A symlinked page is ignored by the scan.
  symlinkSync(path.join(vault, 'wiki/sources/Standup.md'), path.join(vault, 'wiki/Linked.md'));
  const settings: Settings = {
    vaults: [{ path: vault, queueDirectory: path.join(root, 'queue') }],
    activeVaultPath: vault,
    batchIntervalMinutes: 10,
    settleSeconds: 10,
    model: 'sonnet',
    claudePath: '/nonexistent/claude',
    pythonPath: '/usr/bin/python3',
    productRoot,
    extraAllowedTools: [],
    autoProcessEnabled: true,
    enabledRunners: ['claude-code'],
    taskDefaults: {},
  };
  return { vault, productRoot, stateDir: path.join(root, 'state', 'ask'), settings };
}

function service(fx: Fixture, ...runners: AgentRunner[]) {
  return createAskService({ getSettings: () => fx.settings, runners: registry(...runners), stateDir: fx.stateDir });
}

const structured = (citations: { n: number; path: string; title?: string }[], answer = 'Answer [1].', gaps: string[] = []) => ({
  answer,
  citations: citations.map((c) => ({ title: '', ...c })),
  gaps,
});

// ───────────── tests ─────────────

test('unfiltered ask: read-only tools, plugin dir, schema, new session', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  runner.reply = () => ({ structured: structured([{ n: 1, path: 'wiki/sources/Sencha Slack.md', title: 'Sencha' }], 'Brew at 70C [1].', ['No data on cold brew.']) });
  const res = await service(fx, runner).ask({ question: '  How hot for sencha?  ' });

  assert.equal(runner.requests.length, 1);
  const req = runner.requests[0]!;
  assert.deepEqual(req.allowedTools, ['Skill', 'Read', 'Glob', 'Grep']);
  for (const tool of req.allowedTools) assert.ok(!/^(Edit|Write|Bash|MultiEdit|NotebookEdit)/.test(tool));
  // cwd is an empty Ask workspace, not the vault (reads inside cwd bypass Read rules).
  assert.equal(req.workingDirectory, path.join(fx.stateDir, 'workspace'));
  assert.equal(req.pluginDirectory, fx.productRoot);
  assert.deepEqual(req.readableDirectories, [fx.vault, fx.productRoot]);
  assert.equal(req.environment?.CLAUDE_OBSIDIAN_VAULT, fx.vault);
  assert.deepEqual(JSON.parse(req.outputSchema!), ASK_OUTPUT_SCHEMA);
  assert.match(req.prompt, /claude-obsidian:wiki-query/);
  assert.match(req.prompt, /How hot for sencha\?$/);
  assert.match(req.systemPrompt!, /only from the vault/);
  assert.ok('start' in req.session);
  assert.deepEqual(req.selection, { runnerID: 'claude-code', model: 'sonnet' });

  assert.equal(res.answer, 'Brew at 70C [1].');
  assert.deepEqual(res.citations, [{ n: 1, path: 'wiki/sources/Sencha Slack.md', title: 'Sencha' }]);
  assert.deepEqual(res.gaps, ['No data on cold brew.']);
  assert.equal(res.costUSD, 0.0123);
  assert.deepEqual(res.selection, { runnerID: 'claude-code', model: 'sonnet' });

  const saved = JSON.parse(readFileSync(path.join(fx.stateDir, `${res.conversationID}.json`), 'utf8'));
  assert.equal(saved.sessionID, (req.session as { start: string }).start);
  assert.equal(saved.vaultPath, fx.vault);
  assert.equal(saved.turns, 1);
});

test('selection: task default, then request override', async () => {
  const fx = fixture();
  fx.settings.taskDefaults.ask = { runnerID: 'claude-code', model: 'opus', effort: 'high' };
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  await svc.ask({ question: 'q' });
  assert.deepEqual(runner.requests[0]!.selection, { runnerID: 'claude-code', model: 'opus', effort: 'high' });
  await svc.ask({ question: 'q', selection: { runnerID: 'claude-code', model: 'haiku' } });
  assert.deepEqual(runner.requests[1]!.selection, { runnerID: 'claude-code', model: 'haiku' });
});

test('follow-up resumes the same session; a model override keeps the session', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  const first = await svc.ask({ question: 'first', selection: { runnerID: 'claude-code', model: 'haiku' } });
  const second = await svc.ask({ question: 'second', conversationID: first.conversationID });
  const third = await svc.ask({
    question: 'third',
    conversationID: first.conversationID,
    selection: { runnerID: 'claude-code', model: 'opus' },
  });
  const sessionID = (runner.requests[0]!.session as { start: string }).start;
  assert.deepEqual(runner.requests[1]!.session, { resume: sessionID });
  assert.deepEqual(runner.requests[1]!.selection, { runnerID: 'claude-code', model: 'haiku' });
  assert.deepEqual(runner.requests[2]!.session, { resume: sessionID });
  assert.equal(runner.requests[2]!.selection.model, 'opus');
  assert.equal(second.conversationID, first.conversationID);
  assert.equal(third.selection.model, 'opus');
  assert.doesNotMatch((third.notices ?? []).join(' '), /new session/);
  const saved = JSON.parse(readFileSync(path.join(fx.stateDir, `${first.conversationID}.json`), 'utf8'));
  assert.equal(saved.turns, 3);
  assert.equal(saved.selection.model, 'opus');
});

test('follow-up on another runner starts a new session and says so', async () => {
  const fx = fixture();
  fx.settings.enabledRunners = ['claude-code', 'other'];
  const a = new FakeRunner('claude-code');
  const b = new FakeRunner('other');
  const svc = service(fx, a, b);
  const first = await svc.ask({ question: 'q' });
  const res = await svc.ask({
    question: 'q2',
    conversationID: first.conversationID,
    selection: { runnerID: 'other', model: 'x' },
  });
  assert.equal(b.requests.length, 1);
  assert.ok('start' in b.requests[0]!.session);
  assert.notEqual((b.requests[0]!.session as { start: string }).start, (a.requests[0]!.session as { start: string }).start);
  assert.match(res.notices?.[0] ?? '', /^Started a new session: the runner changed from claude-code to other/);
  assert.equal(res.answer, 'plain text');
  assert.equal(res.conversationID, first.conversationID);
});

test('a client-chosen id starts a new chat; invalid ids are rejected', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  const res = await svc.ask({ question: 'q', conversationID: 'client-chat-1' });
  assert.equal(res.conversationID, 'client-chat-1');
  assert.ok('start' in runner.requests[0]!.session, 'a new session');
  assert.equal((await svc.getConversation('client-chat-1'))?.turnCount, 1);
  await svc.ask({ question: 'again', conversationID: 'client-chat-1' });
  assert.ok('resume' in runner.requests[1]!.session, 'the same id continues the chat');
  await assert.rejects(svc.ask({ question: 'q', conversationID: '../escape' }), /invalid conversation id/);
  await assert.rejects(svc.ask({ question: 'q', conversationID: '' }), /invalid conversation id/);
});

test('unsupported, disabled and unknown runners give clear errors', async () => {
  const fx = fixture();
  fx.settings.enabledRunners = ['claude-code', 'api'];
  const api = new FakeRunner('api', ['structuredOutput', 'vision']);
  const svc = service(fx, new FakeRunner('claude-code'), api, new FakeRunner('off'));
  await assert.rejects(svc.ask({ question: 'q', selection: { runnerID: 'api', model: 'm' } }), /cannot answer from the vault/);
  await assert.rejects(svc.ask({ question: 'q', selection: { runnerID: 'off', model: 'm' } }), /not enabled/);
  await assert.rejects(svc.ask({ question: 'q', selection: { runnerID: 'ghost', model: 'm' } }), /unknown runner/);
  assert.equal(api.requests.length, 0);
});

test('label filter: exact Read rules plus Skill, no Glob/Grep, pages listed in prompt', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const res = await service(fx, runner).ask({ question: 'q', labels: ['#Tea'] });
  const req = runner.requests[0]!;
  const expected = ['wiki/sources/Oolong Paper.md', 'wiki/sources/Sencha Slack.md'];
  assert.deepEqual(req.allowedTools, ['Skill', ...expected.map((p) => `Read(/${path.join(fx.vault, p)})`)]);
  assert.ok(req.allowedTools.every((t) => t === 'Skill' || t.startsWith('Read(//')));
  // The vault is not an added directory in filtered mode.
  assert.deepEqual(req.readableDirectories, [fx.productRoot]);
  assert.equal(req.workingDirectory, path.join(fx.stateDir, 'workspace'));
  for (const p of expected) assert.ok(req.prompt.includes(`- ${p}`));
  assert.ok(!req.prompt.includes('Secret'));
  assert.ok(!req.prompt.includes('Linked.md'));
  assert.equal(res.answer, 'plain text');
});

test('source group expands; group plus member narrows; labels AND sources; OR within', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  const allowedPaths = (i: number) =>
    runner.requests[i]!.allowedTools.filter((t) => t !== 'Skill').map((t) => path.relative(fx.vault, t.slice(6, -1)));

  // Discussion = slack + meeting + ...; Green tea matches through its `sources:` link.
  await svc.ask({ question: 'q', sources: ['discussion'] });
  assert.deepEqual(allowedPaths(0), ['wiki/concepts/Green tea.md', 'wiki/sources/Sencha Slack.md', 'wiki/sources/Standup.md']);

  // Discussion + Meeting narrows to meeting.
  await svc.ask({ question: 'q', sources: ['Discussion', 'meeting'] });
  assert.deepEqual(allowedPaths(1), ['wiki/sources/Standup.md']);

  // OR within sources.
  await svc.ask({ question: 'q', sources: ['paper', 'meeting'] });
  assert.deepEqual(allowedPaths(2), ['wiki/sources/Oolong Paper.md', 'wiki/sources/Standup.md']);

  // Labels AND sources: tea AND discussion.
  await svc.ask({ question: 'q', labels: ['tea'], sources: ['discussion'] });
  assert.deepEqual(allowedPaths(3), ['wiki/sources/Sencha Slack.md']);

  // OR within labels.
  await svc.ask({ question: 'q', labels: ['work', 'research'] });
  assert.deepEqual(allowedPaths(4), ['wiki/sources/Oolong Paper.md', 'wiki/sources/Standup.md']);
});

test('zero matches short-circuits without calling the runner', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  const res = await svc.ask({ question: 'q', labels: ['tea'], sources: ['meeting'] });
  assert.equal(runner.requests.length, 0);
  assert.match(res.answer, /No notes in the vault match labels tea and sources meeting/);
  assert.deepEqual(res.citations, []);
  assert.equal(res.costUSD, 0);
  // The conversation exists; a follow-up starts the first real session.
  await svc.ask({ question: 'q2', conversationID: res.conversationID });
  assert.ok('start' in runner.requests[0]!.session);
});

test('citations: missing, escaping and out-of-filter paths are dropped; names resolve', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  runner.reply = () => ({
    structured: JSON.stringify(
      structured([
        { n: 1, path: 'wiki/sources/Sencha Slack.md', title: 'S' },
        { n: 2, path: 'wiki/sources/Nope.md' },
        { n: 3, path: '../etc/passwd' },
        { n: 4, path: path.join(fx.vault, 'wiki/sources/Oolong Paper.md') },
        { n: 5, path: '[[Standup]]' },
        { n: 6, path: './wiki/concepts/Green tea' },
      ]),
    ),
  });
  const svc = service(fx, runner);
  const res = await svc.ask({ question: 'q' });
  assert.deepEqual(res.citations, [
    { n: 1, path: 'wiki/sources/Sencha Slack.md', title: 'S' },
    { n: 4, path: 'wiki/sources/Oolong Paper.md', title: 'Oolong paper' },
    { n: 5, path: 'wiki/sources/Standup.md', title: 'Standup' },
    { n: 6, path: 'wiki/concepts/Green tea.md', title: 'Green tea' },
  ]);

  const filtered = await svc.ask({ question: 'q', labels: ['tea'] });
  assert.deepEqual(
    filtered.citations.map((c) => c.path),
    ['wiki/sources/Sencha Slack.md', 'wiki/sources/Oolong Paper.md'],
  );
});

test('runner error throws and does not persist a conversation', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  runner.reply = () => ({ isError: true, resultText: 'boom' });
  const svc = service(fx, runner);
  await assert.rejects(svc.ask({ question: 'q' }), /claude-code failed: boom/);
  assert.deepEqual(existsSync(fx.stateDir) ? readdirSync(fx.stateDir).filter((f) => f.endsWith('.json')) : [], []);
});

test('vault resolution fails closed', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  fx.settings.activeVaultPath = null;
  fx.settings.vaults.push({ path: '/elsewhere', queueDirectory: '/q' });
  await assert.rejects(service(fx, runner).ask({ question: 'q' }), /several vaults/);
  fx.settings.vaults = [];
  await assert.rejects(service(fx, runner).ask({ question: 'q' }), /no vault/);
  await assert.rejects(service(fx, runner).ask({ question: 'q', vaultPath: fx.productRoot }), /not a claude-obsidian vault/);
  const res = await service(fx, runner).ask({ question: 'q', vaultPath: fx.vault });
  assert.ok(res.conversationID);
});

test('missing productRoot skill is a clear error', async () => {
  const fx = fixture();
  fx.settings.productRoot = '/nonexistent';
  await assert.rejects(service(fx, new FakeRunner('claude-code')).ask({ question: 'q' }), /not a claude-obsidian checkout/);
});

test('filtered: productRoot is not readable when the vault lives inside it', async () => {
  const fx = fixture();
  fx.settings.productRoot = path.dirname(fx.vault);
  mkdirSync(path.join(fx.settings.productRoot, 'skills', 'wiki-query'), { recursive: true });
  writeFileSync(path.join(fx.settings.productRoot, 'skills', 'wiki-query', 'SKILL.md'), '# skill\n');
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  await svc.ask({ question: 'q', labels: ['tea'] });
  assert.deepEqual(runner.requests[0]!.readableDirectories, []);
  await svc.ask({ question: 'q' });
  assert.deepEqual(runner.requests[1]!.readableDirectories, [fx.vault, fx.settings.productRoot]);
});

test('state directory inside the vault is refused', async () => {
  const fx = fixture();
  const svc = createAskService({
    getSettings: () => fx.settings,
    runners: registry(new FakeRunner('claude-code')),
    stateDir: path.join(fx.vault, '.vault-meta', 'ask'),
  });
  await assert.rejects(svc.ask({ question: 'q' }), /must not be inside the vault/);
});

test('changing the filter mid-conversation starts a new session; same filter resumes', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  const first = await svc.ask({ question: 'q' });
  const second = await svc.ask({ question: 'q2', conversationID: first.conversationID, labels: ['Tea'] });
  const third = await svc.ask({ question: 'q3', conversationID: first.conversationID, labels: ['#tea'] });
  const fourth = await svc.ask({ question: 'q4', conversationID: first.conversationID, sources: ['discussion'] });
  const fifth = await svc.ask({ question: 'q5', conversationID: first.conversationID, sources: ['slack', 'meeting', 'email', 'in-person', 'jira-comment', 'github-review'] });
  const [a, b, c, d, e] = runner.requests;
  assert.ok('start' in b!.session);
  assert.notEqual((b!.session as { start: string }).start, (a!.session as { start: string }).start);
  assert.match((second.notices ?? []).join(' '), /filter changed/);
  assert.deepEqual(c!.session, { resume: (b!.session as { start: string }).start });
  assert.doesNotMatch((third.notices ?? []).join(' '), /new session/);
  assert.ok('start' in d!.session);
  assert.match((fourth.notices ?? []).join(' '), /filter changed/);
  // The same expanded source set is the same scope.
  assert.deepEqual(e!.session, { resume: (d!.session as { start: string }).start });
  assert.doesNotMatch((fifth.notices ?? []).join(' '), /new session/);
  assert.equal(a!.workingDirectory, e!.workingDirectory);
});

// ───────────── v2: label match, unconfirmed labels, notices ─────────────

function addPage(fx: Fixture, rel: string, fm: string[]): void {
  mkdirSync(path.dirname(path.join(fx.vault, rel)), { recursive: true });
  writeFileSync(path.join(fx.vault, rel), page(fm));
}

function allowedOf(fx: Fixture, req: RunRequest): string[] {
  return req.allowedTools.filter((t) => t !== 'Skill').map((t) => path.relative(fx.vault, t.slice(6, -1)));
}

class Clock {
  constructor(public t = Date.parse('2026-09-01T00:00:00Z')) {}
  now = () => new Date(this.t);
  advance(ms: number) {
    this.t += ms;
  }
}

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

function svcWith(fx: Fixture, runner: AgentRunner, extra: { now?: () => Date; events?: CoreEvent[] } = {}) {
  const events = extra.events;
  return createAskService({
    getSettings: () => fx.settings,
    runners: registry(runner),
    stateDir: fx.stateDir,
    now: extra.now,
    emit: events ? (e) => events.push(e) : undefined,
  });
}

const hasCode = (code: string) => (e: unknown) => (e as { code?: string }).code === code;

test('labelMatch: any = OR, all = every label (nested tags count); request overrides settings default', async () => {
  const fx = fixture();
  addPage(fx, 'wiki/sources/Green Research.md', ['title: Green research', 'tags: [tea/green, research]']);
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);

  await svc.ask({ question: 'q', labels: ['tea', 'research'] });
  assert.deepEqual(allowedOf(fx, runner.requests[0]!), [
    'wiki/sources/Green Research.md',
    'wiki/sources/Oolong Paper.md',
    'wiki/sources/Sencha Slack.md',
  ]);

  await svc.ask({ question: 'q', labels: ['tea', '#Research'], labelMatch: 'all' });
  assert.deepEqual(allowedOf(fx, runner.requests[1]!), ['wiki/sources/Green Research.md', 'wiki/sources/Oolong Paper.md']);
  assert.match(runner.requests[1]!.prompt, /labels \(all of\): tea, #Research/);

  // Labels AND sources still holds with all.
  await svc.ask({ question: 'q', labels: ['tea', 'research'], labelMatch: 'all', sources: ['paper'] });
  assert.deepEqual(allowedOf(fx, runner.requests[2]!), ['wiki/sources/Oolong Paper.md']);

  // The settings default applies when the request omits it; the request wins otherwise.
  fx.settings.askPreferences = { labelMatch: 'all' };
  const res = await svc.ask({ question: 'q', labels: ['tea', 'research'] });
  assert.equal(allowedOf(fx, runner.requests[3]!).length, 2);
  await svc.ask({ question: 'q', labels: ['tea', 'research'], labelMatch: 'any' });
  assert.equal(allowedOf(fx, runner.requests[4]!).length, 3);

  const stored = await svc.getConversation(res.conversationID);
  assert.equal(stored?.turns[0]?.request.labelMatch, 'all');
  assert.equal(stored?.turns[0]?.request.includeUnconfirmed, true);
});

test('includeUnconfirmed: on counts AI labels and says how many; off leaves them out', async () => {
  const fx = fixture();
  addPage(fx, 'wiki/sources/Matcha.md', ['title: Matcha', 'source_type: slack', 'tags: [tea]', 'labels_reviewed: false', 'labels_by: ai']);
  addPage(fx, 'wiki/sources/Hojicha.md', ['title: Hojicha', 'tags: [tea]', 'labels_reviewed: true']);
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);

  const on = await svc.ask({ question: 'q', labels: ['tea'] });
  assert.deepEqual(allowedOf(fx, runner.requests[0]!), [
    'wiki/sources/Hojicha.md',
    'wiki/sources/Matcha.md',
    'wiki/sources/Oolong Paper.md',
    'wiki/sources/Sencha Slack.md',
  ]);
  assert.deepEqual(on.notices, ['Limited to 4 pages (1 unconfirmed).']);
  assert.equal(on.answer, 'plain text');

  const off = await svc.ask({ question: 'q', labels: ['tea'], includeUnconfirmed: false });
  assert.deepEqual(allowedOf(fx, runner.requests[1]!), [
    'wiki/sources/Hojicha.md',
    'wiki/sources/Oolong Paper.md',
    'wiki/sources/Sencha Slack.md',
  ]);
  assert.deepEqual(off.notices, ['Limited to 3 pages. Left out 1 page whose labels are not confirmed yet.']);

  // Settings default off; sources are not affected by label confirmation.
  fx.settings.askPreferences = { includeUnconfirmed: false };
  await svc.ask({ question: 'q', sources: ['slack'] });
  assert.ok(allowedOf(fx, runner.requests[2]!).includes('wiki/sources/Matcha.md'));
  await svc.ask({ question: 'q', labels: ['tea'] });
  assert.ok(!allowedOf(fx, runner.requests[3]!).includes('wiki/sources/Matcha.md'));

  // Only unconfirmed pages match: no run, and the notice explains why.
  addPage(fx, 'wiki/sources/Kukicha.md', ['title: Kukicha', 'tags: [twig]', 'labels_reviewed: False']);
  const none = await svc.ask({ question: 'q', labels: ['twig'] });
  assert.equal(runner.requests.length, 4);
  assert.match(none.answer, /No notes in the vault match labels twig/);
  assert.deepEqual(none.notices, ['1 page would match with unconfirmed labels; Include unconfirmed is off.']);

  // Unfiltered asks have no scope notice.
  const all = await svc.ask({ question: 'q' });
  assert.deepEqual(all.notices, []);
});

test('scope: flipping includeUnconfirmed or labelMatch starts a new session; v1 scope strings are unchanged', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  const first = await svc.ask({ question: 'q', labels: ['tea'] });
  const saved = JSON.parse(readFileSync(path.join(fx.stateDir, `${first.conversationID}.json`), 'utf8'));
  assert.equal(saved.scope, JSON.stringify({ labels: ['tea'], sources: [] }));

  // labelMatch all with a single label is the same scope.
  const same = await svc.ask({ question: 'q', conversationID: first.conversationID, labels: ['tea'], labelMatch: 'all' });
  assert.ok('resume' in runner.requests[1]!.session);
  assert.doesNotMatch((same.notices ?? []).join(' '), /new session/);

  const flipped = await svc.ask({ question: 'q', conversationID: first.conversationID, labels: ['tea'], includeUnconfirmed: false });
  assert.ok('start' in runner.requests[2]!.session);
  assert.match(flipped.notices?.[0] ?? '', /filter changed/);

  const all = await svc.ask({
    question: 'q',
    conversationID: first.conversationID,
    labels: ['tea', 'research'],
    labelMatch: 'all',
    includeUnconfirmed: false,
  });
  assert.ok('start' in runner.requests[3]!.session);
  assert.match(all.notices?.[0] ?? '', /filter changed/);
});

test('taxonomy comes from settings.sourceTaxonomy', async () => {
  const fx = fixture();
  fx.settings.sourceTaxonomy = [{ id: 'chat', label: 'Chat', sources: [{ id: 'slack', label: 'Slack' }] }];
  const runner = new FakeRunner('claude-code');
  const svc = service(fx, runner);
  await svc.ask({ question: 'q', sources: ['chat'] });
  assert.deepEqual(allowedOf(fx, runner.requests[0]!), ['wiki/concepts/Green tea.md', 'wiki/sources/Sencha Slack.md']);
  // The default groups are gone, so "discussion" is a literal source type with no matches.
  const res = await svc.ask({ question: 'q', sources: ['discussion'] });
  assert.equal(runner.requests.length, 1);
  assert.match(res.answer, /No notes in the vault match/);
});

// ───────────── v2: history ─────────────

test('history: turns stored, list newest first, get, title, events', async () => {
  const fx = fixture();
  const clock = new Clock();
  const events: CoreEvent[] = [];
  const runner = new FakeRunner('claude-code');
  runner.reply = (req) => ({ structured: structured([{ n: 1, path: 'wiki/sources/Standup.md' }], `A: ${req.prompt.split('\n').at(-1)}`) });
  const svc = svcWith(fx, runner, { now: clock.now, events });

  const long = 'How should I brew sencha so that it does not get bitter, and what water temperature works best for it overall?';
  const a = await svc.ask({ question: `  ${long}  ` });
  clock.advance(HOUR);
  const b = await svc.ask({ question: 'Second chat' });
  clock.advance(HOUR);
  await svc.ask({ question: 'Follow-up', conversationID: a.conversationID, labels: ['work'] });

  const list = await svc.listConversations();
  assert.deepEqual(
    list.map((c) => c.id),
    [a.conversationID, b.conversationID],
  );
  const first = list[0]!;
  assert.ok(first.title.length <= 80);
  assert.ok(first.title.endsWith('…'));
  assert.ok(long.startsWith(first.title.slice(0, -1)));
  assert.equal(list[1]!.title, 'Second chat');
  assert.equal(first.turnCount, 2);
  assert.equal(first.pinned, false);
  assert.equal(first.vaultPath, fx.vault);
  assert.equal(first.createdAt, '2026-09-01T00:00:00.000Z');
  assert.equal(first.updatedAt, '2026-09-01T02:00:00.000Z');

  const convo = await svc.getConversation(a.conversationID);
  assert.equal(convo?.turns.length, 2);
  assert.equal(convo?.turns[0]?.request.question, long);
  assert.equal(convo?.turns[0]?.askedAt, '2026-09-01T00:00:00.000Z');
  assert.deepEqual(convo?.turns[0]?.response, a);
  assert.deepEqual(convo?.turns[1]?.request.labels, ['work']);
  assert.deepEqual(convo?.turns[1]?.response.citations, [{ n: 1, path: 'wiki/sources/Standup.md', title: 'Standup' }]);
  assert.equal(await svc.getConversation('missing'), undefined);

  const saved = events.flatMap((e) => (e.type === 'conversation' ? [e] : []));
  assert.equal(saved.length, 3);
  assert.equal(saved[2]!.conversation.turnCount, 2);
  assert.equal(saved[2]!.deleted, undefined);
});

test('history: zero-match turns are kept; pin does not touch updatedAt; delete', async () => {
  const fx = fixture();
  const clock = new Clock();
  const events: CoreEvent[] = [];
  const runner = new FakeRunner('claude-code');
  const svc = svcWith(fx, runner, { now: clock.now, events });

  const res = await svc.ask({ question: 'nothing', labels: ['nope'] });
  assert.equal((await svc.getConversation(res.conversationID))?.turnCount, 1);

  clock.advance(DAY);
  const pinned = await svc.setConversationPinned(res.conversationID, true);
  assert.equal(pinned.pinned, true);
  assert.equal(pinned.updatedAt, '2026-09-01T00:00:00.000Z');
  assert.deepEqual(events.at(-1), { type: 'conversation', conversation: pinned });
  assert.equal((await svc.listConversations())[0]?.pinned, true);

  await svc.deleteConversation(res.conversationID);
  const last = events.at(-1);
  assert.ok(last?.type === 'conversation' && last.deleted === true && last.conversation.id === res.conversationID);
  assert.deepEqual(await svc.listConversations(), []);
  await assert.rejects(svc.deleteConversation(res.conversationID), hasCode('not_found'));
  await assert.rejects(svc.setConversationPinned(res.conversationID, true), hasCode('not_found'));
  await assert.rejects(svc.deleteConversation('../x'), hasCode('invalid_request'));
  await assert.rejects(svc.ask({ question: '  ' }), hasCode('invalid_request'));
});

test('retention: sweeps old non-pinned chats on creation and at most hourly; never when Keep history is off', async () => {
  const fx = fixture();
  const clock = new Clock();
  const runner = new FakeRunner('claude-code');
  const svc = svcWith(fx, runner, { now: clock.now });
  const old = await svc.ask({ question: 'old' });
  const pinned = await svc.ask({ question: 'pinned' });
  await svc.setConversationPinned(pinned.conversationID, true);
  const unpinned = await svc.ask({ question: 'unpinned later' });
  await svc.setConversationPinned(unpinned.conversationID, true);
  clock.advance(5 * DAY);
  const recent = await svc.ask({ question: 'recent' });

  // Day 11: chats from day 0 are past 10 days. Unpinning does not refresh them.
  clock.advance(6 * DAY);
  await svc.setConversationPinned(unpinned.conversationID, false);
  const ids = (await svc.listConversations()).map((c) => c.id).sort();
  assert.deepEqual(ids, [pinned.conversationID, recent.conversationID].sort());
  assert.ok(!existsSync(path.join(fx.stateDir, `${old.conversationID}.json`)));
  assert.ok(!existsSync(path.join(fx.stateDir, `${unpinned.conversationID}.json`)));

  // A shorter window makes `recent` (6 days) old, but the last sweep was under an hour ago.
  fx.settings.askPreferences = { historyDays: 3 };
  clock.advance(30 * 60 * 1000);
  assert.equal((await svc.listConversations()).length, 2);

  // Keep history off: nothing is swept by age, even after the hour.
  fx.settings.askPreferences = { keepHistory: false, historyDays: 3 };
  clock.advance(HOUR);
  assert.equal((await svc.listConversations()).length, 2);

  // Back on: a new service sweeps on creation and emits the deletion.
  fx.settings.askPreferences = { keepHistory: true, historyDays: 3 };
  const events: CoreEvent[] = [];
  const fresh = svcWith(fx, runner, { now: clock.now, events });
  assert.deepEqual(
    (await fresh.listConversations()).map((c) => c.id),
    [pinned.conversationID],
  );
  assert.ok(events.some((e) => e.type === 'conversation' && e.deleted === true && e.conversation.id === recent.conversationID));
});

test('retention: an invalid historyDays falls back to the default', async () => {
  const fx = fixture();
  const clock = new Clock();
  const svc = svcWith(fx, new FakeRunner('claude-code'), { now: clock.now });
  await svc.ask({ question: 'q' });
  fx.settings.askPreferences = { historyDays: 0 };
  clock.advance(9 * DAY);
  await svc.sweepHistory();
  assert.equal((await svc.listConversations()).length, 1);
  clock.advance(2 * DAY);
  await svc.sweepHistory();
  assert.equal((await svc.listConversations()).length, 0);
});

test('legacy v1 records load, list and continue; corrupt and temp files are skipped', async () => {
  const fx = fixture();
  const events: CoreEvent[] = [];
  const runner = new FakeRunner('claude-code');
  const clock = new Clock(Date.parse('2026-09-30T00:00:00Z'));
  const workspace = path.join(fx.stateDir, 'workspace');
  mkdirSync(workspace, { recursive: true });
  const legacy = {
    conversationID: 'legacy-1',
    sessionID: 'sess-legacy',
    selection: { runnerID: 'claude-code', model: 'haiku' },
    vaultPath: fx.vault,
    workingDirectory: realpathSync(workspace),
    scope: '',
    createdAt: '2026-09-29T00:00:00.000Z',
    updatedAt: '2026-09-29T01:00:00.000Z',
    turns: 2,
    costUSD: 0.5,
  };
  writeFileSync(path.join(fx.stateDir, 'legacy-1.json'), JSON.stringify(legacy));
  writeFileSync(path.join(fx.stateDir, 'broken.json'), '{nope');
  writeFileSync(path.join(fx.stateDir, 'legacy-1.json.123.abc.tmp'), '{}');
  const svc = svcWith(fx, runner, { now: clock.now, events });

  assert.deepEqual(await svc.listConversations(), [
    {
      id: 'legacy-1',
      title: 'Earlier conversation',
      vaultPath: fx.vault,
      createdAt: legacy.createdAt,
      updatedAt: legacy.updatedAt,
      pinned: false,
      turnCount: 2,
    },
  ]);
  assert.ok(events.some((e) => e.type === 'log' && e.level === 'warn' && /broken/.test(e.message)));
  assert.deepEqual((await svc.getConversation('legacy-1'))?.turns, []);

  await svc.ask({ question: 'Continue please', conversationID: 'legacy-1' });
  assert.deepEqual(runner.requests[0]!.session, { resume: 'sess-legacy' });
  const after = await svc.getConversation('legacy-1');
  assert.equal(after?.title, 'Continue please');
  assert.equal(after?.turnCount, 1);
  assert.equal(after?.createdAt, legacy.createdAt);
  const saved = JSON.parse(readFileSync(path.join(fx.stateDir, 'legacy-1.json'), 'utf8'));
  assert.equal(saved.turns, 3);
  assert.ok(Math.abs(saved.costUSD - 0.5123) < 1e-9);
});

test('retention: a sweep skips a chat with a turn in flight instead of waiting for it', async () => {
  const fx = fixture();
  const clock = new Clock();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => (release = resolve));
  class SlowRunner extends FakeRunner {
    slow = false;
    override async run(request: RunRequest): Promise<RunResult> {
      if (this.slow) await gate;
      return super.run(request);
    }
  }
  const runner = new SlowRunner('claude-code');
  const svc = svcWith(fx, runner, { now: clock.now });
  const x = await svc.ask({ question: 'x' });
  const other = await svc.ask({ question: 'other' });

  runner.slow = true;
  const followUp = svc.ask({ question: 'x2', conversationID: x.conversationID });
  await new Promise((r) => setTimeout(r, 20)); // let the follow-up take the lock
  clock.advance(11 * DAY); // both chats are old; a sweep is due
  const listed = await Promise.race([
    svc.listConversations(),
    new Promise<'timeout'>((r) => setTimeout(() => r('timeout'), 500)),
  ]);
  assert.notEqual(listed, 'timeout');
  // `other` was swept; X was skipped because its turn is running.
  assert.deepEqual(
    (listed as { id: string }[]).map((c) => c.id),
    [x.conversationID],
  );
  assert.ok(!existsSync(path.join(fx.stateDir, `${other.conversationID}.json`)));
  release();
  await followUp;
  assert.equal((await svc.getConversation(x.conversationID))?.turnCount, 2);
});

// ───────────── v3: progress and Stop ─────────────

test('progress: "Reading your notes" with runner/model, then finished; errors finish with the error', async () => {
  const fx = fixture();
  const events: CoreEvent[] = [];
  const runner = new FakeRunner('claude-code');
  runner.reply = () => ({ structured: structured([{ n: 1, path: 'wiki/sources/Standup.md' }]) });
  const svc = svcWith(fx, runner, { events });
  const res = await svc.ask({ question: 'q', conversationID: 'p-1', selection: { runnerID: 'claude-code', model: 'haiku' } });
  const progress = events.flatMap((e) => (e.type === 'progress' ? [e.progress] : []));
  assert.deepEqual(
    progress.map((p) => [p.key, p.kind, p.message, p.runnerID, p.model, !!p.finished, p.error ?? null]),
    [
      ['ask:p-1', 'ask', 'Reading your notes', 'claude-code', 'haiku', false, null],
      ['ask:p-1', 'ask', 'Reading your notes', 'claude-code', 'haiku', true, null],
    ],
  );
  assert.equal(progress[0]!.startedAt, progress[1]!.startedAt);
  assert.equal(res.conversationID, 'p-1');

  events.length = 0;
  runner.reply = () => ({ isError: true, resultText: 'overloaded' });
  await assert.rejects(svc.ask({ question: 'q2', conversationID: 'p-1' }), /overloaded/);
  const failed = events.flatMap((e) => (e.type === 'progress' ? [e.progress] : []));
  assert.equal(failed.length, 2);
  assert.equal(failed[1]!.finished, true);
  assert.equal(failed[1]!.error, 'overloaded');

  events.length = 0;
  await svc.ask({ question: 'nothing', labels: ['no-such-label'] });
  assert.equal(events.filter((e) => e.type === 'progress').length, 0, 'a zero-match answer runs no runner');
});

class HangingRunner extends FakeRunner {
  started!: Promise<void>;
  private markStarted!: () => void;
  constructor() {
    super('claude-code');
    this.started = new Promise((r) => (this.markStarted = r));
  }
  override async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    this.markStarted();
    return new Promise((_, reject) => {
      const fail = () => reject(Object.assign(new Error('cancelled'), { name: 'AbortError' }));
      if (request.signal?.aborted) fail();
      request.signal?.addEventListener('abort', fail, { once: true });
    });
  }
}

test('cancelAsk stops the in-flight turn: invalid_state "Stopped", nothing stored, finished progress', async () => {
  const fx = fixture();
  const events: CoreEvent[] = [];
  const runner = new HangingRunner();
  const svc = svcWith(fx, runner, { events });
  await svc.cancelAsk('idle-chat'); // no-op when idle
  const pending = svc.ask({ question: 'slow one', conversationID: 'stop-me' });
  await runner.started;
  assert.ok(runner.requests[0]!.signal, 'the run gets an AbortSignal');
  await svc.cancelAsk('stop-me');
  await assert.rejects(pending, (e: unknown) => (e as { code?: string }).code === 'invalid_state' && (e as Error).message === 'Stopped');
  assert.equal(await svc.getConversation('stop-me'), undefined, 'the question is not stored');
  assert.deepEqual(await svc.listConversations(), []);
  assert.ok(!events.some((e) => e.type === 'conversation'));
  const last = events.filter((e) => e.type === 'progress').at(-1);
  assert.ok(last?.type === 'progress');
  assert.deepEqual([last.progress.key, last.progress.finished, last.progress.error, last.progress.message], ['ask:stop-me', true, 'Stopped', 'Stopped']);
});

test('cancelAsk on a follow-up keeps the earlier turns untouched', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = svcWith(fx, runner);
  const first = await svc.ask({ question: 'first' });
  const before = await svc.getConversation(first.conversationID);
  let release!: () => void;
  const started = new Promise<void>((r) => (release = r));
  runner.run = async (request: RunRequest) => {
    release();
    return new Promise<RunResult>((_, reject) => request.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
  };
  const pending = svc.ask({ question: 'second', conversationID: first.conversationID });
  await started;
  await svc.cancelAsk(first.conversationID);
  await assert.rejects(pending, /Stopped/);
  assert.deepEqual(await svc.getConversation(first.conversationID), before);
});

test('a Stop sent before the turn starts still stops it', async () => {
  const fx = fixture();
  const runner = new FakeRunner('claude-code');
  const svc = svcWith(fx, runner);
  const pending = svc.ask({ question: 'q', conversationID: 'early' });
  await svc.cancelAsk('early');
  await assert.rejects(pending, /Stopped/);
  assert.equal(runner.requests.length, 0);
});
