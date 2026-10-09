import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import type { AgentRunner, RunRequest, RunResult, RunnerCapability, Settings } from '../contracts.js';
import { createRunnerRegistry } from '../runners/registry.js';
import { defaultSettings } from '../store/settings.js';
import { statePaths } from '../store/paths.js';
import { createEngine } from './index.js';
import { cleanImageText, extractImageText, NO_TEXT, validateImagePath } from './image-text.js';

/** Records requests and what the scratch directory held during the run; never calls an AI. */
class FakeVisionRunner implements AgentRunner {
  readonly displayName = 'Fake Claude';
  readonly models = [{ id: 'haiku', label: 'Haiku' }];
  readonly effortLevels = ['low'];
  readonly defaultModel = 'haiku';
  readonly requests: RunRequest[] = [];
  readonly seen: string[][] = [];
  constructor(
    readonly id: string,
    readonly answer: (req: RunRequest) => Partial<RunResult> | Promise<Partial<RunResult>>,
    readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['agentTools', 'toolPermissions', 'vision']),
  ) {}
  problems() {
    return [];
  }
  async run(request: RunRequest): Promise<RunResult> {
    this.requests.push(request);
    this.seen.push(fs.readdirSync(request.workingDirectory));
    const a = await this.answer(request);
    return { resultText: '', isError: false, costUSD: 0, denials: [], raw: '{}', ...a };
  }
}

let tmp: string;
let image: string;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-image-text-')));
  image = path.join(tmp, 'brewing-card.png');
  fs.writeFileSync(image, Buffer.from('89504e470d0a1a0a', 'hex'));
});
afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

function opts(runner: AgentRunner, settings: Settings = defaultSettings()) {
  return {
    runners: createRunnerRegistry([runner]),
    settings,
    selection: { runnerID: runner.id, model: 'haiku', effort: 'low' },
    scratchRoot: path.join(tmp, 'scratch'),
  };
}

