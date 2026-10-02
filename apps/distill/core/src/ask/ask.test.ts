import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import type {
  AgentRunner,
  AITask,
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

function fixture(): Fixture {
  const root = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'distill-ask-')));
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
  assert.doesNotMatch(third.answer, /new session/);
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
  assert.match(res.answer, /^> \[!note\] Started a new session: the runner changed from claude-code to other/);
  assert.equal(res.conversationID, first.conversationID);
});

test('unknown or invalid conversation ids are rejected', async () => {
  const fx = fixture();
  const svc = service(fx, new FakeRunner('claude-code'));
  await assert.rejects(svc.ask({ question: 'q', conversationID: 'nope' }), /unknown conversation/);
  await assert.rejects(svc.ask({ question: 'q', conversationID: '../escape' }), /invalid conversation id/);
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
  assert.match(second.answer, /filter changed/);
  assert.deepEqual(c!.session, { resume: (b!.session as { start: string }).start });
  assert.doesNotMatch(third.answer, /new session/);
  assert.ok('start' in d!.session);
  assert.match(fourth.answer, /filter changed/);
  // The same expanded source set is the same scope.
  assert.deepEqual(e!.session, { resume: (d!.session as { start: string }).start });
  assert.doesNotMatch(fifth.answer, /new session/);
  assert.equal(a!.workingDirectory, e!.workingDirectory);
});
