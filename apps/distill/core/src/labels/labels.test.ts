import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, afterEach, before, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, CoreEvent, Job, RunRequest, RunResult, RunnerCapability } from '../contracts.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { statePaths } from '../store/paths.js';
import { decodeJob, recoverInterrupted } from '../store/jobs.js';
import { createEngine, type Engine } from '../engine/index.js';
import { IngestJobKind, JobContext, labelsPrompt } from '../engine/job-kinds.js';
import { defaultSettings } from '../store/settings.js';
import { newJob } from '../store/jobs.js';
import { parseFrontmatter, setLabelProperties } from './frontmatter.js';
import { labelPrompt, suggestLabels, toSuggestions } from './suggest.js';
import { countLabels, normalizeLabel, reviewLabels, scanPages, userLabels } from './vault.js';
import { buildLabelBundle } from './transaction.js';

const PRODUCT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../../..');
const PYTHON = execFileSync('python3', ['-c', 'import sys; print(sys.executable)']).toString().trim();
const CORE = path.join(PRODUCT_ROOT, 'scripts', 'claude-obsidian.py');

// ───────────── fakes ─────────────

/** Records requests; answers label runs with `labels` and ingest turns with `ingest` steps. */
class FakeRunner implements AgentRunner {
  readonly displayName: string;
  readonly models = [];
  readonly effortLevels = [];
  readonly defaultModel = 'm';
  readonly requests: RunRequest[] = [];
  constructor(
    readonly id: string,
    readonly answer: (req: RunRequest) => Partial<RunResult> | Promise<Partial<RunResult>>,
    readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>([
      'agentTools',
      'toolPermissions',
      'sessionResume',
      'structuredOutput',
    ]),
  ) {
    this.displayName = `Fake ${id}`;
  }
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    await new Promise((r) => setImmediate(r));
    const a = await this.answer(request);
    return { resultText: '', isError: false, costUSD: 0.002, denials: [], raw: '{}', ...a };
  }
}

const labelsAnswer =
  (labels: string[]) =>
  (): Partial<RunResult> => ({ structured: { labels } });

let tmp: string;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-labels-')));
});
afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

// ───────────── normalization & suggestion ─────────────

describe('label normalization', () => {
  test('normalizeLabel', () => {
    assert.equal(normalizeLabel('  #Green Tea '), 'green-tea');
    assert.equal(normalizeLabel('##Tea/Japanese'), 'tea/japanese');
    assert.equal(normalizeLabel('C++ & Rust!'), 'c-rust');
    assert.equal(normalizeLabel('2026'), undefined);
    assert.equal(normalizeLabel('#'), undefined);
    assert.equal(normalizeLabel('Café'), 'café');
  });

  test('toSuggestions dedupes, caps at 5 and marks existing', () => {
    const s = toSuggestions(['Tea', '#tea', 'Brewing', 'new one', 'a', 'b', 'c', 'd'], ['tea', 'brewing']);
    assert.deepEqual(s, [
      { name: 'tea', existing: true },
      { name: 'brewing', existing: true },
      { name: 'new-one', existing: false },
      { name: 'a', existing: false },
      { name: 'b', existing: false },
    ]);
  });

  test('userLabels rejects whitespace, strips #, dedupes, no cap', () => {
    assert.deepEqual(userLabels([' #Tea', 'tea', 'a', 'b', 'c', 'd', 'e', 'f']), ['tea', 'a', 'b', 'c', 'd', 'e', 'f']);
    assert.throws(() => userLabels(['green tea']), /whitespace/);
    assert.throws(() => userLabels(['123']), /not a valid label/);
  });

  test('suggestLabels runs a tool-less structured run in the scratch dir', async () => {
    const runner = new FakeRunner('claude-code', labelsAnswer(['Tea', 'Gyokuro', 'tea', 'Brewing Temp']));
    const settings = defaultSettings();
    const scratch = path.join(tmp, 'scratch');
    const out = await suggestLabels(
      { title: 'Gyokuro', text: 'Steep at 60 °C.', source: 'in-person' },
      { runners: createRunnerRegistry([runner]), settings, existing: ['tea', 'brewing'], scratchDir: scratch },
    );
    assert.deepEqual(out.labels, [
      { name: 'tea', existing: true },
      { name: 'gyokuro', existing: false },
      { name: 'brewing-temp', existing: false },
    ]);
    assert.equal(out.costUSD, 0.002);
    const req = runner.requests[0]!;
    assert.equal(req.workingDirectory, scratch);
    assert.ok(fs.existsSync(scratch));
    assert.deepEqual(req.availableTools, []);
    assert.deepEqual(req.allowedTools, []);
    assert.deepEqual(req.readableDirectories, []);
    assert.equal(req.pluginDirectory, undefined);
    assert.deepEqual(req.selection, { runnerID: 'claude-code', model: 'haiku', effort: 'low' });
    assert.match(req.outputSchema ?? '', /"labels"/);
    assert.ok(req.prompt.includes('tea, brewing'));
    assert.ok(req.prompt.includes('Steep at 60 °C.'));
  });

  test('suggestLabels uses the labelSuggest task default and falls back to JSON in the result text', async () => {
    const runner = new FakeRunner('other', () => ({ resultText: 'Sure: {"labels": ["x"]}' }), new Set(['structuredOutput']));
    const settings = { ...defaultSettings(), enabledRunners: ['other'], taskDefaults: { labelSuggest: { runnerID: 'other', model: 'mini' } } };
    const out = await suggestLabels({ text: 't' }, { runners: createRunnerRegistry([runner]), settings, existing: [], scratchDir: tmp });
    assert.deepEqual(out.labels, [{ name: 'x', existing: false }]);
    assert.equal(runner.requests[0]!.selection.model, 'mini');
  });

  test('suggestLabels fails without a usable runner', async () => {
    const settings = defaultSettings();
    await assert.rejects(
      suggestLabels({ text: 't' }, { runners: createRunnerRegistry([]), settings, existing: [], scratchDir: tmp }),
      /Unknown AI runner claude-code/,
    );
    const noSchema = new FakeRunner('claude-code', labelsAnswer([]), new Set(['agentTools']));
    await assert.rejects(
      suggestLabels({ text: 't' }, { runners: createRunnerRegistry([noSchema]), settings, existing: [], scratchDir: tmp }),
      /can't suggest labels/,
    );
  });

  test('labelPrompt says (none yet) for an empty vault and truncates long text', () => {
    const p = labelPrompt({ text: 'x'.repeat(9000) }, []);
    assert.ok(p.includes('(none yet)'));
    assert.ok(p.includes('[…truncated]'));
  });
});

