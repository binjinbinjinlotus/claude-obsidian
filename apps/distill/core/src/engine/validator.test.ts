import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import type { AgentRunner, RunnerRegistry, Settings } from '../contracts.js';
import { defaultSettings } from '../store/settings.js';
import { isVault, problem, queuePlacementProblem, setupProblems } from './validator.js';

let root: string;
let vault: string;
let product: string;

before(() => {
  root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-validator-')));
  vault = path.join(root, 'vault');
  fs.mkdirSync(path.join(vault, 'inbox', 'sub'), { recursive: true });
  fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
  product = path.join(root, 'product');
  fs.mkdirSync(path.join(product, 'scripts'), { recursive: true });
  fs.writeFileSync(path.join(product, 'scripts', 'claude-obsidian.py'), '');
});
after(() => fs.rmSync(root, { recursive: true, force: true }));

/** Runners by id; each reports the given problems. */
function registry(ready: Record<string, string[]>): RunnerRegistry & { asked: string[] } {
  const asked: string[] = [];
  const runner = (id: string) =>
    ({ id, problems: () => (asked.push(id), ready[id]!.map((code) => ({ code, message: `${id} ${code}` }))) }) as unknown as AgentRunner;
  return {
    asked,
    all: () => Object.keys(ready).map(runner),
    get: (id) => (id in ready ? runner(id) : undefined),
    candidates: () => [],
  };
}

function settings(over: Partial<Settings> = {}): Settings {
  return { ...defaultSettings(), productRoot: product, vaults: [{ path: vault, queueDirectory: path.join(root, 'queue') }], activeVaultPath: vault, ...over };
}

test('isVault: only a folder with .claude-obsidian.json', () => {
  assert.equal(isVault(vault), true);
  assert.equal(isVault(path.join(vault, 'inbox')), false);
  assert.equal(isVault(path.join(root, 'none')), false);
});

test('queue placement: outside the vault or exactly <vault>/inbox is fine; anything else inside is not', () => {
  assert.equal(queuePlacementProblem(vault, path.join(root, 'queue')), undefined);
  assert.equal(queuePlacementProblem(vault, path.join(root, 'vault-queue')), undefined, 'a sibling whose name starts with the vault name is outside');
  assert.equal(queuePlacementProblem(vault, path.join(vault, 'inbox')), undefined);
  assert.equal(queuePlacementProblem(vault, path.join(vault, 'inbox') + '/'), undefined);
  for (const q of [vault, path.join(vault, 'wiki'), path.join(vault, '.raw'), path.join(vault, 'inbox', 'sub'), path.join(vault, 'wiki', '..', 'wiki')]) {
    assert.deepEqual(queuePlacementProblem(vault, q), problem.queueIsVaultInternal(path.resolve(q)), q);
  }
  // Through a symlink to the vault: still inside.
  const link = path.join(root, 'link');
  fs.symlinkSync(vault, link);
  assert.equal(queuePlacementProblem(vault, path.join(link, 'wiki'))?.code, 'queueIsVaultInternal');
  assert.equal(queuePlacementProblem(vault, path.join(link, 'inbox')), undefined);
});

test('setupProblems: a ready setup has none; each runner some batching task uses is asked once', () => {
  const runners = registry({ 'claude-code': [] });
  assert.deepEqual(setupProblems(settings(), runners), []);
  assert.deepEqual(runners.asked, ['claude-code']);
});

test('setupProblems: no vault, not a vault, a queue inside the vault, a missing core', () => {
  const runners = registry({ 'claude-code': [] });
  assert.deepEqual(setupProblems(settings({ vaults: [], activeVaultPath: undefined, productRoot: path.join(root, 'nope') }), runners), [
    problem.noVault(),
    problem.missingCore(path.join(root, 'nope', 'scripts', 'claude-obsidian.py')),
  ]);
  const plain = path.join(root, 'plain');
  fs.mkdirSync(plain, { recursive: true });
  assert.deepEqual(setupProblems(settings({ vaults: [{ path: plain, queueDirectory: path.join(plain, 'q') }], activeVaultPath: plain }), runners), [
    problem.notAVault(plain),
    problem.queueIsVaultInternal(path.join(plain, 'q')),
  ]);
  // The active vault falls back to the first one when the active path names none.
  assert.deepEqual(setupProblems(settings({ activeVaultPath: '/elsewhere' }), runners), []);
});

test('setupProblems: an unknown runner and a runner\'s own problems block; action and recovery tasks never do', () => {
  const runners = registry({ 'claude-code': ['notInstalled'], codex: [] });
  const s = settings({
    taskDefaults: {
      ingest: { runnerID: 'codex', model: 'm', effort: null },
      labelSuggest: { runnerID: 'ghost', model: 'm', effort: null },
      actionFind: { runnerID: 'gone-1', model: 'm', effort: null },
      actionDraft: { runnerID: 'gone-2', model: 'm', effort: null },
      actionImprove: { runnerID: 'gone-3', model: 'm', effort: null },
      recovery: { runnerID: 'gone-4', model: 'm', effort: null },
    },
  });
  const got = setupProblems(s, runners);
  assert.deepEqual(got.map((p) => p.code), ['notInstalled', 'unknownRunner']);
  assert.deepEqual(got[1], problem.unknownRunner('ghost'));
  assert.deepEqual(runners.asked, ['claude-code', 'codex'], 'in id order, each once');
});

test('the problem messages name the path or the runner', () => {
  assert.match(problem.notAVault('/x').message, /^\/x has no \.claude-obsidian\.json/);
  assert.match(problem.missingCore('/c').message, /\/c\.$/);
  assert.match(problem.queueIsVaultInternal('/q').message, /^Queue directory \/q is inside the vault/);
  assert.match(problem.unknownRunner('r').message, /AI runner r is not available/);
  assert.deepEqual(problem.noVault(), { code: 'noVault', message: 'No vault selected.' });
  assert.equal(problem.notAVault('/x').code, 'notAVault');
  assert.equal(problem.missingCore('/c').code, 'missingCore');
  assert.equal(problem.queueIsVaultInternal('/q').code, 'queueIsVaultInternal');
  assert.equal(problem.unknownRunner('r').code, 'unknownRunner');
});
