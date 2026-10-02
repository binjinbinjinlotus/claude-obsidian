import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, test } from 'node:test';
import type { AgentRunner, CoreEvent, RunRequest, RunResult, RunnerCapability } from '../contracts.js';
import { createCore } from '../index.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { MemorySecretStore } from '../runners/secrets.js';
import { statePaths } from '../store/paths.js';
import { FIND_SCHEMA } from './ai.js';

const PRODUCT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
const PYTHON = execFileSync('python3', ['-c', 'import sys; print(sys.executable)']).toString().trim();
const CORE = path.join(PRODUCT_ROOT, 'scripts', 'claude-obsidian.py');

let tmp: string;
before(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-actions-e2e-')));
});
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

/** Writes an ingest bundle on the first turn (the core applies it) and answers actionFind. */
class BatchRunner implements AgentRunner {
  readonly id = 'sandboxed';
  readonly displayName = 'Sandboxed';
  readonly models = [{ id: 'x', label: 'Sonnet' }];
  readonly effortLevels = [];
  readonly defaultModel = 'x';
  readonly capabilities = new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']);
  readonly requests: RunRequest[] = [];
  jobID = () => '';
  problems() {
    return [];
  }
  async run(req: RunRequest): Promise<RunResult> {
    this.requests.push(req);
    await new Promise((r) => setImmediate(r));
    const base = { resultText: '', isError: false, costUSD: 0, denials: [], raw: '{}' };
    if (req.outputSchema === FIND_SCHEMA) {
      return {
        ...base,
        structured: {
          items: [{ type: 'todo', title: 'Book the tasting room', fields: [], why: 'You said so', quote: 'I will book the tasting room.', notePath: 'wiki/tea.md' }],
        },
      };
    }
    const vault = req.workingDirectory;
    const dir = path.join(vault, '.vault-meta/worker', this.jobID());
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, 'bundle.json'),
      JSON.stringify({
        schema: 'claude-obsidian.transaction.v1',
        operation_id: `${this.jobID()}-ingest`,
        operation_type: 'markdown',
        expected_hashes: { 'wiki/tea.md': null },
        writes: [{ path: 'wiki/tea.md', mode: 'create', content: '---\ntitle: Tea\n---\n\nI will book the tasting room.\n' }],
      }),
    );
    return { ...base, structured: { status: 'needs_approval', summary: 'Adds a page.', bundle_path: path.join(dir, 'bundle.json') } };
  }
}

test('approve → applied → "Finding actions" adds pending items and the job summary', async () => {
  const vault = path.join(tmp, 'vault');
  const dry = JSON.parse(execFileSync(PYTHON, [CORE, 'init', vault, '--operation-id', 't', '--generated-at', '2026-10-01T00:00:00Z']).toString());
  execFileSync(PYTHON, [CORE, 'init', vault, '--operation-id', 't', '--generated-at', '2026-10-01T00:00:00Z', '--apply', '--approved-plan-sha256', dry.approved_plan_sha256]);
  const state = path.join(tmp, 'state');
  const queue = path.join(tmp, 'queue');
  fs.mkdirSync(queue, { recursive: true });
  fs.mkdirSync(state, { recursive: true });
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({
      vaults: [{ path: vault, queueDirectory: queue }],
      productRoot: PRODUCT_ROOT,
      pythonPath: PYTHON,
      settleSeconds: 0,
      autoProcessEnabled: false,
      enabledRunners: ['sandboxed'],
      labeling: { autoLabelQueueFolder: false },
      taskDefaults: Object.fromEntries(
        ['ingest', 'ask', 'labelSuggest', 'imageText', 'actionFind', 'actionDraft', 'actionImprove'].map((t) => [t, { runnerID: 'sandboxed', model: 'x' }]),
      ),
    }),
  );
  const runner = new BatchRunner();
  const core = createCore({ paths: statePaths(state), runners: createRunnerRegistry([runner]), tickMs: 60_000, secrets: new MemorySecretStore() });
  const events: CoreEvent[] = [];
  core.subscribe((e) => events.push(e));
  const engine = core as unknown as { whenIdle(): Promise<void> };
  fs.writeFileSync(path.join(queue, 'tea.md'), 'I will book the tasting room.\n');
  const job = (await core.processQueue({ force: true }))!;
  runner.jobID = () => job.id;
  await engine.whenIdle();
  assert.equal(core.getJob(job.id)!.state, 'awaitingApproval', core.getJob(job.id)!.approval?.planError ?? '');
  await core.approve(job.id);
  await engine.whenIdle();
  const done = core.getJob(job.id)!;
  assert.equal(done.state, 'completed', done.error ?? '');
  assert.deepEqual(done.actionsFound, { status: 'done', found: 1, pending: 1, added: 0, byType: { todo: 1 }, model: 'Sonnet' });
  const items = await core.listActions();
  assert.equal(items.length, 1);
  assert.equal(items[0]!.status, 'pending');
  assert.deepEqual(items[0]!.source, { kind: 'note', jobID: job.id, notePath: 'wiki/tea.md', pageTitle: 'Tea', quote: 'I will book the tasting room.' });
  const steps = events.filter((e): e is Extract<CoreEvent, { type: 'progress' }> => e.type === 'progress' && e.progress.key === job.id);
  assert.ok(steps.some((e) => e.progress.message.startsWith('Finding actions in')));
  assert.equal(steps.at(-1)!.progress.message, 'Found 1 action to confirm: 1 to-do');
  assert.equal((await core.listProgress()).length, 0, 'nothing left in flight');
  // jobs.json keeps the summary.
  const saved = JSON.parse(fs.readFileSync(path.join(state, 'jobs.json'), 'utf8'));
  assert.equal(saved[0].actionsFound.pending, 1);
  // The labels job kind never triggers finding.
  assert.equal(runner.requests.filter((r) => r.outputSchema === FIND_SCHEMA).length, 1);
});