// ───────────── frontmatter editing ─────────────

describe('setLabelProperties', () => {
  const page = '---\ntype: source\ntitle: "Tea"\ntags:\n  - old\n  - other\nstatus: seed\n---\n\n# Tea\n\nBody ---\n';

  test('replaces tags in place and keeps every other byte', () => {
    const out = setLabelProperties(page, { tags: ['tea', 'yes'], labels_by: 'ai', labels_reviewed: false, labels_origin: 'suggest' });
    assert.equal(
      out,
      '---\ntype: source\ntitle: "Tea"\ntags:\n  - tea\n  - "yes"\nlabels_by: ai\nlabels_reviewed: false\nlabels_origin: suggest\nstatus: seed\n---\n\n# Tea\n\nBody ---\n',
    );
    // and back to confirmed: unconfirmed marks removed
    const confirmed = setLabelProperties(out, { tags: ['tea'], labels_by: 'user' });
    assert.equal(confirmed, '---\ntype: source\ntitle: "Tea"\ntags:\n  - tea\nlabels_by: user\nstatus: seed\n---\n\n# Tea\n\nBody ---\n');
  });

  test('flow and scalar tags, unindented list items', () => {
    assert.equal(setLabelProperties('---\ntags: [a, b]\nx: 1\n---\nB', { tags: ['c'] }), '---\ntags:\n  - c\nx: 1\n---\nB');
    assert.equal(setLabelProperties('---\nx: 1\ntags: a\n---\nB', { tags: ['c'] }), '---\nx: 1\ntags:\n  - c\n---\nB');
    assert.equal(setLabelProperties('---\ntags:\n- a\n- b\nx: 1\n---\nB', { tags: ['c'] }), '---\ntags:\n  - c\nx: 1\n---\nB');
  });

  test('no frontmatter: a new block is prepended', () => {
    assert.equal(setLabelProperties('# Hi\n', { tags: ['a'], labels_by: 'user' }), '---\ntags:\n  - a\nlabels_by: user\n---\n# Hi\n');
    assert.equal(setLabelProperties('# Hi\n', { tags: [] }), '# Hi\n');
  });

  test('CRLF and BOM are preserved', () => {
    const text = '﻿---\r\ntitle: T\r\ntags:\r\n  - a\r\n---\r\nBody\r\n';
    assert.equal(setLabelProperties(text, { tags: ['b'], labels_by: 'user' }), '﻿---\r\ntitle: T\r\ntags:\r\n  - b\r\nlabels_by: user\r\n---\r\nBody\r\n');
  });

  test('a block left empty is removed; labels go at the end when there were none', () => {
    assert.equal(setLabelProperties('---\ntags:\n  - a\n---\nBody\n', { tags: [] }), 'Body\n');
    assert.equal(setLabelProperties('---\ntitle: T\n---\nB', { tags: ['x'] }), '---\ntitle: T\ntags:\n  - x\n---\nB');
    assert.equal(setLabelProperties('---\n---\nB', { tags: ['x'] }), '---\ntags:\n  - x\n---\nB');
  });

  test('the reader sees what the writer wrote', () => {
    const fm = parseFrontmatter(setLabelProperties(page, { tags: ['tea'], labels_by: 'ai', labels_reviewed: false, labels_origin: 'cli' }));
    assert.deepEqual(fm.tags, ['tea']);
    assert.equal(fm.labels_reviewed, 'false');
    assert.equal(fm.labels_origin, 'cli');
    assert.equal(fm.status, 'seed');
  });
});

// ───────────── vault scans ─────────────

function writePage(vault: string, rel: string, text: string): void {
  fs.mkdirSync(path.dirname(path.join(vault, rel)), { recursive: true });
  fs.writeFileSync(path.join(vault, rel), text);
}

