/**
 * Port of clients/macos/Tests/WorkerCoreTests/WorkerCoreTests.swift (19 tests).
 * Suite and test names mirror the Swift XCTestCase classes and methods 1:1.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { runnerSupports, type AITask, type AgentRunner, type RunnerCapability, type Settings } from './contracts.js';
import { ClaudeCodeRunner, claudeArguments, parseClaudeJSON, type ClaudeInvocation } from './runners/claude-code.js';
import { bypassesApproval, suggestedRule } from './runners/permissions.js';
import { defaultRegistry } from './runners/registry.js';
import { IngestJobKind, JobContext, parseWorkerStatus, shellQuote, WorkerProtocol } from './engine/job-kinds.js';
import { BatchInterval, claimFiles, pendingFiles, settledFiles } from './engine/queue.js';
import { queuePlacementProblem, setupProblems } from './engine/validator.js';
import { decodeJob, jobRunnerID, newJob } from './store/jobs.js';
import { decodeSettings, defaultSettings, encodeSettings, selectionFor } from './store/settings.js';

const AI_TASKS: AITask[] = ['ingest', 'ask', 'labelSuggest', 'imageText'];

function settingsWith(patch: Partial<Settings>): Settings {
  return { ...defaultSettings(), ...patch };
}

function job(id: string, vaultPath: string, files: string[] = [], model = 'sonnet') {
  return newJob({ id, kind: 'ingest', vaultPath, files, model, now: new Date() });
}

describe('ClaudeResultTests', () => {
  test('testParsesStructuredOutputAndDenials', () => {
    const json = `{"session_id":"abc","result":"{}","is_error":false,"total_cost_usd":0.02,
     "structured_output":{"status":"needs_approval","summary":"ok","bundle_path":"/v/.vault-meta/worker/j/bundle.json"},
     "permission_denials":[{"tool_name":"Bash","tool_use_id":"t","tool_input":{"command":"ls /"}}]}`;
    const result = parseClaudeJSON(json);
    assert.equal(result.sessionID, 'abc');
    assert.ok(Math.abs(result.costUSD - 0.02) < 1e-9);
    assert.equal(suggestedRule(result.denials[0]!), 'Bash(ls /)');
    const status = parseWorkerStatus(result.structured);
    assert.ok(status);
    assert.equal(status.status, 'needs_approval');
    assert.equal(status.bundle_path, '/v/.vault-meta/worker/j/bundle.json');
  });

  test('testMissingStructuredOutputIsNil', () => {
    const result = parseClaudeJSON('{"session_id":"s","result":"hi","is_error":false}');
    assert.equal(parseWorkerStatus(result.structured), undefined);
    assert.equal(result.resultText, 'hi');
  });

  test('testCompoundBashDenialHasNoRule', () => {
    const d = { toolName: 'Bash', input: { command: 'cd /x && python3 build.py' } };
    assert.equal(suggestedRule(d), undefined);
    assert.equal(bypassesApproval(d), true);
  });

  test('testAbsolutePathDenialUsesDoubleSlashRule', () => {
    assert.equal(suggestedRule({ toolName: 'Read', input: { file_path: '/Users/x/a.md' } }), 'Read(//Users/x/a.md)');
    assert.equal(suggestedRule({ toolName: 'Write', input: { file_path: '/Users/x/b.md' } }), 'Edit(//Users/x/b.md)');
  });
});

describe('InvocationTests', () => {
  test('testStartThenResumeArguments', () => {
    const inv: ClaudeInvocation = {
      claudePath: '/c',
      workingDirectory: '/v',
      prompt: 'p',
      session: { start: 'id' },
      model: 'haiku',
      allowedTools: ['Read', 'Bash(x:*)'],
      addDirectories: [],
      pluginDirectory: '/prod',
      environment: {},
    };
    const args = claudeArguments(inv);
    assert.deepEqual(args.slice(0, 7), ['-p', '--output-format', 'json', '--model', 'haiku', '--session-id', 'id']);
    const i = args.indexOf('--allowedTools');
    assert.deepEqual(args.slice(i + 1), ['Read', 'Bash(x:*)']);
    assert.ok(!args.includes('p'), 'prompt goes over stdin');
    const resumed = claudeArguments({ ...inv, session: { resume: 'id' } });
    assert.ok(resumed.includes('--resume'));
    assert.ok(!resumed.includes('--session-id'));
  });

  test('testPlanningToolsNeverAllowApply', () => {
    const settings = settingsWith({ productRoot: '/prod' });
    const vault = { path: '/v', queueDirectory: '/q' };
    const ctx = new JobContext(job('job-1', '/v', ['inbox/a.md']), vault, settings);
    const tools = IngestJobKind.allowedTools(ctx);
    assert.ok(!tools.some((t) => t.includes('transaction apply')));
    assert.ok(tools.includes('Bash(python3 /prod/scripts/claude-obsidian.py transaction inspect:*)'));
    assert.ok(tools.includes('Edit(//v/.vault-meta/worker/job-1/**)'));
  });

  test('testPathsWithSpacesAreQuoted', () => {
    const settings = settingsWith({ productRoot: '/prod' });
    const vault = { path: '/Users/me/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Vault', queueDirectory: '/q' };
    const ctx = new JobContext(job('j', vault.path, [], 'm'), vault, settings);
    const plan = { operation_id: 'op', operation_type: 'ingest', valid: true, changed_paths: [], approval_sha256: 'abc' };
    assert.equal(
      WorkerProtocol.applyCommand(ctx, plan, ctx.bundlePath),
      `python3 /prod/scripts/claude-obsidian.py transaction apply '${ctx.bundlePath}' --vault '${vault.path}' --approved-plan-sha256 abc`,
    );
    assert.equal(shellQuote("it's"), "'it'\\''s'");
  });

  test('testApplyRuleIsExactCommand', () => {
    const settings = settingsWith({ productRoot: '/prod' });
    const ctx = new JobContext(job('j', '/v', [], 'm'), { path: '/v', queueDirectory: '/q' }, settings);
    const plan = { operation_id: 'op', operation_type: 'ingest', valid: true, changed_paths: [], approval_sha256: 'abc' };
    assert.equal(
      WorkerProtocol.applyCommand(ctx, plan, '/v/b.json'),
      'python3 /prod/scripts/claude-obsidian.py transaction apply /v/b.json --vault /v --approved-plan-sha256 abc',
    );
  });
});

describe('QueueTests', () => {
  let tmp: string;
  beforeEach(() => {
    tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-queue-')));
  });
  afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

  test('testScannerSkipsHiddenPartialAndUnsettled', () => {
    const q = path.join(tmp, 'q');
    fs.mkdirSync(q, { recursive: true });
    for (const name of ['a.md', '.hidden', 'b.pdf.crdownload']) fs.writeFileSync(path.join(q, name), 'x');
    const old = new Date(Date.now() - 60_000);
    fs.utimesSync(path.join(q, 'a.md'), old, old);
    fs.writeFileSync(path.join(q, 'fresh.md'), 'y');
    const pending = pendingFiles(q);
    assert.deepEqual(new Set(pending.map((e) => e.name)), new Set(['a.md', 'fresh.md']));
    assert.deepEqual(settledFiles(pending, 10, new Date()).map((e) => e.name), ['a.md']);
  });

  test('testClaimMovesIntoInboxWithoutClobbering', () => {
    const vaultPath = path.join(tmp, 'vault');
    const inbox = path.join(vaultPath, 'inbox');
    const q = path.join(tmp, 'q');
    for (const d of [inbox, q]) fs.mkdirSync(d, { recursive: true });
    fs.writeFileSync(path.join(inbox, 'note.md'), 'existing');
    fs.writeFileSync(path.join(q, 'note.md'), 'new');
    const vault = { path: vaultPath, queueDirectory: q };
    const claimed = claimFiles(pendingFiles(q), vault, new Set());
    assert.deepEqual(claimed, ['inbox/note 2.md']);
    assert.equal(fs.readFileSync(path.join(inbox, 'note.md'), 'utf8'), 'existing');
    assert.equal(pendingFiles(q).length, 0);
  });

  test('testQueueIsInboxSkipsClaimedFiles', () => {
    const vaultPath = path.join(tmp, 'vault');
    const inbox = path.join(vaultPath, 'inbox');
    fs.mkdirSync(inbox, { recursive: true });
    for (const n of ['a.md', 'b.md']) fs.writeFileSync(path.join(inbox, n), 'x');
    const vault = { path: vaultPath, queueDirectory: inbox };
    const claimed = claimFiles(pendingFiles(inbox), vault, new Set(['inbox/a.md']));
    assert.deepEqual(claimed, ['inbox/b.md']);
    assert.ok(fs.existsSync(path.join(inbox, 'a.md')));
  });

  test('testValidatorRejectsQueueInsideRaw', () => {
    const s = settingsWith({ vaults: [{ path: tmp, queueDirectory: path.join(tmp, '.raw/x') }] });
    const problems = setupProblems(s, defaultRegistry());
    const p = problems.find((x) => x.code === 'queueIsVaultInternal');
    assert.ok(p);
    assert.ok(p.message.includes(path.resolve(tmp, '.raw/x')));
  });

  test('queue placement: inside the vault only exactly <vault>/inbox (decision 2026-10-04)', () => {
    const vault = path.join(tmp, 'MyKnowledgeVault');
    fs.mkdirSync(path.join(vault, 'wiki'), { recursive: true });
    fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
    const placed = (q: string) => queuePlacementProblem(vault, q)?.code;
    // Refused: the root, wiki/, .raw/, .vault-meta/, a folder under inbox/, a not-yet-made folder inside.
    for (const q of [vault, path.join(vault, 'wiki'), path.join(vault, '.raw'), path.join(vault, '.vault-meta/q'), path.join(vault, 'inbox/sub'), path.join(vault, 'new/queue'), vault + '/']) {
      assert.equal(placed(q), 'queueIsVaultInternal', q);
    }
    // Allowed: the inbox itself, the owner's sibling queue, a folder whose name only starts like the vault's.
    for (const q of [path.join(vault, 'inbox'), path.join(vault, 'inbox/'), path.join(tmp, 'Distill Queue', 'MyKnowledgeVault'), vault + '2', path.join(tmp, 'elsewhere')]) {
      assert.equal(placed(q), undefined, q);
    }
    // Through a symlink into the vault: still inside.
    fs.symlinkSync(path.join(vault, 'wiki'), path.join(tmp, 'link'));
    assert.equal(placed(path.join(tmp, 'link')), 'queueIsVaultInternal');
    const s = settingsWith({ vaults: [{ path: vault, queueDirectory: path.join(vault, 'wiki') }], activeVaultPath: vault });
    assert.ok(setupProblems(s, defaultRegistry()).some((x) => x.code === 'queueIsVaultInternal'));
  });
});

describe('BatchIntervalTests', () => {
  test('testSplitsAndRecombines', () => {
    const i = new BatchInterval(1440 + 120 + 30);
    assert.deepEqual([i.days, i.hours, i.minutes], [1, 2, 30]);
    assert.equal(i.totalMinutes, 1590);
    assert.equal(i.toString(), '1d 2h 30m');
    assert.equal(new BatchInterval(180).toString(), '3h');
  });

  test('testClampsPartsAndNeverZero', () => {
    const i = new BatchInterval(1);
    i.set('minutes', 0);
    assert.equal(i.totalMinutes, 1);
    i.set('hours', 99);
    assert.equal(i.hours, 23);
    i.set('minutes', -5);
    assert.equal(i.minutes, 0);
    assert.equal(i.totalMinutes, 23 * 60);
  });
});

describe('RunnerTests', () => {
  test('testClaudeCodeSupportsEveryTask', () => {
    const claude = new ClaudeCodeRunner();
    for (const task of AI_TASKS) assert.ok(runnerSupports(claude, task), task);
  });

  test('testRunnerWithoutPermissionsCannotIngest', () => {
    const chatOnly: AgentRunner = {
      id: 'chat-only',
      displayName: 'Chat only',
      capabilities: new Set<RunnerCapability>(['structuredOutput', 'vision']),
      models: [],
      effortLevels: [],
      defaultModel: 'm',
      problems: () => [],
      run: async () => ({ resultText: '', isError: false, costUSD: 0, denials: [], raw: '' }),
    };
    assert.equal(runnerSupports(chatOnly, 'ingest'), false, 'approval gate needs tools + permissions + resume');
    assert.equal(runnerSupports(chatOnly, 'ask'), false);
    assert.equal(runnerSupports(chatOnly, 'labelSuggest'), true);
    assert.equal(runnerSupports(chatOnly, 'imageText'), true);
  });

  test('testSelectionFallbacksAndOverrides', () => {
    const s = settingsWith({ model: 'opus' });
    const ingest = selectionFor(s, 'ingest');
    assert.equal(ingest.runnerID, 'claude-code');
    assert.equal(ingest.model, 'opus');
    assert.equal(ingest.effort ?? null, null);
    assert.equal(selectionFor(s, 'labelSuggest').model, 'haiku');
    assert.deepEqual(selectionFor(s, 'imageText'), { runnerID: 'claude-code', model: 'haiku', effort: 'low' });
    s.taskDefaults.ask = { runnerID: 'claude-code', model: 'sonnet', effort: 'high' };
    assert.equal(selectionFor(s, 'ask').effort, 'high');
    const back = decodeSettings(JSON.parse(JSON.stringify(encodeSettings(s))));
    assert.deepEqual(selectionFor(back, 'ask'), selectionFor(s, 'ask'));
  });

  test('testOldSettingsAndJobsStillDecode', () => {
    const settings = decodeSettings({ model: 'haiku' });
    assert.deepEqual(settings.enabledRunners, ['claude-code']);
    assert.equal(selectionFor(settings, 'ingest').model, 'haiku');
    const old = decodeJob({
      id: 'j', kind: 'ingest', vaultPath: '/v', files: [], sessionID: 's', model: 'sonnet', state: 'completed',
      createdAt: '2026-10-01T15:42:00Z', updatedAt: '2026-10-01T15:42:00Z', turns: [], grantedTools: [], changedPaths: [],
    });
    assert.ok(old);
    assert.equal(old.runnerID, undefined);
    assert.equal(jobRunnerID(old), 'claude-code');
  });

  test('testRequestMapsToClaudeFlagsIncludingEffort', () => {
    const settings = settingsWith({ claudePath: '/c' });
    const runner = new ClaudeCodeRunner();
    const inv = runner.invocation(
      {
        workingDirectory: '/v',
        prompt: 'p',
        session: { resume: 's1' },
        selection: { runnerID: 'claude-code', model: 'opus', effort: 'high' },
        allowedTools: ['Read'],
        readableDirectories: [],
      },
      settings,
    );
    assert.deepEqual(claudeArguments(inv).slice(0, 9), ['-p', '--output-format', 'json', '--model', 'opus', '--effort', 'high', '--resume', 's1']);
  });
});
