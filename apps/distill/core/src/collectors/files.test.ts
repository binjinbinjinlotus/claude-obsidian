/**
 * v6: script files, languages and packages (temp state dirs only).
 *
 * Package installs use a fake `npm` next to the injected Distill Node and a fake `python3` on the login PATH (success, failure,
 * timeout, Stop, masking). One real `npm install` runs offline with a `file:` dependency; real registry and
 * PyPI downloads are not exercised here (they need the network).
 */
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { CoreError, type Collector, type CollectorRun, type CoreEvent, type Settings } from '../contracts.js';
import { consentHash, hasDependencies, packageCount, ScriptFolders, TRASH_KEEP_DAYS } from './files.js';
import { createCollectorsService, type CollectorsOptions, type CollectorsService } from './index.js';
import { npmFor, planInstall, redact, resolveRuntime, typescriptFlags } from './packages.js';
import { findOnPath, sha256Text } from './script.js';

const roots: string[] = [];
after(() => {
  for (const r of roots) fs.rmSync(r, { recursive: true, force: true });
});

const REAL_NODE = findOnPath('node', process.env.PATH ?? '')!;
const REAL_PYTHON = findOnPath('python3', process.env.PATH ?? '');
const REAL_NPM = REAL_NODE ? path.join(path.dirname(REAL_NODE), 'npm') : undefined;

interface Env {
  root: string;
  vault: string;
  queue: string;
  state: string;
  bin: string;
  events: CoreEvent[];
  clock: { now: Date };
  svc: CollectorsService;
  make(extra?: Partial<CollectorsOptions>): CollectorsService;
}

function exe(file: string, body: string): void {
  fs.writeFileSync(file, body, { mode: 0o755 });
}

/** A temp vault, queue and state dir; `bin` comes first on the scripts' PATH (fake npm / python3; node is the real one). */
function setup(extra: Partial<CollectorsOptions> = {}): Env {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-scriptfiles-')));
  roots.push(root);
  const vault = path.join(root, 'vault');
  const queue = path.join(root, 'queue');
  const state = path.join(root, 'state');
  const bin = path.join(root, 'bin');
  for (const d of [vault, queue, state, bin]) fs.mkdirSync(d, { recursive: true });
  fs.symlinkSync(REAL_NODE, path.join(bin, 'node'));
  const settings = { vaults: [{ path: vault, queueDirectory: queue }], activeVaultPath: vault, settleSeconds: 600 } as unknown as Settings;
  const events: CoreEvent[] = [];
  const clock = { now: new Date() };
  const make = (more: Partial<CollectorsOptions> = {}) =>
    createCollectorsService({
      emit: (e) => events.push(e),
      getSettings: () => settings,
      file: path.join(state, 'collectors.json'),
      dir: path.join(state, 'collectors'),
      now: () => clock.now,
      killGraceMs: 300,
      homeDir: root,
      loginPath: async () => `${bin}:${process.env.PATH ?? '/usr/bin:/bin'}`,
      // Distill's Node, seen from `bin`: the npm next to it is the fake (or real) npm a test puts in `bin`.
      nodePath: path.join(bin, 'node'),
      tmpDir: root,
      baseEnv: { HOME: root, PATH: process.env.PATH, DISTILL_STATE_DIR: '/secret/should-not-leak' },
      ...extra,
      ...more,
    });
  return { root, vault, queue, state, bin, events, clock, svc: make(), make };
}

/** A fake npm: behaviour from $HOME/npm-mode (ok | fail | hang), prints a token and URL credentials to check masking. */
function fakeNpm(env: Env, mode: 'ok' | 'fail' | 'hang' = 'ok'): void {
  fs.writeFileSync(path.join(env.root, 'npm-mode'), mode);
  exe(
    path.join(env.bin, 'npm'),
    [
      '#!/bin/zsh',
      'print -r -- "fake npm $*"',
      'print -r -- "//registry.example.com/:_authToken=s3cr3t-token"',
      'print -u2 -r -- "fetch https://bob:hunter2@example.com/pkg.tgz"',
      'print -r -- "$PWD" > "$HOME/npm-cwd"',
      'print -r -- "${DISTILL_STATE_DIR:-unset}" > "$HOME/npm-env"',
      'mode=$(<"$HOME/npm-mode")',
      'if [[ $mode == fail ]]; then print -u2 "npm ERR! 404"; exit 7; fi',
      'if [[ $mode == hang ]]; then sleep 30; fi',
      'mkdir -p node_modules/leftpad && print -r -- "export default (s) => \'  \' + s;" > node_modules/leftpad/index.js',
      'print -r -- \'{"name":"leftpad","type":"module","main":"index.js"}\' > node_modules/leftpad/package.json',
    ].join('\n'),
  );
}

async function runAndWait(svc: CollectorsService, id: string): Promise<CollectorRun> {
  await svc.runCollector(id);
  await svc.whenIdle();
  return (await svc.listCollectorRuns(id))[0]!;
}

async function rejects(p: Promise<unknown>, code: string): Promise<void> {
  await assert.rejects(p, (err: unknown) => err instanceof CoreError && err.code === code);
}

async function allow(env: Env, c: Collector): Promise<Collector> {
  const fresh = (await env.svc.getCollector(c.id))!;
  return env.svc.allowCollector(c.id, fresh.status!.currentSha256!);
}