describe('listLabels and labelReview', () => {
  test('counts labels, lists unconfirmed and unlabeled pages, skips system pages', async () => {
    const v = path.join(tmp, 'vault');
    writePage(v, 'wiki/index.md', '---\ntype: meta\ntags:\n  - meta\n---\n');
    writePage(v, 'wiki/hot.md', '# hot\n');
    writePage(v, 'wiki/meta/dashboard-x.md', '# meta\n');
    writePage(v, 'wiki/sources/a.md', '---\ntitle: "A"\ntags:\n  - tea\n  - brewing\nlabels_by: user\n---\n');
    writePage(v, 'wiki/sources/b.md', '---\ntitle: B\ntags: [tea]\nlabels_by: ai\nlabels_reviewed: false\nlabels_origin: queue-folder\n---\n');
    writePage(v, 'wiki/concepts/c.md', '---\ntitle: C\n---\n');
    writePage(v, 'wiki/concepts/d.md', 'no frontmatter\n');
    writePage(v, 'wiki/.hidden/e.md', '---\ntags: [x]\n---\n');
    const pages = await scanPages(v);
    assert.deepEqual(countLabels(pages), [
      { name: 'tea', count: 2, unconfirmed: 1 },
      { name: 'brewing', count: 1, unconfirmed: 0 },
    ]);
    assert.deepEqual(reviewLabels(pages), {
      toReview: [{ path: 'wiki/sources/b.md', title: 'B', labels: ['tea'], origin: 'queue-folder' }],
      unlabeled: [
        { path: 'wiki/concepts/c.md', title: 'C' },
        { path: 'wiki/concepts/d.md', title: 'd' },
      ],
    });
  });
});

// ───────────── engine harness ─────────────

interface Harness {
  vault: string;
  queue: string;
  engine: Engine;
  ingest: FakeRunner;
  labeler: FakeRunner;
  events: CoreEvent[];
}

let h: Harness | undefined;
afterEach(async () => {
  await h?.engine.whenIdle();
  await h?.engine.stop();
  h = undefined;
});

function setup(o: { vault?: string; labels?: (req: RunRequest) => Partial<RunResult> | Promise<Partial<RunResult>>; settings?: Record<string, unknown> } = {}): Harness {
  const vault = o.vault ?? path.join(tmp, 'vault');
  const state = path.join(tmp, 'state');
  const queue = path.join(tmp, 'queue');
  fs.mkdirSync(path.join(vault, 'inbox'), { recursive: true });
  if (!fs.existsSync(path.join(vault, '.claude-obsidian.json'))) fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  fs.mkdirSync(queue, { recursive: true });
  fs.mkdirSync(state, { recursive: true });
  fs.writeFileSync(
    path.join(state, 'settings.json'),
    JSON.stringify({
      vaults: [{ path: vault, queueDirectory: queue }],
      activeVaultPath: vault,
      productRoot: PRODUCT_ROOT,
      pythonPath: PYTHON,
      settleSeconds: 0,
      autoProcessEnabled: false,
      enabledRunners: ['claude-code', 'fake-labels'],
      taskDefaults: { labelSuggest: { runnerID: 'fake-labels', model: 'tiny' } },
      ...o.settings,
    }),
  );
  const ingest = new FakeRunner('claude-code', () => ({ structured: { status: 'nothing_to_do', summary: 'ok' } }));
  const labeler = new FakeRunner('fake-labels', o.labels ?? labelsAnswer(['Tea', 'Brewing']), new Set(['structuredOutput']));
  const engine = createEngine({ paths: statePaths(state), runners: createRunnerRegistry([ingest, labeler]), tickMs: 60_000 });
  const events: CoreEvent[] = [];
  engine.subscribe((e) => events.push(e));
  h = { vault, queue, engine, ingest, labeler, events };
  return h;
}

const manifestOf = (notePath: string) => JSON.parse(fs.readFileSync(notePath.replace(/\.md$/, '.distill.json'), 'utf8'));