describe('extractImageText', () => {
  test('runs with only Read, on a copy in an empty scratch dir that is removed afterwards', async () => {
    const runner = new FakeVisionRunner('claude-code', () => ({ resultText: '**Gyokuro brewing card**\n- 60 °C, 2 min' }));
    const out = await extractImageText({ imagePath: image }, opts(runner));
    assert.deepEqual(out, { text: '**Gyokuro brewing card**\n- 60 °C, 2 min', model: 'Haiku' });
    const req = runner.requests[0]!;
    assert.deepEqual(req.availableTools, ['Read']);
    assert.deepEqual(req.allowedTools, ['Read']);
    assert.deepEqual(req.readableDirectories, []);
    assert.equal(req.pluginDirectory, undefined);
    assert.deepEqual(req.selection, { runnerID: 'claude-code', model: 'haiku', effort: 'low' });
    assert.ok(req.workingDirectory.startsWith(path.join(tmp, 'scratch')));
    assert.deepEqual(runner.seen[0], ['image.png']);
    assert.deepEqual(req.images, [path.join(req.workingDirectory, 'image.png')]);
    assert.match(req.prompt, /\.\/image\.png/);
    assert.equal(fs.existsSync(req.workingDirectory), false, 'scratch removed');
    assert.ok(fs.existsSync(image), 'the original is untouched');
  });

  test('a model API runner gets the image attached and no tools', async () => {
    const runner = new FakeVisionRunner('openrouter', () => ({ resultText: 'Hello' }), new Set<RunnerCapability>(['vision', 'structuredOutput']));
    const settings = defaultSettings();
    settings.enabledRunners = ['openrouter'];
    const out = await extractImageText({ imagePath: image }, opts(runner, settings));
    assert.equal(out.text, 'Hello');
    assert.deepEqual(runner.requests[0]!.availableTools, []);
    assert.equal(runner.requests[0]!.images?.length, 1);
  });

  test('no text → empty string; a wrapping fence is removed', async () => {
    assert.equal(cleanImageText(`  ${NO_TEXT}\n`), '');
    assert.equal(cleanImageText(`\`${NO_TEXT}\``), '');
    assert.equal(cleanImageText('```markdown\n# Card\n- a\n```'), '# Card\n- a');
    assert.equal(cleanImageText('| a | b |\n|---|---|\n| 1 | 2 |'), '| a | b |\n|---|---|\n| 1 | 2 |');
    const runner = new FakeVisionRunner('claude-code', () => ({ resultText: NO_TEXT }));
    assert.deepEqual(await extractImageText({ imagePath: image }, opts(runner)), { text: '', model: 'Haiku' });
  });

  test('a runner error is thrown with its message; scratch is still removed', async () => {
    const runner = new FakeVisionRunner('claude-code', () => ({ isError: true, resultText: 'Claude Code isn’t signed in.' }));
    await assert.rejects(extractImageText({ imagePath: image }, opts(runner)), /isn’t signed in/);
    assert.deepEqual(fs.readdirSync(path.join(tmp, 'scratch')), []);
  });

  test('a turned-off or blind runner is refused before running', async () => {
    const off = new FakeVisionRunner('openai', () => ({}));
    await assert.rejects(extractImageText({ imagePath: image }, opts(off)), /turned off/);
    const blind = new FakeVisionRunner('claude-code', () => ({}), new Set<RunnerCapability>(['agentTools']));
    await assert.rejects(extractImageText({ imagePath: image }, opts(blind)), /can't read images/);
    assert.equal(off.requests.length + blind.requests.length, 0);
  });

  test('aborting the signal stops the run', async () => {
    const controller = new AbortController();
    const runner = new FakeVisionRunner('claude-code', (req) =>
      new Promise((_resolve, reject) => req.signal?.addEventListener('abort', () => reject(new Error('Cancelled.')))),
    );
    const run = extractImageText({ imagePath: image }, { ...opts(runner), signal: controller.signal });
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(runner.requests[0]?.signal, controller.signal);
    controller.abort();
    await assert.rejects(run, /Cancelled/);
  });

  test('the path must be an absolute, readable image file of a supported type', () => {
    assert.throws(() => validateImagePath(''), /required/);
    assert.throws(() => validateImagePath('card.png'), /absolute/);
    assert.throws(() => validateImagePath(path.join(tmp, 'missing.png')), /not found/);
    assert.throws(() => validateImagePath(tmp), /Not a file/);
    const heic = path.join(tmp, 'photo.heic');
    fs.writeFileSync(heic, 'x');
    assert.throws(() => validateImagePath(heic), /Unsupported image type \.heic/);
    const txt = path.join(tmp, 'notes.txt');
    fs.writeFileSync(txt, 'x');
    assert.throws(() => validateImagePath(txt), /Unsupported/);
    assert.equal(validateImagePath(image), image);
  });
});

describe('engine.extractImageText', () => {
  function engineWith(runner: AgentRunner, taskDefaults?: Settings['taskDefaults']) {
    const state = path.join(tmp, 'state');
    fs.mkdirSync(state, { recursive: true });
    fs.writeFileSync(path.join(state, 'settings.json'), JSON.stringify({ productRoot: tmp, ...(taskDefaults ? { taskDefaults } : {}) }));
    // productRoot is a temp dir without the core: never heal it to this checkout (the test must not depend on where it runs).
    return createEngine({ paths: statePaths(state), runners: createRunnerRegistry([runner]), tickMs: 60_000, detectProductRoot: () => '' });
  }

  test('defaults to Claude Code · Haiku · low effort, scratch under the state dir', async () => {
    const runner = new FakeVisionRunner('claude-code', () => ({ resultText: 'Text' }));
    const engine = engineWith(runner);
    assert.deepEqual(await engine.extractImageText({ imagePath: image }), { text: 'Text', model: 'Haiku' });
    assert.deepEqual(runner.requests[0]!.selection, { runnerID: 'claude-code', model: 'haiku', effort: 'low' });
    assert.ok(runner.requests[0]!.workingDirectory.startsWith(path.join(tmp, 'state')));
  });

  test('follows the Settings choice for Text from images', async () => {
    const runner = new FakeVisionRunner('claude-code', () => ({ resultText: 'Text' }));
    runner.models.push({ id: 'sonnet', label: 'Sonnet' });
    const engine = engineWith(runner, { imageText: { runnerID: 'claude-code', model: 'sonnet', effort: 'medium' } });
    const out = await engine.extractImageText({ imagePath: image });
    assert.equal(out.model, 'Sonnet');
    assert.deepEqual(runner.requests[0]!.selection, { runnerID: 'claude-code', model: 'sonnet', effort: 'medium' });
  });

  test('a missing image is invalid_request and never runs', async () => {
    const runner = new FakeVisionRunner('claude-code', () => ({}));
    const engine = engineWith(runner);
    await assert.rejects(engine.extractImageText({ imagePath: path.join(tmp, 'nope.png') }), (e: { code?: string }) => e.code === 'invalid_request');
    assert.equal(runner.requests.length, 0);
  });
});