describe('script files (v6)', () => {
  test('inline code becomes a real file in the collector folder; collectors.json keeps only the reference', async () => {
    const env = setup();
    const code = 'print -r -- "hi" > "$2/hi.md"';
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter: 'zsh' } });
    const file = path.join(env.state, 'collectors', 'scripts', c.id, 'collector.zsh');
    assert.deepEqual(c.script!.source, { file, managed: true });
    assert.equal(fs.readFileSync(file, 'utf8'), code);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);
    const stored = fs.readFileSync(path.join(env.state, 'collectors.json'), 'utf8');
    assert.ok(!stored.includes('hi.md'), 'no code in collectors.json');
    assert.equal(c.status!.currentSha256, sha256Text(code), 'no manifest: the hash is the script’s');
    assert.deepEqual(c.status!.script, { path: file, dir: path.dirname(file), managed: true, manifest: null, lastTestRun: null });
    await allow(env, c);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success');
    assert.deepEqual(run.filesAdded, ['hi.md']);

    // The old app's Edit form sends the managed path back unchanged: it stays managed.
    const same = await env.svc.updateCollector(c.id, { script: { source: { file } } });
    assert.deepEqual(same.script!.source, { file, managed: true });
    assert.equal(same.status!.needsConsent, false);
    // New inline code from the old app goes into the same file.
    const edited = await env.svc.updateCollector(c.id, { script: { source: { inline: `${code}\n# v2` } } });
    assert.deepEqual(edited.script!.source, { file, managed: true });
    assert.equal(fs.readFileSync(file, 'utf8'), `${code}\n# v2`);
    assert.equal(edited.status!.needsConsent, true);
  });

  test('an allowed inline collector from an older build migrates with its consent; a backup is kept', async () => {
    const env = setup();
    const code = 'print -r -- migrated > "$2/m.md"';
    const nodeCode = 'import fs from "node:fs"; fs.writeFileSync(process.argv[3] + "/n.md", "n");';
    const t = '2026-10-01T09:00:00Z';
    const record = (id: string, interpreter: string, inline: string) => ({
      id, kind: 'script', name: id, vaultPath: env.vault, enabled: true, schedule: { cron: '0 * * * *' },
      script: { source: { inline }, interpreter, timeoutSeconds: 60, allowedSha256: sha256Text(inline), allowedAt: t, futureKey: 1 },
      createdAt: t, updatedAt: t,
    });
    const before = JSON.stringify({ version: 1, collectors: [record('col-a', 'zsh', code), record('col-b', 'node', nodeCode)], ticks: {} }, null, 2);
    fs.writeFileSync(path.join(env.state, 'collectors.json'), before);
    const svc = env.make();
    const [a, b] = await svc.listCollectors();
    assert.deepEqual(a!.script!.source, { file: path.join(env.state, 'collectors', 'scripts', 'col-a', 'collector.zsh'), managed: true });
    assert.equal(path.basename((b!.script!.source as { file: string }).file), 'collector.mjs', 'node code keeps the .mjs it always ran as');
    assert.equal(a!.status!.needsConsent, false, 'same bytes, same hash: still allowed');
    assert.equal(b!.status!.needsConsent, false);
    const backups = fs.readdirSync(env.state).filter((n) => n.startsWith('collectors.json.pre-script-files-'));
    assert.equal(backups.length, 1);
    assert.equal(fs.readFileSync(path.join(env.state, backups[0]!), 'utf8'), before);
    const saved = JSON.parse(fs.readFileSync(path.join(env.state, 'collectors.json'), 'utf8'));
    assert.equal(saved.collectors[0].script.futureKey, 1, 'unknown keys survive');
    assert.equal(saved.collectors[0].script.source.inline, undefined);
    assert.equal((await runAndWait(svc, 'col-a')).result, 'success');
    assert.equal((await runAndWait(svc, 'col-b')).result, 'success');
    assert.ok(fs.existsSync(path.join(env.queue, 'm.md')) && fs.existsSync(path.join(env.queue, 'n.md')));
    // Loading again changes nothing and makes no second backup.
    env.make();
    assert.equal(fs.readdirSync(env.state).filter((n) => n.startsWith('collectors.json.pre-script-files-')).length, 1);
  });

  test('a managed path from another state dir is re-pointed at this one', async () => {
    const env = setup();
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'exit 0' }, interpreter: 'zsh' } });
    const file = path.join(env.state, 'collectors.json');
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll(env.state, '/old/state'));
    const again = (await env.make().getCollector(c.id))!;
    assert.equal((again.script!.source as { file: string }).file, path.join(env.state, 'collectors', 'scripts', c.id, 'collector.zsh'));
  });

  test('read and save the script; a version changed on disk is never overwritten; your own file is read-only here', async () => {
    const env = setup();
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'exit 0' }, interpreter: 'zsh' } });
    await allow(env, c);
    const got = await env.svc.getCollectorScript(c.id);
    assert.equal(got.code, 'exit 0');
    assert.equal(got.sha256, sha256Text('exit 0'));
    assert.equal(got.manifest, null, 'zsh has no packages');
    const saved = await env.svc.writeCollectorScript(c.id, { code: 'exit 1', baseSha256: got.sha256! });
    assert.equal(saved.code, 'exit 1');
    assert.equal((await env.svc.getCollector(c.id))!.status!.needsConsent, true, 'a saved change asks again');
    // Edited in another editor since it was loaded:
    fs.writeFileSync(got.path, 'exit 2');
    await rejects(env.svc.writeCollectorScript(c.id, { code: 'exit 3', baseSha256: saved.sha256! }), 'invalid_state');
    assert.equal(fs.readFileSync(got.path, 'utf8'), 'exit 2');
    await rejects(env.svc.writeCollectorScript(c.id, { manifest: '{}' }), 'invalid_request');
    await rejects(env.svc.writeCollectorScript(c.id, { code: '  ' }), 'invalid_request');

    const own = path.join(env.root, 'own.zsh');
    fs.writeFileSync(own, 'exit 0');
    const ext = await env.svc.createCollector({ kind: 'script', script: { source: { file: own }, interpreter: 'zsh' } });
    assert.deepEqual(ext.script!.source, { file: own });
    assert.equal(ext.status!.script!.managed, false);
    assert.equal((await env.svc.getCollectorScript(ext.id)).code, 'exit 0');
    await rejects(env.svc.writeCollectorScript(ext.id, { code: 'exit 1' }), 'invalid_state');
    await rejects(env.svc.installCollectorPackages(ext.id), 'invalid_request');
  });

  test('Duplicate (another collector’s managed path) gets its own copy, manifest included', async () => {
    const env = setup();
    const a = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{"dependencies":{"x":"1"}}' } });
    const aFile = (a.script!.source as { file: string }).file;
    const b = await env.svc.createCollector({ kind: 'script', script: { source: { file: aFile }, interpreter: 'node' } });
    const bFile = (b.script!.source as { file: string }).file;
    assert.equal(bFile, path.join(env.state, 'collectors', 'scripts', b.id, 'collector.js'));
    assert.equal(fs.readFileSync(bFile, 'utf8'), 'console.log(1)');
    assert.equal((await env.svc.getCollectorScript(b.id)).manifest!.text, '{"dependencies":{"x":"1"}}');
    await env.svc.deleteCollector(a.id);
    assert.equal((await env.svc.getCollector(b.id))!.status!.scriptProblem, undefined, 'the copy outlives the original');
  });

  test('changing the language renames the file and asks again', async () => {
    const env = setup();
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node' } });
    const js = (c.script!.source as { file: string }).file;
    assert.equal(path.basename(js), 'collector.js');
    await allow(env, c);
    const ts = await env.svc.updateCollector(c.id, { script: { interpreter: 'typescript' } });
    const tsFile = (ts.script!.source as { file: string }).file;
    assert.equal(path.basename(tsFile), 'collector.ts');
    assert.ok(!fs.existsSync(js) && fs.existsSync(tsFile));
    assert.equal(ts.script!.allowedSha256, null);
    assert.equal(ts.status!.script!.manifest!.name, 'package.json');
  });

  test('TypeScript runs on Node’s type stripping', async (t) => {
    const env = setup();
    const code = [
      'import fs from "node:fs";',
      'interface Note { name: string; body: string }',
      'const note: Note = { name: "typed.md", body: "from TypeScript" };',
      'const queue: string = process.argv[3]!;',
      'fs.writeFileSync(`${queue}/${note.name}`, note.body);',
    ].join('\n');
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter: 'typescript' } });
    await allow(env, c);
    const run = await runAndWait(env.svc, c.id);
    if (run.result === 'failed' && /Node 22\.6/.test(run.error?.message ?? '')) {
      t.skip(`this node can't strip types: ${run.error!.message}`);
      return;
    }
    assert.equal(run.result, 'success', JSON.stringify(run));
    assert.equal(fs.readFileSync(path.join(env.queue, 'typed.md'), 'utf8'), 'from TypeScript');
    assert.equal(run.stderrTail, '', 'no experimental warning in the output');
  });

  test('typescriptFlags: default stripping, the 22.6 flag, or unsupported', () => {
    assert.deepEqual(typescriptFlags({ version: '22.22.1', typescript: 'strip' }), []);
    assert.deepEqual(typescriptFlags({ version: '22.10.0', typescript: null }), ['--experimental-strip-types', '--disable-warning=ExperimentalWarning']);
    assert.deepEqual(typescriptFlags({ version: '23.1.0', typescript: null }), ['--experimental-strip-types', '--disable-warning=ExperimentalWarning']);
    assert.equal(typescriptFlags({ version: '22.5.1', typescript: null }), undefined);
    assert.equal(typescriptFlags({ version: '20.18.0', typescript: null }), undefined);
  });

  test('an old node first on the login PATH: TypeScript and ESM JavaScript run on Distill’s Node, and the run says which', async (t) => {
    // The owner's Mac: `zsh -l` finds /usr/local/bin/node v14 before nvm's 22. A fake old node stands in for it.
    const env = setup({ nodePath: process.execPath });
    fs.rmSync(path.join(env.bin, 'node'));
    exe(path.join(env.bin, 'node'), '#!/bin/sh\necho ran > "$HOME/old-node-ran"\necho v14.16.0\nexit 1\n');
    const want = { label: `Node ${process.versions.node}`, path: process.execPath, version: process.versions.node };

    // ESM JavaScript that also spawns `node` itself: it finds Distill's Node too (its folder is first on PATH).
    const js = await env.svc.createCollector({
      kind: 'script',
      script: {
        source: { inline: 'import fs from "node:fs"; import { execFileSync } from "node:child_process"; fs.writeFileSync(process.argv[3] + "/js.md", execFileSync("node", ["-p", "process.versions.node"]).toString().trim());' },
        interpreter: 'node',
      },
    });
    await allow(env, js);
    const jsRun = await runAndWait(env.svc, js.id);
    assert.equal(jsRun.result, 'success', JSON.stringify(jsRun));
    assert.equal(fs.readFileSync(path.join(env.queue, 'js.md'), 'utf8'), process.versions.node, 'a child `node` is Distill’s Node');
    assert.deepEqual(jsRun.runtime, want);

    const ts = await env.svc.createCollector({
      kind: 'script',
      script: { source: { inline: 'import fs from "node:fs";\nconst n: number = 2;\nfs.writeFileSync(`${process.argv[3]}/ts.md`, String(n));' }, interpreter: 'typescript' },
    });
    await allow(env, ts);
    const tsRun = await runAndWait(env.svc, ts.id);
    if (!typescriptFlags({ version: process.versions.node, typescript: null }) && !(process.features as { typescript?: unknown }).typescript) {
      t.skip(`the test's Node ${process.versions.node} can't strip types`);
      return;
    }
    assert.equal(tsRun.result, 'success', JSON.stringify(tsRun));
    assert.equal(fs.readFileSync(path.join(env.queue, 'ts.md'), 'utf8'), '2');
    assert.deepEqual(tsRun.runtime, want);
    assert.ok(!fs.existsSync(path.join(env.root, 'old-node-ran')), 'the login shell’s old node never ran');

    // The run's details keep the runtime across a restart.
    const reopened = env.make();
    assert.deepEqual((await reopened.listCollectorRuns(ts.id))[0]!.runtime, want);
    await reopened.stop();
  });

  test('resolveRuntime: tsx in the folder runs on Distill’s Node; zsh and python3 still come from the login PATH', async () => {
    const env = setup();
    const folder = path.join(env.root, 'tsx-folder');
    fs.mkdirSync(path.join(folder, 'node_modules', 'tsx', 'dist'), { recursive: true });
    fs.writeFileSync(path.join(folder, 'node_modules', 'tsx', 'dist', 'cli.mjs'), '');
    const node = path.join(env.bin, 'node');
    const viaTsx = await resolveRuntime('typescript', folder, '/nowhere', {}, node);
    assert.ok(!('error' in viaTsx));
    assert.equal(viaTsx.command, node);
    assert.deepEqual(viaTsx.args, [path.join(folder, 'node_modules', 'tsx', 'dist', 'cli.mjs')]);
    assert.equal(viaTsx.runtime.label, `Node ${process.versions.node} with tsx`);
    const zsh = await resolveRuntime('zsh', null, '/bin', {}, node);
    assert.deepEqual(zsh, { command: '/bin/zsh', args: [], runtime: { label: 'zsh', path: '/bin/zsh' } });
    const gone = await resolveRuntime('node', null, '/bin', {}, path.join(env.root, 'no-node'));
    assert.ok('error' in gone && /Distill's Node/.test(gone.error));
  });

  test('npmFor: npm-cli.js next to Distill’s Node runs with that Node, never through its shebang', () => {
    const env = setup();
    // Layout of an nvm / official install: bin/node, bin/npm → ../lib/node_modules/npm/bin/npm-cli.js
    const rt = path.join(env.root, 'rt');
    const cli = path.join(rt, 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js');
    fs.mkdirSync(path.dirname(cli), { recursive: true });
    fs.mkdirSync(path.join(rt, 'bin'));
    fs.writeFileSync(cli, '#!/usr/bin/env node\n');
    fs.symlinkSync(process.execPath, path.join(rt, 'bin', 'node'));
    fs.symlinkSync('../lib/node_modules/npm/bin/npm-cli.js', path.join(rt, 'bin', 'npm'));
    assert.deepEqual(npmFor(path.join(rt, 'bin', 'node')), { command: path.join(rt, 'bin', 'node'), args: [cli] });
    // bin/npm linking to a .js elsewhere (no lib/ beside bin/).
    const other = path.join(env.root, 'other');
    fs.mkdirSync(path.join(other, 'bin'), { recursive: true });
    fs.symlinkSync(process.execPath, path.join(other, 'bin', 'node'));
    fs.symlinkSync(cli, path.join(other, 'bin', 'npm'));
    assert.deepEqual(npmFor(path.join(other, 'bin', 'node')), { command: path.join(other, 'bin', 'node'), args: [fs.realpathSync(cli)] });
    // A plain executable npm (the fakes here): run as is. None at all: undefined.
    fakeNpm(env);
    assert.deepEqual(npmFor(path.join(env.bin, 'node')), { command: path.join(env.bin, 'npm'), args: [] });
    assert.equal(npmFor(path.join(env.root, 'nowhere', 'node')), undefined);
    const plan = planInstall('package.json', env.root, '/nowhere', path.join(rt, 'bin', 'node'));
    assert.ok(!('error' in plan));
    assert.deepEqual(plan.steps, [{ command: path.join(rt, 'bin', 'node'), args: [cli, 'install', '--no-audit', '--no-fund'], label: 'npm install --no-audit --no-fund' }]);
  });

  test('npm rewriting package.json (npm 6) never changes what was allowed: same bytes, ready, consent unchanged', async () => {
    const env = setup();
    const manifest = '{"name":"x","type":"module","dependencies":{"leftpad":"^1.0.0"}}';
    // npm 6 style: reorders keys, reindents, adds a trailing newline; then installs (or fails, from $HOME/npm-mode).
    fs.writeFileSync(path.join(env.root, 'npm-mode'), 'ok');
    exe(
      path.join(env.bin, 'npm'),
      [
        '#!/bin/zsh',
        'print -r -- "$*" > "$HOME/npm-args"',
        'print -r -- \'{\n  "dependencies": {\n    "leftpad": "^1.0.0"\n  },\n  "name": "x",\n  "type": "module"\n}\' > package.json',
        'mkdir -p node_modules/leftpad && print -r -- "export default (s) => \'  \' + s;" > node_modules/leftpad/index.js',
        'print -r -- \'{"name":"leftpad","type":"module","main":"index.js"}\' > node_modules/leftpad/package.json',
        '[[ $(<"$HOME/npm-mode") == fail ]] && exit 1',
        'exit 0',
      ].join('\n'),
    );
    const c = await env.svc.createCollector({
      kind: 'script',
      script: { source: { inline: 'import pad from "leftpad"; import fs from "node:fs"; fs.writeFileSync(process.argv[3] + "/p.md", pad("y"));' }, interpreter: 'node', manifest },
    });
    const file = path.join(env.state, 'collectors', 'scripts', c.id, 'package.json');
    const before = fs.readFileSync(file);
    const modeBefore = fs.statSync(file).mode & 0o777;
    const allowed = await allow(env, c);
    await env.svc.whenIdle();
    const done = (await env.svc.getCollectorInstall(c.id))!;
    assert.equal(done.result, 'success', JSON.stringify(done));
    assert.match(done.outputTail!, /^\$ npm install --no-audit --no-fund\n/, 'the banner names npm, not node + npm-cli.js');
    assert.deepEqual(done.runtime, { label: `Node ${process.versions.node}`, path: path.join(env.bin, 'node'), version: process.versions.node });
    assert.ok(fs.readFileSync(file).equals(before), 'package.json is byte for byte what was allowed');
    assert.equal(fs.statSync(file).mode & 0o777, modeBefore);
    const status = (await env.svc.getCollector(c.id))!.status!;
    assert.equal(status.script!.manifest!.state, 'ready');
    assert.equal(status.script!.manifest!.needsInstall, false);
    assert.equal(status.currentSha256, allowed.script!.allowedSha256, 'the consent hash didn’t move');
    assert.equal(status.needsConsent, false);
    assert.equal(status.script!.changes, undefined);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success', JSON.stringify(run));
    assert.equal(run.installId, undefined, 'no second install');

    // A failing install that rewrote package.json first is put back too.
    fs.writeFileSync(path.join(env.root, 'npm-mode'), 'fail');
    await env.svc.installCollectorPackages(c.id, { clean: true });
    await env.svc.whenIdle();
    assert.equal((await env.svc.getCollectorInstall(c.id))!.result, 'failed');
    assert.ok(fs.readFileSync(file).equals(before));
    assert.equal((await env.svc.getCollector(c.id))!.status!.currentSha256, allowed.script!.allowedSha256);
  });

  test('the manifest is part of consent; without one the hash is the script’s own', async () => {
    const env = setup();
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node' } });
    await allow(env, c);
    const files = await env.svc.getCollectorScript(c.id);
    assert.deepEqual(files.manifest, { name: 'package.json', path: path.join(path.dirname(files.path), 'package.json'), text: null, sha256: null });
    const manifest = '{"name":"pull","type":"module","dependencies":{"leftpad":"^1.0.0"}}';
    await env.svc.writeCollectorScript(c.id, { manifest, baseManifestSha256: null });
    const after = (await env.svc.getCollector(c.id))!;
    assert.equal(after.status!.needsConsent, true, 'a new package list needs the user’s OK');
    assert.equal(after.status!.currentSha256, consentHash(Buffer.from('console.log(1)'), { name: 'package.json', bytes: Buffer.from(manifest) }));
    const m = after.status!.script!.manifest!;
    assert.deepEqual(after.status!.script!.changes, ['manifest'], 'the consent card can name what changed');
    assert.equal(m.packageCount, 1);
    assert.equal(m.exists, true);
    assert.equal(m.hasDependencies, true);
    assert.equal(m.needsInstall, true);
    assert.equal(m.lastInstall, null);
    await rejects(env.svc.installCollectorPackages(c.id), 'invalid_state');
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'notTrusted', 'nothing installs or runs before the OK');
    // Removing the manifest gives back the script-only hash (the old allowance fits again).
    await env.svc.writeCollectorScript(c.id, { manifest: null });
    assert.equal((await env.svc.getCollector(c.id))!.status!.needsConsent, false);
  });

  test('allowing a script with packages installs them at once: npm in the folder, output masked, consent unchanged', async () => {
    const env = setup();
    fakeNpm(env);
    const code = 'import pad from "leftpad"; import fs from "node:fs"; fs.writeFileSync(process.argv[3] + "/p.md", pad("x"));';
    const manifest = '{"type":"module","dependencies":{"leftpad":"^1.0.0"}}\n';
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter: 'node', manifest } });
    assert.equal(c.status!.script!.manifest!.state, 'needsInstall');
    const allowed = await allow(env, c);
    assert.equal(allowed.status!.script!.manifest!.state, 'installing', 'adding = allow → installing, before any run');
    assert.equal(allowed.status!.script!.manifest!.installing, true);
    await rejects(env.svc.installCollectorPackages(c.id), 'busy');
    await env.svc.whenIdle();
    const done = (await env.svc.getCollectorInstall(c.id))!;
    assert.equal(done.result, 'success', JSON.stringify(done));
    assert.equal(done.trigger, 'allow');
    assert.equal(done.command, 'npm install --no-audit --no-fund');
    assert.equal(fs.readFileSync(path.join(env.root, 'npm-cwd'), 'utf8').trim(), path.join(env.state, 'collectors', 'scripts', c.id));
    assert.equal(fs.readFileSync(path.join(env.root, 'npm-env'), 'utf8').trim(), 'unset', 'no DISTILL_* variables');
    assert.match(done.outputTail!, /fake npm install --no-audit --no-fund/);
    assert.ok(!done.outputTail!.includes('s3cr3t-token') && !done.outputTail!.includes('hunter2'), done.outputTail);
    assert.match(done.outputTail!, /_authToken=\*\*\*/);
    const outputs = env.events.filter((e) => e.type === 'collector.install.output').map((e) => (e as { text: string }).text).join('');
    assert.ok(!outputs.includes('hunter2'), 'live output is masked too');
    const after = (await env.svc.getCollector(c.id))!;
    assert.equal(after.status!.currentSha256, allowed.script!.allowedSha256, 'installing never changes what consent covers');
    assert.equal(after.status!.script!.manifest!.state, 'ready');
    assert.equal(after.status!.script!.manifest!.lastInstall!.outputTail, undefined, 'status leaves the output out');
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success', JSON.stringify(run));
    assert.equal(run.installId, undefined, 'nothing to install first');
    assert.equal(fs.readFileSync(path.join(env.queue, 'p.md'), 'utf8'), '  x');
  });

  test('Allow and run: Run now during the install waits for it, then runs', async () => {
    const env = setup();
    fakeNpm(env);
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'import "leftpad"; console.log("ran")' }, interpreter: 'node', manifest: '{"dependencies":{"leftpad":"1"}}' } });
    await allow(env, c);
    const queued = await env.svc.runCollector(c.id);
    assert.equal(queued.result, 'queued');
    assert.equal(queued.waiting, 'install');
    await env.svc.whenIdle();
    const run = (await env.svc.listCollectorRuns(c.id))[0]!;
    assert.equal(run.result, 'nothing', JSON.stringify(run));
    assert.match(run.stdoutTail!, /ran/);
    assert.equal(run.installId, undefined, 'the run itself installed nothing');
  });

  test('a failed install shows as failed and is not retried by every run; missing packages reinstall before a run', async () => {
    const env = setup();
    fakeNpm(env, 'fail');
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'import "leftpad"; console.log("ran")' }, interpreter: 'node', manifest: '{"dependencies":{"leftpad":"2"}}' } });
    await allow(env, c);
    await env.svc.whenIdle();
    const failedInstall = (await env.svc.getCollectorInstall(c.id))!;
    assert.equal(failedInstall.result, 'failed');
    let status = (await env.svc.getCollector(c.id))!.status!;
    assert.equal(status.script!.manifest!.state, 'failed');
    assert.equal(status.needsAttention, true);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'failed');
    assert.equal(run.error!.code, 'installFailed');
    assert.equal(run.installId, failedInstall.id, 'no second install attempt');
    // Install again (explicit) works once npm does.
    fakeNpm(env, 'ok');
    await env.svc.installCollectorPackages(c.id);
    await env.svc.whenIdle();
    status = (await env.svc.getCollector(c.id))!.status!;
    assert.equal(status.script!.manifest!.state, 'ready');
    // Safety net: node_modules deleted by hand → the next run installs first.
    fs.rmSync(path.join(env.state, 'collectors', 'scripts', c.id, 'node_modules'), { recursive: true });
    const again = await runAndWait(env.svc, c.id);
    assert.equal(again.result, 'nothing', JSON.stringify(again));
    assert.ok(again.installId);
    assert.equal((await env.svc.getCollectorInstall(c.id))!.trigger, 'beforeRun');
  });

  test('allowing a changed manifest installs at once', async () => {
    const env = setup();
    fakeNpm(env);
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{"dependencies":{"a":"1"}}' } });
    await allow(env, c);
    await env.svc.whenIdle();
    const first = (await env.svc.getCollectorInstall(c.id))!;
    await env.svc.writeCollectorScript(c.id, { manifest: '{"dependencies":{"a":"2"}}' });
    assert.equal((await env.svc.getCollector(c.id))!.status!.script!.manifest!.state, 'needsInstall');
    const again = await allow(env, c);
    assert.equal(again.status!.script!.manifest!.state, 'installing');
    await env.svc.whenIdle();
    const second = (await env.svc.getCollectorInstall(c.id))!;
    assert.notEqual(second.id, first.id);
    assert.equal(second.trigger, 'allow');
    assert.equal(second.result, 'success');
  });

  test('install timeout, Stop and clean reinstall', async () => {
    const env = setup({ installTimeoutMs: 500 });
    fakeNpm(env, 'hang');
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{"dependencies":{"a":"1"}}' } });
    await allow(env, c);
    await env.svc.whenIdle();
    assert.equal((await env.svc.getCollectorInstall(c.id))!.result, 'timedout');

    const env2 = setup();
    fakeNpm(env2, 'hang');
    const d = await env2.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{"dependencies":{"a":"1"}}' } });
    await allow(env2, d);
    await new Promise((r) => setTimeout(r, 200));
    assert.equal((await env2.svc.stopCollectorInstall(d.id))!.result, 'running');
    await env2.svc.whenIdle();
    assert.equal((await env2.svc.getCollectorInstall(d.id))!.result, 'stopped');
    assert.equal(await env2.svc.stopCollectorInstall(d.id), null);

    fakeNpm(env2, 'ok');
    const stale = path.join(env2.state, 'collectors', 'scripts', d.id, 'node_modules', 'stale');
    fs.mkdirSync(stale, { recursive: true });
    await env2.svc.installCollectorPackages(d.id, { clean: true });
    await env2.svc.whenIdle();
    const clean = (await env2.svc.getCollectorInstall(d.id))!;
    assert.equal(clean.result, 'success');
    assert.equal(clean.clean, true);
    assert.equal(clean.trigger, 'manual');
    assert.ok(!fs.existsSync(stale), 'clean removed node_modules first');
  });

  test('Python: requirements.txt installs into a .venv in the folder, and runs use it', async () => {
    const env = setup();
    // A fake python3: `-m venv --symlinks .venv` makes a venv whose python3 marks that it ran, then runs the real python3.
    exe(
      path.join(env.bin, 'python3'),
      [
        '#!/bin/zsh',
        'if [[ "$1 $2 $3" == "-m venv --symlinks" ]]; then',
        '  mkdir -p "$4/bin"',
        `  print -r -- '#!/bin/zsh' > "$4/bin/python3"`,
        `  print -r -- 'if [[ "$1 $2" == "-m pip" ]]; then print -r -- "pip $*"; exit 0; fi' >> "$4/bin/python3"`,
        `  print -r -- 'print venv > "$HOME/venv-used"; exec ${REAL_PYTHON ?? '/usr/bin/python3'} "$@"' >> "$4/bin/python3"`,
        '  chmod +x "$4/bin/python3"; print "created venv"; exit 0',
        'fi',
        'print -u2 "unexpected: $*"; exit 9',
      ].join('\n'),
    );
    const code = 'import sys, pathlib\npathlib.Path(sys.argv[2], "py.md").write_text("py")\n';
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter: 'python3', manifest: '# packages\nrequests==2.32.3\n' } });
    assert.equal(path.basename((c.script!.source as { file: string }).file), 'collector.py');
    assert.equal(c.status!.script!.manifest!.name, 'requirements.txt');
    await allow(env, c);
    await env.svc.whenIdle();
    const inst = (await env.svc.getCollectorInstall(c.id))!;
    assert.equal(inst.result, 'success', JSON.stringify(inst));
    assert.equal(inst.command, 'python3 -m venv --symlinks .venv && .venv/bin/python3 -m pip install --disable-pip-version-check -r requirements.txt');
    assert.match(inst.outputTail!, /created venv[\s\S]*pip -m pip install/);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success', JSON.stringify(run));
    assert.ok(fs.existsSync(path.join(env.root, 'venv-used')), 'the run used the folder’s .venv');
    // With the venv in place, the next install reuses it (no venv step).
    const plan = planInstall('requirements.txt', path.join(env.state, 'collectors', 'scripts', c.id), `${env.bin}:${process.env.PATH}`);
    assert.ok(!('error' in plan) && plan.steps.length === 1);
  });

  test('a real venv: its python resolves to the base python3; restarts, re-points and manifest changes keep the same .venv', async (t) => {
    if (!REAL_PYTHON) {
      t.skip('no python3 on PATH');
      return;
    }
    const env = setup();
    fs.symlinkSync(REAL_PYTHON, path.join(env.bin, 'python3'));
    // Offline: pip is already in a new venv, so "pip" with --no-index is satisfied without the network.
    const c = await env.svc.createCollector({
      kind: 'script',
      script: { source: { inline: 'import sys, pathlib\npathlib.Path(sys.argv[2], "v.md").write_text(sys.executable)\n' }, interpreter: 'python3', manifest: '--no-index\npip\n' },
    });
    await allow(env, c);
    await env.svc.whenIdle();
    const inst = (await env.svc.getCollectorInstall(c.id))!;
    assert.equal(inst.result, 'success', inst.outputTail);
    const dir = path.join(env.state, 'collectors', 'scripts', c.id);
    const venvPython = path.join(dir, '.venv', 'bin', 'python3');
    assert.ok(fs.lstatSync(venvPython).isSymbolicLink(), 'symlinks, never copies');
    const base = (await import('node:child_process')).execFileSync(REAL_PYTHON, ['-c', 'import os, sys; print(os.path.realpath(sys.executable))']).toString().trim();
    assert.equal(fs.realpathSync(venvPython), base, 'the Keychain sees the same program');
    const fingerprint = () => {
      const cfg = fs.statSync(path.join(dir, '.venv', 'pyvenv.cfg'));
      const py = fs.lstatSync(venvPython);
      return `${cfg.ino}:${cfg.mtimeMs}:${py.ino}:${py.mtimeMs}`;
    };
    const before = fingerprint();
    // A core restart (with migration and a state-dir re-point) leaves the venv alone.
    const file = path.join(env.state, 'collectors.json');
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replaceAll(env.state, '/old/state'));
    const svc2 = env.make();
    svc2.start();
    await svc2.stop();
    assert.equal(fingerprint(), before);
    // A manifest change installs into the same venv.
    await svc2.writeCollectorScript(c.id, { manifest: '--no-index\npip  # still offline\n' });
    const fresh = (await svc2.getCollector(c.id))!;
    await svc2.allowCollector(c.id, fresh.status!.currentSha256!);
    await svc2.whenIdle();
    const second = (await svc2.getCollectorInstall(c.id))!;
    assert.equal(second.result, 'success', second.outputTail);
    assert.ok(!second.command.includes('venv --symlinks'), 'no new venv');
    assert.equal(fingerprint(), before);
  });

  test('a real npm install, offline, with a file: dependency', async (t) => {
    if (!REAL_NPM || !fs.existsSync(REAL_NPM)) {
      t.skip('npm is not next to this node');
      return;
    }
    const env = setup();
    fs.symlinkSync(REAL_NPM, path.join(env.bin, 'npm'));
    const c = await env.svc.createCollector({
      kind: 'script',
      script: {
        source: { inline: 'import greet from "greet"; import fs from "node:fs"; fs.writeFileSync(process.argv[3] + "/g.md", greet());' },
        interpreter: 'node',
        manifest: '{"name":"g","private":true,"type":"module","dependencies":{"greet":"file:./greet"}}',
      },
    });
    const dir = path.join(env.state, 'collectors', 'scripts', c.id);
    fs.mkdirSync(path.join(dir, 'greet'));
    fs.writeFileSync(path.join(dir, 'greet', 'package.json'), '{"name":"greet","version":"1.0.0","type":"module","main":"index.js"}');
    fs.writeFileSync(path.join(dir, 'greet', 'index.js'), 'export default () => "hello";');
    const manifestBefore = fs.readFileSync(path.join(dir, 'package.json'));
    await allow(env, c);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success', JSON.stringify({ run, install: await env.svc.getCollectorInstall(c.id) }));
    assert.equal(fs.readFileSync(path.join(env.queue, 'g.md'), 'utf8'), 'hello');
    assert.ok(fs.readFileSync(path.join(dir, 'package.json')).equals(manifestBefore), 'npm left package.json as it was');
    assert.equal((await env.svc.getCollector(c.id))!.status!.needsConsent, false);
  });

  test('delete: the folder is removed only when Distill’s trash keeps it; restore puts a copy back; the old collectors/trash is pruned', async () => {
    const env = setup();
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{}' } });
    const dir = path.join(env.state, 'collectors', 'scripts', c.id);
    await env.svc.deleteCollector(c.id);
    assert.ok(fs.existsSync(dir), 'on its own the service never destroys a script');

    const kept = env.make({ trashKeepsScriptFolders: true });
    const d = await kept.createCollector({ kind: 'script', script: { source: { inline: 'console.log(2)' }, interpreter: 'node' } });
    const ddir = path.join(env.state, 'collectors', 'scripts', d.id);
    const copy = path.join(env.root, 'trash-copy');
    fs.cpSync(ddir, copy, { recursive: true });
    const { status: _s, ...record } = (await kept.getCollector(d.id))!;
    await kept.deleteCollector(d.id);
    assert.ok(!fs.existsSync(ddir));
    const back = await kept.restoreCollector(record, copy);
    assert.equal(back.id, d.id);
    assert.equal(fs.readFileSync((back.script!.source as { file: string }).file, 'utf8'), 'console.log(2)');
    assert.equal(back.status!.needsConsent, true);

    // An earlier v6 build moved folders to collectors/trash: a restore still finds them, and they go after 30 days.
    const legacy = path.join(env.state, 'collectors', 'trash', `${c.id}-20261004-090000`);
    fs.mkdirSync(path.dirname(legacy), { recursive: true });
    fs.renameSync(dir, legacy);
    const { status: _t, ...cRecord } = c;
    const restored = await kept.restoreCollector(cRecord);
    assert.equal(fs.readFileSync((restored.script!.source as { file: string }).file, 'utf8'), 'console.log(1)');
    const folders = new ScriptFolders(path.join(env.state, 'collectors'));
    assert.deepEqual(folders.pruneTrash(new Date()), []);
    const old = new Date(Date.now() - (TRASH_KEEP_DAYS + 1) * 24 * 3600 * 1000);
    fs.utimesSync(legacy, old, old);
    assert.equal(folders.pruneTrash(new Date()).length, 1);
  });

  test('restoring a record from before script files writes its code to a file', async () => {
    const env = setup();
    const t = '2026-10-01T09:00:00Z';
    const back = await env.svc.restoreCollector({ id: 'col-old', kind: 'script', name: 'Old', vaultPath: env.vault, enabled: true, schedule: { cron: '0 * * * *' }, script: { source: { inline: 'exit 0' }, interpreter: 'zsh', timeoutSeconds: 60, allowedSha256: 'x' }, createdAt: t, updatedAt: t });
    assert.deepEqual(back.script!.source, { file: path.join(env.state, 'collectors', 'scripts', 'col-old', 'collector.zsh'), managed: true });
    assert.equal(back.enabled, false);
    assert.equal(back.script!.allowedSha256, undefined);
  });

  test('Test run: like a real run, into a scratch folder; never the queue, lastRun or the sidebar count', async () => {
    const env = setup();
    const code = 'print -r -- "$DISTILL_QUEUE_DIR" > "$2/where.txt"; print -r -- "$DISTILL_RUN_TRIGGER" > "$2/trigger.txt"; print -r -- one > "$2/a.md"; [[ -f "$2/old.md" ]] && print stale; exit ${FAIL:-0}';
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter: 'zsh' } });
    await env.svc.testCollector(c.id);
    await env.svc.whenIdle();
    const refused = (await env.svc.listCollectorRuns(c.id))[0]!;
    assert.equal(refused.trigger, 'test');
    assert.equal(refused.result, 'notTrusted', 'same consent as a real run');
    await allow(env, c);
    const scratch = path.join(env.state, 'collectors', 'test-runs', c.id);
    fs.mkdirSync(scratch, { recursive: true });
    fs.writeFileSync(path.join(scratch, 'old.md'), 'from the last test run');
    await env.svc.testCollector(c.id);
    await env.svc.whenIdle();
    const run = (await env.svc.listCollectorRuns(c.id))[0]!;
    assert.equal(run.result, 'success', JSON.stringify(run));
    assert.equal(run.outputDir, scratch);
    assert.deepEqual(run.filesAdded, ['a.md', 'trigger.txt', 'where.txt']);
    assert.equal(fs.readFileSync(path.join(scratch, 'trigger.txt'), 'utf8').trim(), 'test', 'DISTILL_RUN_TRIGGER tells the script it is a Test run');
    assert.equal(fs.readFileSync(path.join(scratch, 'where.txt'), 'utf8').trim(), scratch, '$2 and DISTILL_QUEUE_DIR are the scratch folder');
    assert.ok(!run.stdoutTail!.includes('stale'), 'the previous test output was cleared first');
    assert.deepEqual(fs.readdirSync(env.queue), [], 'nothing reached the queue');
    const status = (await env.svc.getCollector(c.id))!.status!;
    assert.notEqual(status.lastRun?.trigger, 'test', 'lastRun is the real runs only');
    assert.equal(status.script!.lastTestRun!.id, run.id);
    assert.equal(status.script!.lastTestRun!.outputDir, scratch);
    assert.equal(status.needsAttention, false, 'a refused test run raises no count');
  });

  test('Test run is for scripts; deleting removes its output', async () => {
    const env = setup();
    const f = await env.svc.createCollector({ kind: 'folder', folder: { source: path.join(env.root, 'in') } });
    await rejects(env.svc.testCollector(f.id), 'invalid_request');
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'print x > "$2/x.md"; exit 3' }, interpreter: 'zsh' } });
    await allow(env, c);
    await env.svc.testCollector(c.id);
    await env.svc.whenIdle();
    const status = (await env.svc.getCollector(c.id))!.status!;
    assert.equal(status.script!.lastTestRun!.result, 'failed');
    assert.equal(status.needsAttention, false, 'a failed test run raises no count');
    assert.equal(status.lastRun, null);
    await env.svc.deleteCollector(c.id);
    assert.ok(!fs.existsSync(path.join(env.state, 'collectors', 'test-runs', c.id)));
  });

  test('ids never leave the scripts folder', () => {
    const folders = new ScriptFolders('/state/collectors');
    assert.equal(folders.folder('../../etc'), '/state/collectors/scripts/______etc');
    assert.equal(folders.folder('..'), '/state/collectors/scripts/__');
  });

  test('hasDependencies and redact', () => {
    assert.equal(hasDependencies('package.json', Buffer.from('{"name":"x"}')), false);
    assert.equal(hasDependencies('package.json', Buffer.from('{"devDependencies":{"tsx":"^4"}}')), true);
    assert.equal(hasDependencies('package.json', Buffer.from('{not json')), true);
    assert.equal(hasDependencies('requirements.txt', Buffer.from('# none\n\n  # still none\n')), false);
    assert.equal(hasDependencies('requirements.txt', Buffer.from('keyring  # for the Keychain\n')), true);
    assert.equal(packageCount('requirements.txt', Buffer.from('--index-url https://x\nkeyring\ngoogle-auth>=2\n')), 2);
    assert.equal(packageCount('package.json', Buffer.from('{"dependencies":{"a":"1"},"devDependencies":{"tsx":"4"}}')), 2);
    assert.equal(redact('https://u:p@h/x token=abc password: "pw" //r/:_authToken=t'), 'https://***@h/x token=*** password: "***" //r/:_authToken=***');
  });
});
