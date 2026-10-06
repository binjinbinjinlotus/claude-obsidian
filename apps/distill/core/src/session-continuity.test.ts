/**
 * Session continuity (docs/specs/session-continuity.md): every place that resumes an AI session.
 * For each place: the resume fails (before or at the runner), the typed session_unavailable
 * appears, Continue (newSession) starts a new seeded session, Cancel leaves everything as it was.
 * Ordinary runner errors never turn into session_unavailable.
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import {
  CoreError,
  type AgentRunner,
  type CoreEvent,
  type Job,
  type RunRequest,
  type RunResult,
  type RunnerCapability,
  type SessionStoreStatus,
  type Settings,
} from './contracts.js';
import { createAskService } from './ask/index.js';
import { createEngine, type Engine } from './engine/index.js';
import { CANCELLED_BEFORE_FIRST_TURN, newSessionPrompt } from './engine/session-seed.js';
import { ClaudeCodeRunner } from './runners/claude-code.js';
import { CodexRunner } from './runners/codex.js';
import { RunnerError, type ProcessOutput, type RunProcessOptions } from './runners/process.js';
import { createRunnerRegistry } from './runners/registry.js';
import {
  checkResume,
  claudeTranscriptStatus,
  codexRolloutStatus,
  isSessionUnavailableError,
  resumeFailure,
  sessionNotFoundIn,
} from './runners/session.js';
import { startServer } from './server/http.js';
import { statePaths } from './store/paths.js';
import { decodeJob, encodeJob } from './store/jobs.js';

const SID = '3f2a91c0-1111-4222-8333-44445555c217';
const CLAUDE_NOT_FOUND = `No conversation found with session ID: ${SID}`;
const CODEX_NOT_FOUND = `Error: thread/resume: thread/resume failed: no rollout found for thread id ${SID} (code -32600)`;

let tmp: string;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-session-')));
});
afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

const out = (status: number, stdout: string, stderr: string): ProcessOutput => ({ status, stdout: Buffer.from(stdout), stderr: Buffer.from(stderr) });

function request(session: RunRequest['session']): RunRequest {
  return { workingDirectory: tmp, prompt: 'p', session, selection: { runnerID: 'x', model: 'm' }, allowedTools: [], readableDirectories: [] };
}

const settingsFor = (claudePath = '/bin/echo'): Settings =>
  ({ claudePath, productRoot: tmp, runnerOptions: { codex: { path: '/bin/echo' } } }) as unknown as Settings;

// ───────────── detection ─────────────

describe('detection: positive evidence only', () => {
  test('the not-found phrase must name exactly this session', () => {
    assert.equal(sessionNotFoundIn(CLAUDE_NOT_FOUND, SID), true);
    assert.equal(sessionNotFoundIn(CODEX_NOT_FOUND, SID), true);
    assert.equal(sessionNotFoundIn(CLAUDE_NOT_FOUND, 'another-id'), false, 'another session id');
    assert.equal(sessionNotFoundIn('Error: 401 invalid x-api-key', SID), false);
    assert.equal(sessionNotFoundIn(`Rate limited; session ${SID} kept`, SID), false);
    assert.equal(sessionNotFoundIn('', SID), false);
  });

  test('Claude Code: a refused resume is sessionNotFound; other exits stay nonZeroExit', async () => {
    const runner = new ClaudeCodeRunner(async () => out(1, '', CLAUDE_NOT_FOUND + '\n'));
    await assert.rejects(runner.run(request({ resume: SID }), settingsFor()), (e: unknown) => e instanceof RunnerError && e.code === 'sessionNotFound');
    // The same text on a first turn is not about a resume.
    await assert.rejects(runner.run(request({ start: SID }), settingsFor()), (e: unknown) => e instanceof RunnerError && e.code === 'nonZeroExit');
    // Live log (stream-json): stdout also carries an error result event; still sessionNotFound.
    const streamLine = JSON.stringify({ type: 'result', subtype: 'error_during_execution', is_error: true, num_turns: 0, session_id: SID, errors: [CLAUDE_NOT_FOUND] });
    const streaming = new ClaudeCodeRunner(async () => out(1, streamLine + '\n', CLAUDE_NOT_FOUND + '\n'));
    await assert.rejects(
      streaming.run({ ...request({ resume: SID }), onStep: () => undefined }, settingsFor()),
      (e: unknown) => e instanceof RunnerError && e.code === 'sessionNotFound',
    );
    const auth = new ClaudeCodeRunner(async () => out(1, '', 'Invalid API key · Please run /login'));
    await assert.rejects(auth.run(request({ resume: SID }), settingsFor()), (e: unknown) => e instanceof RunnerError && e.code === 'nonZeroExit');
  });

  test('Codex: a refused resume is sessionNotFound; other exits stay nonZeroExit', async () => {
    const runner = new CodexRunner(async () => out(1, '', CODEX_NOT_FOUND));
    await assert.rejects(runner.run(request({ resume: SID }), settingsFor()), (e: unknown) => e instanceof RunnerError && e.code === 'sessionNotFound');
    const other = new CodexRunner(async () => out(1, '', 'Error: stream disconnected before completion'));
    await assert.rejects(other.run(request({ resume: SID }), settingsFor()), (e: unknown) => e instanceof RunnerError && e.code === 'nonZeroExit');
  });

  test('Claude transcripts: present, missing, or unknown when the store is unreadable', () => {
    const config = path.join(tmp, 'claude');
    assert.equal(claudeTranscriptStatus(SID, config), 'unknown', 'no projects dir');
    fs.mkdirSync(path.join(config, 'projects', '-Users-me-vault'), { recursive: true });
    assert.equal(claudeTranscriptStatus(SID, config), 'missing');
    fs.writeFileSync(path.join(config, 'projects', '-Users-me-vault', `${SID}.jsonl`), '{}\n');
    assert.equal(claudeTranscriptStatus(SID, config), 'present');
    assert.equal(claudeTranscriptStatus('../escape', config), 'unknown', 'odd ids are never judged');
    assert.equal(new ClaudeCodeRunner(undefined, config).sessionStatus(SID), 'present');
  });

  test('Codex rollouts: present (also archived), missing, unknown', () => {
    const home = path.join(tmp, 'codex');
    assert.equal(codexRolloutStatus(SID, home), 'unknown');
    fs.mkdirSync(path.join(home, 'sessions', '2026', '10', '05'), { recursive: true });
    assert.equal(codexRolloutStatus(SID, home), 'missing');
    fs.mkdirSync(path.join(home, 'archived_sessions'), { recursive: true });
    fs.writeFileSync(path.join(home, 'archived_sessions', `rollout-2026-10-05T00-00-00-${SID}.jsonl`), '');
    assert.equal(codexRolloutStatus(SID, home), 'present', 'archived: let codex decide');
    fs.rmSync(path.join(home, 'archived_sessions'), { recursive: true });
    fs.writeFileSync(path.join(home, 'sessions', '2026', '10', '05', `rollout-2026-10-05T00-00-00-${SID}.jsonl`), '');
    assert.equal(new CodexRunner(undefined, home).sessionStatus(SID), 'present');
  });

  test('checkResume: runner gone, never started, missing; null when it cannot tell', () => {
    const caps = new Set<RunnerCapability>(['sessionResume']);
    const runner = (status: SessionStoreStatus | undefined, c = caps) =>
      ({ id: 'claude-code', displayName: 'Claude Code', capabilities: c, ...(status ? { sessionStatus: () => status } : {}) }) as unknown as AgentRunner;
    const base = { place: 'batch' as const, runnerID: 'claude-code', sessionID: SID };
    assert.equal(checkResume({ ...base, runner: undefined })?.reason, 'runnerGone');
    assert.equal(checkResume({ ...base, runner: runner(undefined, new Set()) })?.reason, 'runnerGone');
    assert.equal(checkResume({ ...base, runner: runner('present'), neverStarted: true })?.reason, 'neverStarted');
    const missing = checkResume({ ...base, runner: runner('missing') })!;
    assert.equal(missing.reason, 'missing');
    assert.match(missing.message, /This batch’s AI session isn’t available anymore \(its history is no longer on this Mac\)\. Distill will start a new session to continue\./);
    assert.equal(checkResume({ ...base, runner: runner('unknown') }), null);
    assert.equal(checkResume({ ...base, runner: runner(undefined) }), null, 'a runner without a session store is never judged');
    assert.equal(resumeFailure({ ...base, runner: runner('present') }, new RunnerError('rate limited', 'apiError')), null);
    assert.equal(resumeFailure({ ...base, runner: runner('present') }, new Error(CLAUDE_NOT_FOUND)), null, 'only the runner-level code counts');
    assert.equal(resumeFailure({ ...base, runner: runner('present') }, new RunnerError(CLAUDE_NOT_FOUND, 'sessionNotFound'))?.reason, 'notFound');
  });

  test('the job marker survives a save and a lenient load', () => {
    const job = decodeJob({ id: 'j', vaultPath: '/v', sessionUnavailable: { place: 'batch', reason: 'notFound', message: 'm', detail: 'd', action: 'reply', text: 'hi' } })!;
    assert.equal(job.sessionUnavailable?.text, 'hi');
    assert.deepEqual(decodeJob(encodeJob(job))!.sessionUnavailable, job.sessionUnavailable);
    assert.equal(decodeJob({ id: 'j', vaultPath: '/v', sessionUnavailable: { place: 'moon', reason: 'x' } })!.sessionUnavailable, undefined);
  });
});

// ───────────── batches (engine) ─────────────

type Step = Partial<RunResult> & { throws?: Error };

class FakeAgent implements AgentRunner {
  readonly id = 'claude-code';
  readonly displayName = 'Claude Code';
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly requests: RunRequest[] = [];
  readonly capabilities = new Set<RunnerCapability>(['agentTools', 'toolPermissions', 'sessionResume', 'structuredOutput']);
  status: SessionStoreStatus = 'unknown';
  constructor(readonly steps: Step[]) {}
  problems() {
    return [];
  }
  sessionStatus(): SessionStoreStatus {
    return this.status;
  }
  newSessionCommand(prompt: string, model: string): string[] {
    return ['claude', '--model', model, prompt];
  }
  resumeCommand(sessionID: string): string[] {
    return ['claude', '--resume', sessionID];
  }
  async run(req: RunRequest): Promise<RunResult> {
    this.requests.push(req);
    await new Promise((r) => setImmediate(r));
    const step = this.steps.shift() ?? { structured: { status: 'failed', summary: 'no more steps' } };
    if (step.throws) throw step.throws;
    const sid = 'start' in req.session ? req.session.start : req.session.resume;
    const { throws: _t, ...rest } = step;
    return { sessionID: sid, resultText: '', isError: false, costUSD: 0, denials: [], raw: '{}', ...rest };
  }
}

const PLAN = {
  schema: 'claude-obsidian.transaction-plan.v1',
  operation_id: 'op-1',
  operation_type: 'ingest',
  valid: true,
  changed_paths: ['wiki/a.md'],
  approval_sha256: 'f'.repeat(64),
};

interface H {
  engine: Engine;
  runner: FakeAgent;
  vault: string;
  queue: string;
  events: CoreEvent[];
}

function engineSetup(runner: FakeAgent, jobs?: unknown, extra: Record<string, unknown> = { recovery: { automatic: false } }): H {
  const vault = path.join(tmp, 'vault');
  const product = path.join(tmp, 'product');
  const state = path.join(tmp, 'state');
  const queue = path.join(tmp, 'queue');
  for (const d of [path.join(vault, 'inbox'), path.join(product, 'scripts'), state, queue]) fs.mkdirSync(d, { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '# fake\n');
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({
      vaults: [{ path: vault, queueDirectory: queue }],
      activeVaultPath: vault,
      productRoot: product,
      settleSeconds: 0,
      pythonPath: '/usr/bin/python3',
      autoProcessEnabled: false,
      labeling: { autoLabelQueueFolder: false },
      ...extra,
    }),
  );
  if (jobs) fs.writeFileSync(path.join(state, 'jobs.json'), JSON.stringify(jobs));
  const engine = createEngine({
    paths: statePaths(state),
    runners: createRunnerRegistry([runner]),
    launch: async () => out(0, JSON.stringify(PLAN), ''),
    tickMs: 60_000,
  });
  const events: CoreEvent[] = [];
  engine.subscribe((e) => events.push(e));
  return { engine, runner, vault, queue, events };
}

/** A batch waiting for review with a valid plan (one worker turn ran). */
async function reviewedBatch(h: H): Promise<Job> {
  fs.writeFileSync(path.join(h.queue, 'a.md'), '# A\n');
  const orig = h.runner.run.bind(h.runner);
  let first = true;
  h.runner.run = async (req) => {
    if (first) {
      first = false;
      const id = h.engine.listJobs()[0]!.id;
      h.runner.steps.unshift({ structured: { status: 'needs_approval', summary: 'Adds a page.', bundle_path: path.join(h.vault, '.vault-meta/worker', id, 'bundle.json') } });
    }
    return orig(req);
  };
  const job = await h.engine.processQueue({ force: true });
  await h.engine.whenIdle();
  const j = h.engine.getJob(job!.id)!;
  assert.equal(j.state, 'awaitingApproval');
  return j;
}