describe('addNote and labelNote', () => {
  test('wait: suggestions come back synchronously and are recorded in the manifest', async () => {
    const { engine, labeler, vault } = setup();
    writePage(vault, 'wiki/sources/x.md', '---\ntags: [tea]\n---\n');
    const r = await engine.addNote({ title: 'Sencha', text: 'Green tea.', origin: 'cli', suggest: 'wait' });
    assert.match(r.requestID, /^[0-9a-f-]{36}$/);
    assert.deepEqual(r.suggestedLabels, [
      { name: 'tea', existing: true },
      { name: 'brewing', existing: false },
    ]);
    assert.equal(labeler.requests.length, 1);
    assert.ok(labeler.requests[0]!.prompt.includes('Labels already used in the vault (most used first):\ntea'));
    const m = manifestOf(r.notePath);
    assert.equal(m.requestID, r.requestID);
    assert.equal(m.origin, 'cli');
    assert.deepEqual(m.suggestedLabels, r.suggestedLabels);
    assert.equal(m.labels, undefined);
  });

  test('wait: a failed suggestion still queues the note, with suggestError', async () => {
    const { engine } = setup({ labels: () => ({ isError: true, resultText: 'rate limited' }) });
    const r = await engine.addNote({ title: 'N', text: 't', origin: 'cli', suggest: 'wait' });
    assert.equal(r.suggestError, 'rate limited');
    assert.equal(r.suggestedLabels, undefined);
    assert.ok(fs.existsSync(r.notePath));
    assert.equal(manifestOf(r.notePath).suggestError, 'rate limited');
  });

  test('background: emits labelSuggestions and records them; none: no run', async () => {
    const { engine, labeler, events } = setup();
    const r = await engine.addNote({ title: 'Bg', text: 'about tea' });
    assert.equal(r.suggestedLabels, undefined);
    await engine.whenIdle();
    const ev = events.find((e) => e.type === 'labelSuggestions');
    assert.deepEqual(ev, {
      type: 'labelSuggestions',
      requestID: r.requestID,
      notePath: r.notePath,
      labels: [
        { name: 'tea', existing: false },
        { name: 'brewing', existing: false },
      ],
      costUSD: 0.002,
    });
    assert.equal(manifestOf(r.notePath).origin, 'app');
    assert.deepEqual(manifestOf(r.notePath).suggestedLabels, (ev as { labels: unknown }).labels);

    const before = labeler.requests.length;
    const n = await engine.addNote({ title: 'None', text: 'x', suggest: 'none' });
    await engine.whenIdle();
    assert.equal(labeler.requests.length, before);
    assert.equal(manifestOf(n.notePath).suggestedLabels, undefined);
  });

  test('labels on addNote are confirmed: written as tags, no suggestion run', async () => {
    const { engine, labeler } = setup();
    const r = await engine.addNote({ title: 'L', text: 'x', labels: ['#Tea', 'tea', 'Brewing'], suggest: 'wait' });
    assert.equal(labeler.requests.length, 0);
    assert.deepEqual(manifestOf(r.notePath).labels, ['tea', 'brewing']);
    assert.match(fs.readFileSync(r.notePath, 'utf8'), /\ntags:\n {2}- tea\n {2}- brewing\n---\n/);
    await assert.rejects(engine.addNote({ title: 'Bad', text: 'x', labels: ['green tea'] }), { code: 'invalid_request' });
  });

  test('labelNote before the batch rewrites manifest and tags; after the batch → invalid_state', async () => {
    const { engine } = setup();
    const r = await engine.addNote({ title: 'Q', text: 'body', origin: 'cli', suggest: 'none' });
    const out = await engine.labelNote(r.requestID, ['Tea', '#oolong']);
    assert.deepEqual(out, { notePath: r.notePath, labels: ['tea', 'oolong'] });
    assert.deepEqual(manifestOf(r.notePath).labels, ['tea', 'oolong']);
    const text = fs.readFileSync(r.notePath, 'utf8');
    assert.match(text, /^---\ntitle: "Q"\ncreated: \d{4}-\d{2}-\d{2}\ntags:\n {2}- tea\n {2}- oolong\n---\n\nbody\n$/);

    await assert.rejects(engine.labelNote('nope', ['a']), { code: 'not_found' });
    const job = await engine.processQueue({ force: true });
    assert.ok(job);
    await engine.whenIdle();
    await assert.rejects(engine.labelNote(r.requestID, ['x']), { code: 'invalid_state' });
  });

  test('queue = inbox/: labels and suggestions live in Distill state; the note files are never edited (decision 2026-10-04)', async () => {
    const vault = path.join(tmp, 'vault');
    const { engine, ingest } = setup({
      settings: { vaults: [{ path: vault, queueDirectory: path.join(vault, 'inbox') }], labeling: { autoLabelQueueFolder: false, cliFallbackToAI: true } },
    });
    const files = (notePath: string) => [notePath, notePath.replace(/\.md$/, '.distill.json')];
    const snap = (notePath: string) => files(notePath).map((f) => [fs.readFileSync(f, 'utf8'), fs.statSync(f).mtimeMs]);

    // Background suggestion lands in the overlay, not the manifest.
    const bg = await engine.addNote({ title: 'Bg', text: 'about tea', origin: 'cli' });
    const bgBefore = snap(bg.notePath);
    await engine.whenIdle();
    assert.deepEqual(snap(bg.notePath), bgBefore);
    assert.equal(manifestOf(bg.notePath).suggestedLabels, undefined);

    // Confirmed labels, and confirmed-empty ([] = no labels, no AI fallback).
    const q = await engine.addNote({ title: 'Q', text: 'body', origin: 'cli', suggest: 'none' });
    const e = await engine.addNote({ title: 'E', text: 'body', origin: 'cli', suggest: 'none' });
    const qBefore = snap(q.notePath);
    assert.deepEqual(await engine.labelNote(q.requestID, ['Tea']), { notePath: q.notePath, labels: ['tea'] });
    await engine.labelNote(e.requestID, []);
    assert.deepEqual(snap(q.notePath), qBefore, 'neither the note nor its manifest changed');
    assert.ok(!fs.readdirSync(path.join(vault, 'inbox')).some((n) => n.endsWith('.tmp')), 'no temp file in inbox/');
    const stored = JSON.parse(fs.readFileSync(path.join(tmp, 'state', 'labels', 'notes.json'), 'utf8'));
    assert.deepEqual(stored[q.requestID].labels, ['tea']);
    assert.deepEqual(stored[e.requestID].labels, []);

    // The queue row reads the overlay.
    const row = engine.listQueue().find((r) => r.path === q.notePath)!;
    assert.equal(row.note?.labelsConfirmed, true);

    // The batch reads it too: confirmed, confirmed-empty, and the background suggestion (CLI fallback).
    await engine.processQueue({ force: true });
    await engine.whenIdle();
    const prompt = ingest.requests[0]!.prompt;
    assert.ok(prompt.includes('- inbox/Q.md: labels the user confirmed:\n    tags:\n      - tea\n    labels_by: user'), prompt);
    assert.ok(prompt.includes('- inbox/E.md: no labels.'));
    assert.ok(prompt.includes('- inbox/Bg.md: AI labels the user has not confirmed yet:\n    tags:\n      - tea\n      - brewing'));
    assert.deepEqual(snap(q.notePath), qBefore);
  });
});

// ───────────── batch: ingest prompt per origin ─────────────

