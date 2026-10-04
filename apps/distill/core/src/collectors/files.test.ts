/**
 * v6: script files, languages and packages (temp state dirs only).
 *
 * Package installs use fake `npm` and `python3` executables on the injected login PATH (success, failure,
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
import { planInstall, redact, typescriptFlags } from './packages.js';
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
    assert.deepEqual(c.status!.script, { path: file, dir: path.dirname(file), managed: true, manifest: null });
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

  test('Install: npm in the script folder, output captured and masked, consent unchanged afterwards', async () => {
    const env = setup();
    fakeNpm(env);
    const code = 'import pad from "leftpad"; import fs from "node:fs"; fs.writeFileSync(process.argv[3] + "/p.md", pad("x"));';
    const manifest = '{"type":"module","dependencies":{"leftpad":"^1.0.0"}}\n';
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter: 'node', manifest } });
    const allowed = await allow(env, c);
    const started = await env.svc.installCollectorPackages(c.id);
    assert.equal(started.result, 'running');
    assert.equal(started.command, 'npm install --no-audit --no-fund');
    await rejects(env.svc.runCollector(c.id), 'busy');
    await rejects(env.svc.installCollectorPackages(c.id), 'busy');
    await env.svc.whenIdle();
    const done = (await env.svc.getCollectorInstall(c.id))!;
    assert.equal(done.result, 'success', JSON.stringify(done));
    assert.equal(fs.readFileSync(path.join(env.root, 'npm-cwd'), 'utf8').trim(), path.join(env.state, 'collectors', 'scripts', c.id));
    assert.equal(fs.readFileSync(path.join(env.root, 'npm-env'), 'utf8').trim(), 'unset', 'no DISTILL_* variables');
    assert.match(done.outputTail!, /fake npm install --no-audit --no-fund/);
    assert.ok(!done.outputTail!.includes('s3cr3t-token') && !done.outputTail!.includes('hunter2'), done.outputTail);
    assert.match(done.outputTail!, /_authToken=\*\*\*/);
    const outputs = env.events.filter((e) => e.type === 'collector.install.output').map((e) => (e as { text: string }).text).join('');
    assert.ok(!outputs.includes('hunter2'), 'live output is masked too');
    assert.ok(env.events.some((e) => e.type === 'collector.install.finished'));
    const after = (await env.svc.getCollector(c.id))!;
    assert.equal(after.status!.currentSha256, allowed.script!.allowedSha256, 'installing never changes what consent covers');
    assert.equal(after.status!.script!.manifest!.needsInstall, false);
    assert.equal(after.status!.script!.manifest!.lastInstall!.outputTail, undefined, 'status leaves the output out');
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success', JSON.stringify(run));
    assert.equal(run.installId, undefined, 'nothing to install first');
    assert.equal(fs.readFileSync(path.join(env.queue, 'p.md'), 'utf8'), '  x');
  });

  test('a changed manifest installs before the next run; a failed install fails the run', async () => {
    const env = setup();
    fakeNpm(env);
    const c = await env.svc.createCollector({
      kind: 'script',
      script: { source: { inline: 'import "leftpad"; console.log("ran")' }, interpreter: 'node', manifest: '{"dependencies":{"leftpad":"1"}}' },
    });
    await allow(env, c);
    const first = await runAndWait(env.svc, c.id);
    assert.equal(first.result, 'nothing', JSON.stringify(first));
    assert.ok(first.installId, 'the run installed first');
    assert.equal((await env.svc.getCollectorInstall(c.id))!.trigger, 'beforeRun');
    assert.match(first.stdoutTail!, /ran/);

    await env.svc.writeCollectorScript(c.id, { manifest: '{"dependencies":{"leftpad":"2"}}' });
    await allow(env, c);
    fakeNpm(env, 'fail');
    const second = await runAndWait(env.svc, c.id);
    assert.equal(second.result, 'failed');
    assert.equal(second.error!.code, 'installFailed');
    const status = (await env.svc.getCollector(c.id))!.status!;
    assert.equal(status.needsAttention, true);
    assert.equal(status.script!.manifest!.needsInstall, true);
    assert.equal(status.script!.manifest!.lastInstall!.result, 'failed');
  });

  test('install timeout, Stop and clean reinstall', async () => {
    const env = setup({ installTimeoutMs: 500 });
    fakeNpm(env, 'hang');
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{"dependencies":{"a":"1"}}' } });
    await allow(env, c);
    await env.svc.installCollectorPackages(c.id);
    await env.svc.whenIdle();
    assert.equal((await env.svc.getCollectorInstall(c.id))!.result, 'timedout');

    const env2 = setup();
    fakeNpm(env2, 'hang');
    const d = await env2.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{"dependencies":{"a":"1"}}' } });
    await allow(env2, d);
    await env2.svc.installCollectorPackages(d.id);
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
    assert.ok(!fs.existsSync(stale), 'clean removed node_modules first');
  });

  test('Python: requirements.txt installs into a .venv in the folder, and runs use it', async () => {
    const env = setup();
    // A fake python3: `-m venv .venv` makes a venv whose python3 marks that it ran, then runs the real python3.
    exe(
      path.join(env.bin, 'python3'),
      [
        '#!/bin/zsh',
        'if [[ "$1 $2" == "-m venv" ]]; then',
        '  mkdir -p "$3/bin"',
        `  print -r -- '#!/bin/zsh' > "$3/bin/python3"`,
        `  print -r -- 'if [[ "$1 $2" == "-m pip" ]]; then print -r -- "pip $*"; exit 0; fi' >> "$3/bin/python3"`,
        `  print -r -- 'print venv > "$HOME/venv-used"; exec ${REAL_PYTHON ?? '/usr/bin/python3'} "$@"' >> "$3/bin/python3"`,
        '  chmod +x "$3/bin/python3"; print "created venv"; exit 0',
        'fi',
        `exec ${REAL_PYTHON ?? '/usr/bin/python3'} "$@"`,
      ].join('\n'),
    );
    const code = 'import sys, pathlib\npathlib.Path(sys.argv[2], "py.md").write_text("py")\n';
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: code }, interpreter: 'python3', manifest: '# packages\nrequests==2.32.3\n' } });
    assert.equal(path.basename((c.script!.source as { file: string }).file), 'collector.py');
    assert.equal(c.status!.script!.manifest!.name, 'requirements.txt');
    await allow(env, c);
    await env.svc.installCollectorPackages(c.id);
    await env.svc.whenIdle();
    const inst = (await env.svc.getCollectorInstall(c.id))!;
    assert.equal(inst.result, 'success', JSON.stringify(inst));
    assert.match(inst.command, /^python3 -m venv \.venv && \.venv\/bin\/python3 -m pip install --disable-pip-version-check -r requirements\.txt$/);
    assert.match(inst.outputTail!, /created venv[\s\S]*pip -m pip install/);
    const run = await runAndWait(env.svc, c.id);
    assert.equal(run.result, 'success', JSON.stringify(run));
    assert.ok(fs.existsSync(path.join(env.root, 'venv-used')), 'the run used the folder’s .venv');
    // With the venv in place, the next install skips creating it.
    const plan = planInstall('requirements.txt', path.join(env.state, 'collectors', 'scripts', c.id), `${env.bin}:${process.env.PATH}`);
    assert.ok(!('error' in plan) && plan.steps.length === 1);
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

  test('deleting moves the folder to the trash without installed packages; the trash keeps 30 days', async () => {
    const env = setup();
    const c = await env.svc.createCollector({ kind: 'script', script: { source: { inline: 'console.log(1)' }, interpreter: 'node', manifest: '{}' } });
    const dir = path.join(env.state, 'collectors', 'scripts', c.id);
    fs.mkdirSync(path.join(dir, 'node_modules', 'x'), { recursive: true });
    await env.svc.deleteCollector(c.id);
    assert.ok(!fs.existsSync(dir));
    const trash = path.join(env.state, 'collectors', 'trash');
    const [kept] = fs.readdirSync(trash);
    assert.ok(kept!.startsWith(`${c.id}-`));
    assert.equal(fs.readFileSync(path.join(trash, kept!, 'collector.js'), 'utf8'), 'console.log(1)');
    assert.ok(fs.existsSync(path.join(trash, kept!, 'package.json')));
    assert.ok(!fs.existsSync(path.join(trash, kept!, 'node_modules')));
    assert.equal(JSON.parse(fs.readFileSync(path.join(trash, kept!, 'collector.json'), 'utf8')).collector.id, c.id);

    const folders = new ScriptFolders(path.join(env.state, 'collectors'));
    assert.deepEqual(folders.pruneTrash(new Date()), []);
    const old = new Date(Date.now() - (TRASH_KEEP_DAYS + 1) * 24 * 3600 * 1000);
    fs.utimesSync(path.join(trash, kept!), old, old);
    assert.equal(folders.pruneTrash(new Date()).length, 1);
    assert.deepEqual(fs.readdirSync(trash), []);
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