const strip = (j: Job | undefined) => {
  const { updatedAt: _u, ...rest } = structuredClone(j!);
  return rest;
};

describe('batches: approve, reply, allow, Open in Terminal', () => {
  let h: H;
  afterEach(async () => {
    await h?.engine.stop();
  });

  test('approve: transcript gone → session_unavailable, nothing changes (Cancel); Continue applies in a new seeded session', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    h.runner.status = 'missing';
    const before = strip(job);
    const calls = h.runner.requests.length;
    await assert.rejects(h.engine.approve(job.id), (e: unknown) => {
      assert.ok(isSessionUnavailableError(e));
      assert.equal((e as CoreError).details?.reason, 'missing');
      assert.equal((e as CoreError).details?.place, 'batch');
      assert.equal((e as CoreError).details?.action, 'approve');
      return true;
    });
    assert.deepEqual(strip(h.engine.getJob(job.id)), before, 'Cancel leaves the batch exactly as it was');
    assert.equal(h.runner.requests.length, calls, 'no runner call');

    h.runner.steps.push({ structured: { status: 'done', summary: 'Applied.', operation_id: 'op-1', changed_paths: ['wiki/a.md'] } });
    await h.engine.approve(job.id, { newSession: true });
    await h.engine.whenIdle();
    const done = h.engine.getJob(job.id)!;
    assert.equal(done.state, 'completed');
    assert.equal(done.operationID, 'op-1');
    assert.notEqual(done.sessionID, job.sessionID, 'a new session id is recorded');
    const req = h.runner.requests.at(-1)!;
    assert.deepEqual(req.session, { start: done.sessionID });
    assert.ok(req.prompt.includes('NEW session'));
    assert.ok(req.prompt.includes('inbox/a.md'), 'seeded with the sources');
    assert.ok(req.prompt.includes('APPROVED operation op-1'));
    assert.ok(req.allowedTools.some((t) => t.includes(`--approved-plan-sha256 ${PLAN.approval_sha256}`)), 'the same pinned apply');
    const replaced = h.events.find((e) => e.type === 'session.replaced');
    assert.deepEqual(replaced && { ...replaced }, { type: 'session.replaced', place: 'batch', objectID: job.id, reason: 'missing' });
  });

  test('reply: the runner refuses the resume → the batch is put back with a marker; Continue sends the reply to a new session', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    const before = strip(job);
    h.runner.steps.push({ throws: new RunnerError(CLAUDE_NOT_FOUND, 'sessionNotFound') });
    await h.engine.reply(job.id, 'Put it on the Gyokuro page');
    await h.engine.whenIdle();
    const back = h.engine.getJob(job.id)!;
    const { sessionUnavailable, ...rest } = strip(back);
    assert.deepEqual(rest, before, 'state, approval, turns and grants are as they were');
    assert.equal(sessionUnavailable?.reason, 'notFound');
    assert.equal(sessionUnavailable?.action, 'reply');
    assert.equal(sessionUnavailable?.text, 'Put it on the Gyokuro page', 'the reply is kept for Continue');
    assert.match(sessionUnavailable?.detail ?? '', /No conversation found/);
    assert.equal(back.error, undefined);

    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'Moved.' } });
    await h.engine.reply(job.id, 'Put it on the Gyokuro page', { newSession: true });
    await h.engine.whenIdle();
    const after = h.engine.getJob(job.id)!;
    assert.equal(after.sessionUnavailable, undefined, 'the next turn clears the marker');
    assert.notEqual(after.sessionID, job.sessionID);
    const req = h.runner.requests.at(-1)!;
    assert.deepEqual(req.session, { start: after.sessionID });
    assert.ok(req.prompt.includes('What happened so far'));
    assert.ok(req.prompt.includes('Adds a page.'), 'the conversation so far');
    assert.ok(req.prompt.includes('Put it on the Gyokuro page'));
    assert.ok(req.prompt.includes('bundle.json'), 'the plan under review');
  });

  test('Continue keeps the batch progress open while the new session works (reply)', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.reply(job.id, 'go on', { newSession: true });
    const last = h.events.filter((e): e is Extract<CoreEvent, { type: 'progress' }> => e.type === 'progress' && e.progress.key === job.id).at(-1);
    assert.ok(last && !last.progress.finished, 'progress is running, not closed as "Ready for review"');
    assert.match(last.progress.message, /new session/);
    await h.engine.whenIdle();
  });

  test('approve refused at the resume: the live log keeps no spinning step', async () => {
    const { createStepLog } = await import('./steps/index.js');
    h = engineSetup(new FakeAgent([]));
    const log = createStepLog({ dir: path.join(tmp, 'steps'), emit: () => undefined, getJob: (id) => h.engine.getJob(id) });
    h.engine.subscribe((e) => log.onEvent(e));
    const job = await reviewedBatch(h);
    h.runner.steps.push({ throws: new RunnerError(CLAUDE_NOT_FOUND, 'sessionNotFound') });
    await h.engine.approve(job.id);
    await h.engine.whenIdle();
    const back = h.engine.getJob(job.id)!;
    assert.equal(back.state, 'awaitingApproval');
    assert.equal(back.sessionUnavailable?.action, 'approve');
    const running = log.list(job.id).steps.filter((s) => s.state === 'running');
    assert.deepEqual(running, [], 'no "Applying…" or agent step left running');
    assert.ok(log.list(job.id).steps.some((s) => s.state === 'review'), 'waiting for the user again');
  });

  test('approve when the batch runner is gone and the default cannot limit tools: the core applies, no agent turn', async () => {
    const weak = new FakeAgent([]);
    h = engineSetup(weak);
    const job = await reviewedBatch(h);
    // The batch now names a runner this core no longer has; the default (the fake) loses toolPermissions.
    (weak.capabilities as Set<RunnerCapability>).delete('toolPermissions');
    (weak.capabilities as Set<RunnerCapability>).add('sandboxedWrites');
    const jobsFile = path.join(tmp, 'state', 'jobs.json');
    await h.engine.stop();
    const saved = JSON.parse(fs.readFileSync(jobsFile, 'utf8'));
    saved[0].runnerID = 'retired-runner';
    fs.writeFileSync(jobsFile, JSON.stringify(saved));
    const applies: string[][] = [];
    const engine = createEngine({
      paths: statePaths(path.join(tmp, 'state')),
      runners: createRunnerRegistry([weak]),
      launch: async (o: RunProcessOptions) => {
        applies.push(o.args);
        return out(0, JSON.stringify(o.args.includes('apply') ? { ok: true, operation_id: 'op-1', changed_paths: ['wiki/a.md'] } : PLAN), '');
      },
      tickMs: 60_000,
    });
    h = { ...h, engine };
    await assert.rejects(engine.approve(job.id), (e: unknown) => isSessionUnavailableError(e) && (e as CoreError).details?.reason === 'runnerGone');
    const calls = weak.requests.length;
    await engine.approve(job.id, { newSession: true });
    await engine.whenIdle();
    assert.equal(weak.requests.length, calls, 'no agent turn ran the apply');
    assert.ok(applies.some((a) => a.includes('apply') && a.includes('--approved-plan-sha256')), 'the core ran the pinned apply');
  });

  test('allow: transcript gone → nothing granted (Cancel); Continue grants and runs in a new session', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    h.runner.status = 'missing';
    await assert.rejects(h.engine.allow(job.id, ['WebFetch']), (e: unknown) => isSessionUnavailableError(e) && (e as CoreError).details?.action === 'allow');
    assert.deepEqual(h.engine.getJob(job.id)!.grantedTools, []);
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.allow(job.id, ['WebFetch'], { newSession: true });
    await h.engine.whenIdle();
    const after = h.engine.getJob(job.id)!;
    assert.deepEqual(after.grantedTools, ['WebFetch']);
    assert.ok(h.runner.requests.at(-1)!.allowedTools.includes('WebFetch'));
    assert.ok('start' in h.runner.requests.at(-1)!.session);
  });

  test('reply to a batch cancelled before its first turn: neverStarted; Continue starts it over with the reply', async () => {
    const vault = path.join(tmp, 'vault');
    const jobs = [{
      id: 'job-20261005-010000-ab12', kind: 'ingest', vaultPath: vault, files: ['inbox/a.md'], sessionID: SID,
      model: 'sonnet', state: 'cancelled', createdAt: '2026-10-05T01:00:00Z', updatedAt: '2026-10-05T01:00:00Z',
      turns: [{ id: 't1', date: '2026-10-05T01:00:00Z', author: 'app', text: CANCELLED_BEFORE_FIRST_TURN, costUSD: 0 }],
      grantedTools: [], changedPaths: [],
    }];
    h = engineSetup(new FakeAgent([{ structured: { status: 'nothing_to_do', summary: 'ok' } }]), jobs);
    fs.writeFileSync(path.join(vault, 'inbox', 'a.md'), '# A\n');
    await assert.rejects(h.engine.reply(jobs[0]!.id, 'go'), (e: unknown) => isSessionUnavailableError(e) && (e as CoreError).details?.reason === 'neverStarted');
    assert.equal(h.engine.getJob(jobs[0]!.id)!.state, 'cancelled');
    await h.engine.reply(jobs[0]!.id, 'go', { newSession: true });
    await h.engine.whenIdle();
    const req = h.runner.requests[0]!;
    assert.ok('start' in req.session);
    assert.ok(!req.prompt.includes('NEW session'), 'nothing to continue: the batch starts over');
    assert.ok(req.prompt.includes('inbox/a.md') && req.prompt.includes('go'));
  });

  test('an ordinary runner error on a resume fails the batch as before (no confirmation)', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    h.runner.steps.push({ throws: new RunnerError('Exited 1: 529 overloaded', 'nonZeroExit') });
    await h.engine.reply(job.id, 'again');
    await h.engine.whenIdle();
    const after = h.engine.getJob(job.id)!;
    assert.equal(after.state, 'failed');
    assert.equal(after.sessionUnavailable, undefined);
    assert.match(after.error ?? '', /overloaded/);
  });

  test('a stopped batch recovery gave up on can be rejected (review-queue.md)', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    h.runner.steps.push({ throws: new RunnerError('Exited 1: 529 overloaded', 'nonZeroExit') });
    await h.engine.reply(job.id, 'again');
    await h.engine.whenIdle();
    assert.equal(h.engine.getJob(job.id)!.recovery?.state, 'gaveUp');
    assert.equal((await h.engine.status()).pendingApprovals, 1, "Couldn't fix needs the owner");
    await h.engine.reject(job.id);
    assert.equal((await h.engine.status()).pendingApprovals, 0);
    const after = h.engine.getJob(job.id)!;
    assert.equal(after.state, 'rejected');
    assert.equal(after.recovery, undefined);
  });

  test('recovery with a gone session proposes a new one; only the owner continues it, and recovery starts over', async () => {
    h = engineSetup(new FakeAgent([]), undefined, {});
    const job = await reviewedBatch(h);
    h.runner.steps.push({ throws: new RunnerError('Exited 1: 529 overloaded', 'nonZeroExit') });
    await h.engine.reply(job.id, 'again');
    h.runner.status = 'missing'; // gone before the turn ends: recovery can't reply in it
    await h.engine.whenIdle();
    const stuck = h.engine.getJob(job.id)!;
    assert.equal(stuck.recovery?.state, 'gaveUp');
    assert.equal(stuck.recovery?.proposal, 'new_session');
    assert.equal(h.runner.requests.length, 2, 'no new session started by itself');
    h.runner.steps.push({ structured: { status: 'nothing_to_do', summary: 'ok' } });
    await h.engine.reply(job.id, 'Continue this batch in a new session.', { newSession: true });
    await h.engine.whenIdle();
    const after = h.engine.getJob(job.id)!;
    assert.ok('start' in h.runner.requests.at(-1)!.session, 'a new session');
    assert.notEqual(after.sessionID, job.sessionID);
    assert.equal(after.recovery, undefined);
  });

  test('runner-failed recovery: a resumed turn that errors gets one "continue" in the same session (review-queue.md)', async () => {
    h = engineSetup(new FakeAgent([]), undefined, {});
    const job = await reviewedBatch(h);
    h.runner.steps.push({ throws: new RunnerError('Exited 1: 529 overloaded', 'nonZeroExit') });
    await h.engine.reply(job.id, 'again');
    await h.engine.whenIdle();
    const after = h.engine.getJob(job.id)!;
    assert.equal(after.recovery?.signature, 'runner-failed');
    assert.equal(after.recovery?.attempts[0]?.by, 'rule');
    assert.ok(after.turns.some((t) => t.author === 'app' && /stopped with an error: .*overloaded/.test(t.text)), 'Distill asked the session to continue');
    assert.equal(after.sessionID, job.sessionID, 'the same session');
  });

  test('Open in Terminal: a gone session throws (no resume argv); newSession opens a primed new session, the batch unchanged', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    assert.deepEqual(await h.engine.jobResumeCommand(job.id), ['claude', '--resume', job.sessionID]);
    h.runner.status = 'missing';
    await assert.rejects(h.engine.jobResumeCommand(job.id), (e: unknown) => isSessionUnavailableError(e) && (e as CoreError).details?.place === 'terminal');
    const argv = (await h.engine.jobResumeCommand(job.id, { newSession: true }))!;
    assert.equal(argv[0], 'claude');
    assert.ok(!argv.includes('--resume'));
    assert.match(argv.at(-1)!, /new session/);
    assert.match(argv.at(-1)!, /Do not run `transaction apply`/);
    assert.deepEqual(strip(h.engine.getJob(job.id)), strip(job));
    assert.ok(h.events.some((e) => e.type === 'session.replaced' && e.place === 'terminal'));
  });

  test('resumeBatchSession (the seam review-labels plugs into) restores the snapshot when the session is gone', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    h.runner.status = 'missing';
    const outcome = h.engine.resumeBatchSession({ job, prompt: 'x', action: 'approve', snapshot: job });
    assert.equal(outcome.kind, 'session_unavailable');
    assert.equal(h.runner.requests.length, 1, 'no resume ran');
  });

  test('the seed for a new session carries sources, labels, conversation, plan and the pending action', async () => {
    h = engineSetup(new FakeAgent([]));
    const job = await reviewedBatch(h);
    const { IngestJobKind, JobContext } = await import('./engine/job-kinds.js');
    const ctx = new JobContext(job, { path: h.vault, queueDirectory: h.queue }, h.engine.getSettings(), [{ file: 'inbox/a.md', labels: ['tea'], by: 'user' }]);
    const p = newSessionPrompt(IngestJobKind, ctx, 'PENDING');
    assert.ok(p.includes('inbox/a.md') && p.includes('tea') && p.includes('Adds a page.') && p.includes('op-1') && p.endsWith('PENDING'));
  });
});