describe('batch labels in the ingest prompt', () => {
  test('confirmed, cli fallback, app (none), confirmed-empty, queue-folder text and binary files', async () => {
    const { engine, ingest, labeler, queue } = setup({ labels: labelsAnswer(['Queue Topic']) });
    const confirmed = await engine.addNote({ title: 'Confirmed', text: 'c', labels: ['tea'] });
    const cliWait = await engine.addNote({ title: 'Cli wait', text: 'w', origin: 'cli', suggest: 'wait' });
    const cliLate = await engine.addNote({ title: 'Cli late', text: 'late text', origin: 'cli', suggest: 'none' });
    const app = await engine.addNote({ title: 'App', text: 'a', suggest: 'none' });
    const empty = await engine.addNote({ title: 'Empty', text: 'e', origin: 'cli', suggest: 'none' });
    await engine.labelNote(empty.requestID, []);
    fs.writeFileSync(path.join(queue, 'dropped.md'), '---\ntitle: D\n---\nDropped text about queues\n');
    fs.writeFileSync(path.join(queue, 'scan.pdf'), '%PDF-1.4');
    fs.writeFileSync(path.join(queue, 'tagged.md'), '---\ntags: [Mine]\n---\nOwn tags\n');
    await engine.whenIdle();
    labeler.requests.length = 0;

    const job = await engine.processQueue({ force: true });
    assert.ok(job);
    await engine.whenIdle();

    // Pre-step: one suggestion for the late CLI note, one for the dropped .md; none for the PDF.
    assert.equal(labeler.requests.length, 2);
    assert.ok(labeler.requests.some((r) => r.prompt.includes('late text')));
    assert.ok(labeler.requests.some((r) => r.prompt.includes('Dropped text about queues') && !r.prompt.includes('title: D')));
    const prompt = ingest.requests[0]!.prompt;
    const section = prompt.slice(prompt.indexOf('Labels (the `tags` property)'));
    assert.ok(section.includes('- inbox/Confirmed.md: labels the user confirmed:\n    tags:\n      - tea\n    labels_by: user'));
    assert.ok(
      section.includes(
        '- inbox/Cli wait.md: AI labels the user has not confirmed yet:\n    tags:\n      - queue-topic\n    labels_by: ai\n    labels_reviewed: false\n    labels_origin: cli',
      ),
    );
    assert.ok(section.includes('- inbox/Cli late.md: AI labels the user has not confirmed yet:\n    tags:\n      - queue-topic'));
    assert.ok(section.includes('- inbox/App.md: no labels.'));
    assert.ok(section.includes('- inbox/Empty.md: no labels.'));
    assert.ok(section.includes('labels_origin: queue-folder'));
    assert.ok(section.includes('- inbox/dropped.md: AI labels'));
    assert.ok(section.includes('- inbox/scan.pdf: no labels.'));
    assert.ok(section.includes('- inbox/tagged.md: labels the user confirmed:\n    tags:\n      - mine\n'), 'own tags kept, no AI call');
    assert.ok(!section.includes('distill.json:'), 'manifests are not sources');
    assert.ok(prompt.includes('only the Labels section of this prompt decides labels'));
    const final = engine.getJob(job.id)!;
    assert.ok(final.turns.some((t) => t.author === 'app' && t.text.startsWith('Suggested labels for 2 of 2 file(s).') && t.costUSD > 0));
    void confirmed;
    void cliWait;
    void cliLate;
    void app;
  });

  test('preferences off: no fallback and no queue-folder labels', async () => {
    const { engine, ingest, labeler, queue } = setup({ settings: { labeling: { autoLabelQueueFolder: false, cliFallbackToAI: false } } });
    await engine.addNote({ title: 'Cli', text: 'x', origin: 'cli', suggest: 'none' });
    fs.writeFileSync(path.join(queue, 'dropped.md'), 'x');
    await engine.processQueue({ force: true });
    await engine.whenIdle();
    assert.equal(labeler.requests.length, 0);
    const prompt = ingest.requests[0]!.prompt;
    assert.ok(prompt.includes('- inbox/Cli.md: no labels.'));
    assert.ok(prompt.includes('- inbox/dropped.md: no labels.'));
  });

  test('labelsPrompt is empty without a plan; JobContext carries it into initialPrompt', () => {
    assert.equal(labelsPrompt([]), '');
    const job = newJob({ id: 'job-1', kind: 'ingest', vaultPath: '/v', files: ['inbox/a.md'], model: 'm', now: new Date() });
    const ctx = new JobContext(job, { path: '/v', queueDirectory: '/q' }, defaultSettings(), [
      { file: 'inbox/a.md', labels: ['x'], by: 'user' },
    ]);
    assert.ok(IngestJobKind.initialPrompt(ctx).includes('- inbox/a.md: labels the user confirmed:'));
  });
});

// ───────────── core-built transactions with the real Python core ─────────────

let template: string;
before(() => {
  template = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-labels-vault-')));
  const vault = path.join(template, 'vault');
  const dry = JSON.parse(
    execFileSync(PYTHON, [CORE, 'init', vault, '--operation-id', 't', '--generated-at', '2026-10-01T00:00:00Z']).toString(),
  );
  execFileSync(PYTHON, [
    CORE, 'init', vault, '--operation-id', 't', '--generated-at', '2026-10-01T00:00:00Z',
    '--apply', '--approved-plan-sha256', dry.approved_plan_sha256,
  ]);
});
after(() => fs.rmSync(template, { recursive: true, force: true }));

function realVault(): string {
  const vault = path.join(tmp, 'vault');
  fs.cpSync(path.join(template, 'vault'), vault, { recursive: true });
  writePage(vault, 'wiki/sources/a.md', '---\ntype: source\ntitle: "A"\ntags:\n  - draft\nstatus: seed\n---\n\n# A\n\nAbout sencha.\n');
  writePage(vault, 'wiki/concepts/b.md', '# B\n\nNo frontmatter here.\n');
  return vault;
}

const sha = (file: string) => createHash('sha256').update(fs.readFileSync(file)).digest('hex');

describe('label jobs (core builds, inspects and applies)', () => {
  test('confirmLabels → valid plan → approve → exactly the pages change', async () => {
    const vault = realVault();
    const { engine, ingest } = setup({ vault });
    const untouched = sha(path.join(vault, 'wiki/index.md'));
    const job = await engine.confirmLabels([
      { path: 'wiki/sources/a.md', labels: ['Tea', 'sencha'] },
      { path: 'wiki/concepts/b.md', labels: ['tea'] },
    ]);
    assert.equal(job.state, 'awaitingApproval', job.approval?.planError ?? job.error ?? '');
    assert.equal(job.kind, 'labels');
    assert.equal(job.approval?.plan?.valid, true);
    assert.equal(job.approval?.plan?.operation_type, 'markdown');
    assert.deepEqual(job.approval?.plan?.changed_paths, ['wiki/sources/a.md', 'wiki/concepts/b.md']);
    const bundle = JSON.parse(fs.readFileSync(job.approval!.bundlePath!, 'utf8'));
    assert.equal(bundle.schema, 'claude-obsidian.transaction.v1');
    assert.equal(bundle.expected_hashes['wiki/sources/a.md'], sha(path.join(vault, 'wiki/sources/a.md')));
    assert.ok(job.approval!.bundlePath!.startsWith(path.join(vault, '.vault-meta/worker', job.id) + '/'));
    await assert.rejects(engine.reply(job.id, 'hi'), { code: 'invalid_state' });
    await assert.rejects(engine.confirmLabels([{ path: 'wiki/sources/a.md', labels: ['x'] }]), { code: 'busy' });

    await engine.approve(job.id);
    assert.equal(engine.getJob(job.id)!.state, 'running');
    await engine.whenIdle();
    const done = engine.getJob(job.id)!;
    assert.equal(done.state, 'completed', done.error ?? '');
    assert.deepEqual(done.changedPaths, ['wiki/sources/a.md', 'wiki/concepts/b.md']);
    assert.equal(done.operationID, job.approval?.plan?.operation_id);
    assert.equal(
      fs.readFileSync(path.join(vault, 'wiki/sources/a.md'), 'utf8'),
      '---\ntype: source\ntitle: "A"\ntags:\n  - tea\n  - sencha\nlabels_by: user\nstatus: seed\n---\n\n# A\n\nAbout sencha.\n',
    );
    assert.equal(fs.readFileSync(path.join(vault, 'wiki/concepts/b.md'), 'utf8'), '---\ntags:\n  - tea\nlabels_by: user\n---\n# B\n\nNo frontmatter here.\n');
    assert.equal(sha(path.join(vault, 'wiki/index.md')), untouched);
    assert.equal(ingest.requests.length, 0, 'no agent turn');
  });

  test('suggestLabelsForPages → unconfirmed AI labels; confirming clears the marks', async () => {
    const vault = realVault();
    const { engine, labeler } = setup({ vault, labels: labelsAnswer(['Green Tea', 'draft']) });
    const started = await engine.suggestLabelsForPages(['wiki/concepts/b.md']);
    assert.equal(started.state, 'running', 'returned at once');
    await engine.whenIdle();
    const job = engine.getJob(started.id)!;
    assert.equal(job.state, 'awaitingApproval', job.approval?.planError ?? job.error ?? '');
    assert.equal(job.runnerID, 'fake-labels');
    assert.equal(job.model, 'tiny');
    assert.ok(job.turns.some((t) => t.author === 'worker' && t.costUSD === 0.002));
    assert.deepEqual(labeler.requests[0]!.availableTools, []);
    assert.ok(labeler.requests[0]!.prompt.includes('No frontmatter here.'));
    await engine.approve(job.id);
    await engine.whenIdle();
    assert.equal(engine.getJob(job.id)!.state, 'completed');
    assert.equal(
      fs.readFileSync(path.join(vault, 'wiki/concepts/b.md'), 'utf8'),
      '---\ntags:\n  - green-tea\n  - draft\nlabels_by: ai\nlabels_reviewed: false\nlabels_origin: suggest\n---\n# B\n\nNo frontmatter here.\n',
    );
    const review = await engine.labelReview();
    assert.deepEqual(review.toReview, [{ path: 'wiki/concepts/b.md', title: 'b', labels: ['green-tea', 'draft'], origin: 'suggest' }]);
    assert.deepEqual(await engine.listLabels(), [
      { name: 'draft', count: 2, unconfirmed: 1 },
      { name: 'green-tea', count: 1, unconfirmed: 1 },
    ]);

    const confirm = await engine.confirmLabels([{ path: 'wiki/concepts/b.md', labels: ['green-tea'] }]);
    await engine.approve(confirm.id);
    await engine.whenIdle();
    assert.equal(
      fs.readFileSync(path.join(vault, 'wiki/concepts/b.md'), 'utf8'),
      '---\ntags:\n  - green-tea\nlabels_by: user\n---\n# B\n\nNo frontmatter here.\n',
    );
    assert.deepEqual((await engine.labelReview()).toReview, []);
  });

  test('suggestLabelsForPages: returns running, skips labeled pages, counts pages in labelPages progress', async () => {
    const vault = realVault();
    writePage(vault, 'wiki/concepts/c.md', '# C\n\nAbout gyokuro.\n');
    const { engine, labeler, events } = setup({ vault });
    const job = await engine.suggestLabelsForPages(['wiki/sources/a.md', 'wiki/concepts/b.md', 'wiki/concepts/c.md']);
    assert.equal(job.state, 'running');
    assert.deepEqual(job.files, ['wiki/concepts/b.md', 'wiki/concepts/c.md']);
    assert.equal(job.turns[0]!.text, 'Suggest labels for 2 pages. Skipped 1 page that already has labels.');
    await engine.whenIdle();
    assert.equal(labeler.requests.length, 2, 'the labeled page never reaches the AI');
    const done = engine.getJob(job.id)!;
    assert.equal(done.state, 'awaitingApproval', done.approval?.planError ?? done.error ?? '');
    assert.ok(done.approval!.skipped.includes('wiki/sources/a.md: already has labels'));
    assert.deepEqual(done.approval!.plan!.changed_paths, ['wiki/concepts/b.md', 'wiki/concepts/c.md']);
    const progress = events.flatMap((e) => (e.type === 'progress' && e.progress.key === job.id ? [e.progress] : []));
    assert.deepEqual(
      progress.map((p) => [p.kind, p.done, p.total, p.message, !!p.finished]),
      [
        ['labelPages', 0, 2, 'Suggesting labels for 2 pages', false],
        ['labelPages', 1, 2, 'Suggesting labels for 2 pages', false],
        ['labelPages', 2, 2, 'Suggesting labels for 2 pages', false],
        ['labelPages', 2, 2, 'Preparing the change for Review', false],
        ['labelPages', 2, 2, 'Ready for review', true],
      ],
    );
    assert.equal(progress[0]!.runnerID, 'fake-labels');
    assert.equal(progress[0]!.model, 'tiny');
    await assert.rejects(engine.suggestLabelsForPages(['wiki/sources/a.md']), { code: 'busy' });
    await engine.reject(job.id);
    await assert.rejects(engine.suggestLabelsForPages(['wiki/sources/a.md']), { code: 'invalid_request', message: /already has labels/ });
  });

  test('suggestLabelsForPages: cancel keeps the finished pages for review', async () => {
    const vault = realVault();
    writePage(vault, 'wiki/concepts/c.md', '# C\n\nAbout gyokuro.\n');
    writePage(vault, 'wiki/concepts/d.md', '# D\n\nAbout matcha.\n');
    let release!: () => void;
    const hung = new Promise<void>((r) => (release = r));
    const { engine, labeler } = setup({
      vault,
      labels: async (req) => {
        if (!req.prompt.includes('About gyokuro.')) return { structured: { labels: ['tea'] } };
        release();
        // Hang until the job is cancelled; a real runner rejects on abort.
        return new Promise((_, reject) => req.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
      },
    });
    const job = await engine.suggestLabelsForPages(['wiki/concepts/b.md', 'wiki/concepts/c.md', 'wiki/concepts/d.md']);
    await hung;
    await engine.cancel(job.id);
    await engine.whenIdle();
    const done = engine.getJob(job.id)!;
    assert.equal(done.state, 'awaitingApproval', done.approval?.planError ?? done.error ?? '');
    assert.deepEqual(done.approval!.plan!.changed_paths, ['wiki/concepts/b.md']);
    assert.ok(done.approval!.skipped.includes('wiki/concepts/c.md: not done (stopped)'));
    assert.ok(done.approval!.skipped.includes('wiki/concepts/d.md: not done (stopped)'));
    assert.ok(done.turns.some((t) => t.text === 'Stopped after 1 of 3 pages; suggested labels for 1 page.'));
    assert.equal(labeler.requests.length, 2, 'no page after the stop');
  });

  test('suggestLabelsForPages: every page fails → failed, labelPages finishes with the error', async () => {
    const vault = realVault();
    const { engine, events } = setup({ vault, labels: () => ({ isError: true, resultText: 'quota exceeded' }) });
    const job = await engine.suggestLabelsForPages(['wiki/concepts/b.md']);
    await engine.whenIdle();
    assert.equal(engine.getJob(job.id)!.state, 'failed');
    const progress = events.flatMap((e) => (e.type === 'progress' && e.progress.key === job.id ? [e.progress] : []));
    const last = progress.at(-1)!;
    assert.equal(progress.filter((p) => p.finished).length, 1);
    assert.equal(last.kind, 'labelPages');
    assert.equal(last.finished, true);
    assert.match(last.error ?? '', /No labels could be suggested/);
    assert.match(last.error ?? '', /quota exceeded/);
  });

  test('suggestLabelsForPages: cancel before any page finishes → cancelled', async () => {
    const vault = realVault();
    let release!: () => void;
    const hung = new Promise<void>((r) => (release = r));
    const { engine, events } = setup({
      vault,
      labels: async (req) => {
        release();
        return new Promise((_, reject) => req.signal?.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
      },
    });
    const job = await engine.suggestLabelsForPages(['wiki/concepts/b.md']);
    await hung;
    await engine.cancel(job.id);
    await engine.whenIdle();
    assert.equal(engine.getJob(job.id)!.state, 'cancelled');
    const last = events.filter((e) => e.type === 'progress').at(-1);
    assert.ok(last?.type === 'progress' && last.progress.finished && last.progress.key === job.id && last.progress.message === 'Cancelled');
  });

  test('a page edited after review: apply exits 75, the plan is rebuilt for a new review', async () => {
    const vault = realVault();
    const { engine } = setup({ vault });
    const job = await engine.confirmLabels([{ path: 'wiki/sources/a.md', labels: ['tea'] }]);
    const firstPlan = job.approval!.plan!;
    fs.appendFileSync(path.join(vault, 'wiki/sources/a.md'), '\nEdited by hand.\n');
    await engine.approve(job.id);
    await engine.whenIdle();
    const rebuilt = engine.getJob(job.id)!;
    assert.equal(rebuilt.state, 'awaitingApproval', rebuilt.error ?? '');
    assert.notEqual(rebuilt.approval?.plan?.operation_id, firstPlan.operation_id);
    assert.ok(rebuilt.turns.some((t) => t.text.includes('plan was rebuilt')));
    await engine.approve(job.id);
    await engine.whenIdle();
    assert.equal(engine.getJob(job.id)!.state, 'completed');
    const text = fs.readFileSync(path.join(vault, 'wiki/sources/a.md'), 'utf8');
    assert.ok(text.includes('tags:\n  - tea\nlabels_by: user\n'));
    assert.ok(text.endsWith('\nEdited by hand.\n'));
  });

  test('nothing to change completes at once; bad paths are rejected; reject works', async () => {
    const vault = realVault();
    const { engine } = setup({ vault });
    const noop = await engine.confirmLabels([{ path: 'wiki/missing.md', labels: ['x'] }]);
    assert.equal(noop.state, 'completed');
    assert.ok(noop.turns.some((t) => t.text.includes('wiki/missing.md: not found')));
    await assert.rejects(engine.confirmLabels([{ path: '../etc/passwd.md', labels: ['x'] }]), { code: 'invalid_request' });
    await assert.rejects(engine.confirmLabels([{ path: '.raw/x.md', labels: ['x'] }]), { code: 'invalid_request' });
    await assert.rejects(engine.suggestLabelsForPages([]), { code: 'invalid_request' });
    const job = await engine.confirmLabels([{ path: 'wiki/sources/a.md', labels: ['x'] }]);
    await engine.reject(job.id);
    assert.equal(engine.getJob(job.id)!.state, 'rejected');
    assert.ok(fs.readFileSync(path.join(vault, 'wiki/sources/a.md'), 'utf8').includes('  - draft\n'));
  });
});

describe('core applies for runners without toolPermissions', () => {
  test('an ingest job from a sandboxedWrites runner is applied by the core', async () => {
    const vault = realVault();
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
        taskDefaults: Object.fromEntries(['ingest', 'ask', 'labelSuggest', 'imageText'].map((t) => [t, { runnerID: 'sandboxed', model: 'x' }])),
      }),
    );
    let engine!: Engine;
    const runner = new FakeRunner(
      'sandboxed',
      () => {
        // Phase 1: the runner writes its bundle into the job directory and asks for approval.
        const job = engine.listJobs()[0]!;
        const dir = path.join(vault, '.vault-meta/worker', job.id);
        fs.mkdirSync(dir, { recursive: true });
        const content = '---\ntitle: New\n---\nNew page.\n';
        fs.writeFileSync(
          path.join(dir, 'bundle.json'),
          JSON.stringify({
            schema: 'claude-obsidian.transaction.v1',
            operation_id: `${job.id}-ingest`,
            operation_type: 'markdown',
            expected_hashes: { 'wiki/new.md': null },
            writes: [{ path: 'wiki/new.md', mode: 'create', content }],
          }),
        );
        return { structured: { status: 'needs_approval', summary: 'Adds a page.', bundle_path: path.join(dir, 'bundle.json') } };
      },
      new Set<RunnerCapability>(['agentTools', 'sandboxedWrites', 'sessionResume', 'structuredOutput']),
    );
    engine = createEngine({ paths: statePaths(state), runners: createRunnerRegistry([runner]), tickMs: 60_000 });
    h = { vault, queue, engine, ingest: runner, labeler: runner, events: [] };
    fs.writeFileSync(path.join(queue, 'a.md'), 'x');
    const job = await engine.processQueue({ force: true });
    await engine.whenIdle();
    assert.equal(engine.getJob(job!.id)!.state, 'awaitingApproval', engine.getJob(job!.id)!.approval?.planError ?? '');
    await engine.approve(job!.id);
    await engine.whenIdle();
    const done = engine.getJob(job!.id)!;
    assert.equal(done.state, 'completed', done.error ?? '');
    assert.deepEqual(done.changedPaths, ['wiki/new.md']);
    assert.equal(runner.requests.length, 1, 'the runner never runs the apply');
    assert.equal(fs.readFileSync(path.join(vault, 'wiki/new.md'), 'utf8'), '---\ntitle: New\n---\nNew page.\n');
  });
});

describe('recovery', () => {
  test('a label job interrupted while applying keeps its plan', () => {
    const job = decodeJob({
      id: 'job-1', kind: 'labels', vaultPath: '/v', state: 'running', createdAt: '2026-10-01T00:00:00Z',
      approval: { summary: 'Confirm labels', questions: [], denials: [], skipped: [], bundlePath: '/v/b.json',
        plan: { operation_id: 'op', operation_type: 'markdown', valid: true, changed_paths: ['wiki/a.md'], approval_sha256: 'a'.repeat(64) } },
    }) as Job;
    const r = recoverInterrupted(job);
    assert.equal(r.state, 'awaitingApproval');
    assert.equal(r.approval?.plan?.operation_id, 'op');
    assert.ok(r.approval?.summary.endsWith('Confirm labels'));
  });
});

// keep buildLabelBundle importable for callers (used by the engine)
void buildLabelBundle;