// ───────────── Ask ─────────────

describe('Ask follow-ups', () => {
  function askSetup(runner: FakeAgent) {
    const vault = path.join(tmp, 'vault');
    const product = path.join(tmp, 'product');
    fs.mkdirSync(path.join(product, 'skills', 'wiki-query'), { recursive: true });
    fs.writeFileSync(path.join(product, 'skills', 'wiki-query', 'SKILL.md'), '#\n');
    fs.mkdirSync(path.join(vault, 'wiki'), { recursive: true });
    fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
    const settings = {
      vaults: [{ path: vault, queueDirectory: path.join(tmp, 'q') }],
      activeVaultPath: vault,
      model: 'sonnet',
      productRoot: product,
      enabledRunners: ['claude-code'],
      taskDefaults: {},
      extraAllowedTools: [],
    } as unknown as Settings;
    const events: CoreEvent[] = [];
    const stateDir = path.join(tmp, 'state', 'ask');
    const svc = createAskService({ getSettings: () => settings, runners: createRunnerRegistry([runner]), stateDir, emit: (e) => events.push(e) });
    return { svc, events, stateDir };
  }
  const answer = (text: string): Step => ({ structured: { answer: text, citations: [], gaps: [] } });

  test('transcript gone → session_unavailable, the chat is unchanged (Cancel); Continue replays the conversation', async () => {
    const runner = new FakeAgent([answer('70–80 °C.')]);
    const { svc, events, stateDir } = askSetup(runner);
    const first = await svc.ask({ question: 'How hot for green tea?' });
    const file = path.join(stateDir, `${first.conversationID}.json`);
    const saved = fs.readFileSync(file, 'utf8');
    runner.status = 'missing';
    await assert.rejects(svc.ask({ question: 'And gyokuro?', conversationID: first.conversationID }), (e: unknown) => {
      assert.ok(isSessionUnavailableError(e));
      assert.equal((e as CoreError).details?.place, 'conversation');
      assert.match((e as CoreError).message, /This conversation’s AI session isn’t available anymore/);
      return true;
    });
    assert.equal(fs.readFileSync(file, 'utf8'), saved, 'nothing saved');
    assert.equal(runner.requests.length, 1);

    runner.steps.push(answer('No temperature for gyokuro.'));
    const res = await svc.ask({ question: 'And gyokuro?', conversationID: first.conversationID, newSession: true });
    const req = runner.requests.at(-1)!;
    assert.ok('start' in req.session, 'a new session');
    assert.ok(req.prompt.includes('Q1: How hot for green tea?') && req.prompt.includes('A1: 70–80 °C.'), 'the conversation so far');
    assert.ok(res.notices?.some((n) => /Started a new session/.test(n)));
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.equal(record.sessionID, (req.session as { start: string }).start, 'the new session id is recorded');
    assert.equal(record.history.length, 2);
    assert.ok(events.some((e) => e.type === 'session.replaced' && e.place === 'conversation' && e.reason === 'missing'));
  });

  test('the runner refuses the resume → session_unavailable; an ordinary error stays an error', async () => {
    const runner = new FakeAgent([answer('a')]);
    const { svc } = askSetup(runner);
    const first = await svc.ask({ question: 'q' });
    runner.steps.push({ throws: new RunnerError(CLAUDE_NOT_FOUND, 'sessionNotFound') });
    await assert.rejects(svc.ask({ question: 'q2', conversationID: first.conversationID }), isSessionUnavailableError);
    runner.steps.push({ throws: new RunnerError('Exited 1: 401 invalid api key', 'nonZeroExit') });
    await assert.rejects(svc.ask({ question: 'q3', conversationID: first.conversationID }), (e: unknown) => !isSessionUnavailableError(e) && /401/.test((e as Error).message));
  });

  test('a deliberate reset (runner/scope change) keeps its notice and never replays history', async () => {
    const runner = new FakeAgent([answer('a'), answer('b')]);
    const { svc } = askSetup(runner);
    const first = await svc.ask({ question: 'secret q' });
    runner.status = 'missing'; // irrelevant: the scope change already starts fresh
    fs.mkdirSync(path.join(tmp, 'vault', 'wiki', 'sources'), { recursive: true });
    fs.writeFileSync(path.join(tmp, 'vault', 'wiki', 'sources', 'A.md'), '---\ntitle: A\ntags:\n  - tea\n---\nx\n');
    const res = await svc.ask({ question: 'q2', conversationID: first.conversationID, labels: ['tea'], newSession: true });
    assert.ok(res.notices?.some((n) => /filter changed/.test(n)));
    assert.ok(!runner.requests.at(-1)!.prompt.includes('secret q'), 'no replay across a filter scope');
  });
});

// ───────────── API ─────────────

describe('API', () => {
  test('session_unavailable is a 409 with place, reason, message and detail; newSession reaches the core', async () => {
    const seen: unknown[] = [];
    const err = new CoreError('session_unavailable', 'This batch’s AI session isn’t available anymore (x). Distill will start a new session to continue.', {
      place: 'batch', reason: 'notFound', message: 'm', detail: CLAUDE_NOT_FOUND, action: 'reply',
    });
    const job = { id: 'j1' } as Job;
    const core = new Proxy({} as Record<string, unknown>, {
      get: (_t, k) => {
        if (k === 'getJob') return () => job;
        if (k === 'reply') return async (_id: string, _text: string, opts: unknown) => {
          seen.push(opts);
          if (!(opts as { newSession?: boolean }).newSession) throw err;
        };
        if (k === 'subscribe') return () => () => undefined;
        return undefined;
      },
    });
    const server = await startServer({ core: core as never, token: 'session-continuity-token' });
    try {
      const call = (body: unknown) =>
        fetch(`http://127.0.0.1:${server.port}/v1/jobs/j1/reply`, {
          method: 'POST',
          headers: { Authorization: 'Bearer session-continuity-token', 'Content-Type': 'application/json' },
          body: JSON.stringify(body),
        });
      const r = await call({ text: 'hi' });
      assert.equal(r.status, 409);
      const body = (await r.json()) as { error: Record<string, unknown> };
      assert.equal(body.error.code, 'session_unavailable');
      assert.equal(body.error.reason, 'notFound');
      assert.equal(body.error.place, 'batch');
      assert.equal(body.error.detail, CLAUDE_NOT_FOUND);
      assert.match(String(body.error.message), /isn’t available anymore/);
      const ok = await call({ text: 'hi', newSession: true });
      assert.equal(ok.status, 200);
      assert.deepEqual(seen, [{}, { newSession: true }]);
    } finally {
      await server.close();
    }
  });
});
