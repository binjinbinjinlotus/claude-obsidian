import assert from 'node:assert/strict';
import { spawn } from "node:child_process";
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import {
  createFakeCore,
  ensureToken,
  releaseLock,
  startServer,
  statePaths,
  writeLock,
  type FakeCore,
  type RunningServer,
} from '@distill/core/server';
import { HELP, run, type CliIO } from './cli.js';
import { loaderArgs, type ServerSpawner } from './client.js';

interface Captured {
  code: number;
  stdout: string;
  stderr: string;
}

describe('distill CLI', () => {
  let tmp: string;
  let stateDir: string;
  let core: FakeCore;
  let server: RunningServer;
  const spawnCalls: { dir: string; env: NodeJS.ProcessEnv }[] = [];

  const failingSpawner: ServerSpawner = (paths, env) => {
    spawnCalls.push({ dir: paths.dir, env });
    return { pid: undefined, exitCode: () => 1, logPath: path.join(paths.dir, 'server.log') };
  };

  function io(overrides: Partial<CliIO> = {}, stdin = ''): CliIO & { out: string[]; err: string[] } {
    const out: string[] = [];
    const err: string[] = [];
    return {
      out,
      err,
      stdout: (t) => out.push(t),
      stderr: (t) => err.push(t),
      env: { HOME: path.join(tmp, 'home'), DISTILL_STATE_DIR: stateDir },
      cwd: tmp,
      readStdin: async () => stdin,
      spawner: failingSpawner,
      ...overrides,
    };
  }

  async function cli(argv: string[], overrides: Partial<CliIO> = {}, stdin = ''): Promise<Captured> {
    const x = io(overrides, stdin);
    const code = await run(argv, x);
    return { code, stdout: x.out.join(''), stderr: x.err.join('') };
  }

  const lastCall = (m: string) => core.calls.filter((c) => c.method === m).at(-1);

  before(async () => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-cli-'));
    stateDir = path.join(tmp, 'state');
    const paths = statePaths(stateDir);
    const token = ensureToken(paths);
    core = createFakeCore();
    server = await startServer({ core, token });
    writeLock(paths, { port: server.port, startedAt: new Date().toISOString(), version: '0.1.0' });
    fs.writeFileSync(path.join(tmp, 'card.png'), 'png');
    fs.writeFileSync(path.join(tmp, 'setup.jpg'), 'jpg');
    fs.writeFileSync(path.join(tmp, 'note.md'), '# From file\nbody');
  });
  after(async () => {
    releaseLock(statePaths(stateDir));
    await server.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  describe('usage', () => {
    it('--help documents commands, JSON shapes and that approval is not in the CLI', async () => {
      const r = await cli(['--help']);
      assert.equal(r.code, 0);
      for (const s of ['distill ask', 'note add', 'status', 'serve', 'plugin install', 'no approve', '--json output', 'Exit codes']) {
        assert.ok(r.stdout.includes(s), s);
      }
      assert.equal((await cli([])).code, 2);
    });
    it('--version', async () => {
      const r = await cli(['--version']);
      assert.equal(r.code, 0);
      assert.match(r.stdout, /^distill \d+\.\d+\.\d+\n$/);
    });
    it('unknown command or flag exits 2', async () => {
      assert.equal((await cli(['approve', 'job-1'])).code, 2);
      const r = await cli(['ask', 'q', '--bogus']);
      assert.equal(r.code, 2);
      assert.match(r.stderr, /bogus/);
    });
    it('usage errors are JSON with --json', async () => {
      const r = await cli(['note', 'add', '--json']);
      assert.equal(r.code, 2);
      assert.deepEqual(JSON.parse(r.stdout).error.code, 'usage');
    });
    it('note add validates its text sources', async () => {
      assert.equal((await cli(['note', 'add', '--title', 'T'])).code, 2);
      assert.equal((await cli(['note', 'add', '--title', 'T', '--text', 'a', '--file', 'note.md'])).code, 2);
      assert.equal((await cli(['note', 'add', '--title', 'T', 'stray'])).code, 2);
      const missing = await cli(['note', 'add', '--title', 'T', '--image', 'nope.png', '--json']);
      assert.equal(missing.code, 1);
      assert.equal(JSON.parse(missing.stdout).error.code, 'file_not_found');
    });
  });

  describe('ask', () => {
    it('--json prints the AskResponse and sends filters', async () => {
      const r = await cli(['ask', 'How hot for sencha?', '--label', 'tea', '--label', 'green', '--source', 'slack', '--json']);
      assert.equal(r.code, 0, r.stderr);
      const res = JSON.parse(r.stdout);
      assert.deepEqual(Object.keys(res).sort(), ['answer', 'citations', 'conversationID', 'costUSD', 'gaps', 'selection']);
      assert.deepEqual(lastCall('ask')?.args[0], { question: 'How hot for sencha?', labels: ['tea', 'green'], sources: ['slack'] });
    });
    it('merges --model/--effort with the settings default and passes --conversation', async () => {
      const r = await cli(['ask', 'more?', '--model', 'opus', '--effort', 'high', '--conversation', 'conv-7', '--json']);
      assert.equal(r.code, 0, r.stderr);
      assert.deepEqual(lastCall('ask')?.args[0], {
        question: 'more?',
        conversationID: 'conv-7',
        selection: { runnerID: 'claude-code', model: 'opus', effort: 'high' },
      });
      assert.equal(JSON.parse(r.stdout).conversationID, 'conv-7');
    });
    it('--runner different from the default requires --model', async () => {
      assert.equal((await cli(['ask', 'q', '--runner', 'codex'])).code, 2);
    });
    it('reads the question from stdin with "-"', async () => {
      const r = await cli(['ask', '-', '--json'], {}, 'from stdin\n');
      assert.equal(r.code, 0);
      assert.equal((lastCall('ask')?.args[0] as { question: string }).question, 'from stdin');
    });
    it('human output lists citations, gaps and the conversation id', async () => {
      const r = await cli(['ask', 'How hot for sencha?']);
      assert.equal(r.code, 0);
      assert.match(r.stdout, /Brew sencha/);
      assert.match(r.stdout, /\[1\] Sencha \(wiki\/tea\/sencha\.md\)/);
      assert.match(r.stdout, /No notes on cold brewing/);
      assert.match(r.stdout, /--conversation conv-1/);
    });
    it('server errors exit 1 with the error shape', async () => {
      core.failNext('ask', Object.assign(new Error('no vault selected'), { code: 'no_vault' }));
      const r = await cli(['ask', 'q', '--json']);
      assert.equal(r.code, 1);
      assert.deepEqual(JSON.parse(r.stdout), { error: { code: 'no_vault', message: 'no vault selected' } });
    });
  });

  describe('note add', () => {
    it('--json prints AddNoteResult; images resolve to absolute paths with modes', async () => {
      const r = await cli([
        'note', 'add', '--title', 'Gyokuro at 60 °C', '--text', 'Steep 2 min.',
        '--image', 'card.png:extract', '--image', 'setup.jpg', '--source', 'in-person', '--ref', 'with Mei', '--json',
      ]);
      assert.equal(r.code, 0, r.stderr);
      const res = JSON.parse(r.stdout);
      assert.deepEqual(Object.keys(res).sort(), ['notePath', 'queued', 'requestID']);
      assert.deepEqual(lastCall('addNote')?.args[0], {
        title: 'Gyokuro at 60 °C',
        text: 'Steep 2 min.',
        images: [
          { path: path.join(tmp, 'card.png'), mode: 'extract' },
          { path: path.join(tmp, 'setup.jpg'), mode: 'keep' },
        ],
        source: 'in-person',
        sourceRef: 'with Mei',
      });
    });
    it('reads text from --file and from stdin', async () => {
      assert.equal((await cli(['note', 'add', '--title', 'F', '--file', 'note.md', '--json'])).code, 0);
      assert.equal((lastCall('addNote')?.args[0] as { text: string }).text, '# From file\nbody');
      assert.equal((await cli(['note', 'add', '--title', 'S', '-', '--json'], {}, 'piped text')).code, 0);
      assert.equal((lastCall('addNote')?.args[0] as { text: string }).text, 'piped text');
    });
    it('accepts option values that start with "-" (Markdown bullets)', async () => {
      const r = await cli(['note', 'add', '--title', 'B', '--text', '- a bullet', '--ref', '-x', '--json']);
      assert.equal(r.code, 0, r.stdout);
      assert.equal((lastCall('addNote')?.args[0] as { text: string }).text, '- a bullet');
      const q = await cli(['ask', '--json', '--', '-why?']);
      assert.equal(q.code, 0, q.stdout);
      assert.equal((lastCall('ask')?.args[0] as { question: string }).question, '-why?');
    });
    it('human output says it is queued for approval', async () => {
      const r = await cli(['note', 'add', '--title', 'H', '--text', 'x']);
      assert.equal(r.code, 0);
      assert.match(r.stdout, /Queued "H"/);
      assert.match(r.stdout, /approve/);
    });
  });

  describe('status', () => {
    it('--json includes StatusResponse and the server lock', async () => {
      const r = await cli(['status', '--json']);
      assert.equal(r.code, 0, r.stderr);
      const res = JSON.parse(r.stdout);
      assert.equal(res.version, '0.1.0-fake');
      assert.equal(res.pendingApprovals, 1);
      assert.equal(res.server.port, server.port);
      assert.equal(res.server.pid, process.pid);
    });
    it('human output', async () => {
      const r = await cli(['status']);
      assert.match(r.stdout, /Vault: +\/tmp\/vault/);
      assert.match(r.stdout, /1 waiting for review/);
    });
  });

  describe('server autostart', () => {
    it('starts a server with the CLI state dir when none is running, and reports a failed start', async () => {
      const otherState = path.join(tmp, 'other-state');
      const before = spawnCalls.length;
      const r = await cli(['status', '--json'], { env: { HOME: path.join(tmp, 'home'), DISTILL_STATE_DIR: otherState } });
      assert.equal(r.code, 1);
      assert.equal(JSON.parse(r.stdout).error.code, 'server_start_failed');
      assert.equal(spawnCalls.length, before + 1);
      assert.equal(spawnCalls.at(-1)?.dir, otherState);
    });
    it('without DISTILL_STATE_DIR uses $HOME/Library/Application Support/Distill from the given env', async () => {
      const home = path.join(tmp, 'home2');
      await cli(['status', '--json'], { env: { HOME: home } });
      assert.equal(spawnCalls.at(-1)?.dir, path.join(home, 'Library', 'Application Support', 'Distill'));
    });
    it('loaderArgs keeps loader flags and drops test/inspect flags', () => {
      assert.deepEqual(loaderArgs(['--import', 'tsx', '--test', '--inspect=9229', '--loader=x', '--test-reporter=spec']), [
        '--import',
        'tsx',
        '--loader=x',
      ]);
    });
  });

  describe('plugin install', () => {
    const pluginDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..', 'plugin');

    it('--target claude --dry-run prints the two claude plugin commands', async () => {
      const r = await cli(['plugin', 'install', '--target', 'claude', '--dry-run', '--json']);
      assert.equal(r.code, 0, r.stdout);
      const res = JSON.parse(r.stdout);
      assert.deepEqual(
        res.actions.map((a: { command: string[] }) => a.command),
        [
          ['claude', 'plugin', 'marketplace', 'add', pluginDir],
          ['claude', 'plugin', 'install', 'distill@distill-local'],
        ],
      );
      const human = await cli(['plugin', 'install', '--target', 'claude', '--dry-run']);
      assert.match(human.stdout, /would run: claude plugin install distill@distill-local/);
    });
    it('--target claude runs the commands through the runner', async () => {
      const ran: string[][] = [];
      const r = await cli(['plugin', 'install', '--target', 'claude', '--json'], { runCommand: (argv) => (ran.push(argv), 0) });
      assert.equal(r.code, 0);
      assert.equal(ran.length, 2);
      const failed = await cli(['plugin', 'install', '--target', 'claude', '--json'], { runCommand: () => 1 });
      assert.equal(failed.code, 1);
    });
    it('--target codex --dry-run changes nothing', async () => {
      const home = path.join(tmp, 'home-dry');
      const r = await cli(['plugin', 'install', '--target', 'codex', '--dry-run', '--json'], { env: { HOME: home, DISTILL_STATE_DIR: stateDir } });
      assert.equal(r.code, 0, r.stdout);
      const res = JSON.parse(r.stdout);
      assert.deepEqual(
        res.actions.map((a: { action: string; skill: string; destination: string }) => [a.action, a.skill, a.destination]),
        [
          ['link', 'distill-ask', path.join(home, '.agents', 'skills', 'distill-ask')],
          ['link', 'distill-note', path.join(home, '.agents', 'skills', 'distill-note')],
        ],
      );
      assert.ok(res.notes.join(' ').includes('~/.codex/skills/'));
      assert.equal(fs.existsSync(path.join(home, '.agents')), false);
    });
    it('--target codex links skills into a temp HOME, is idempotent, refuses conflicts without --force', async () => {
      const home = path.join(tmp, 'home-real');
      const env = { HOME: home, DISTILL_STATE_DIR: stateDir };
      assert.equal((await cli(['plugin', 'install', '--target', 'codex'], { env })).code, 0);
      for (const name of ['distill-ask', 'distill-note']) {
        const dest = path.join(home, '.agents', 'skills', name);
        assert.ok(fs.lstatSync(dest).isSymbolicLink());
        assert.equal(fs.realpathSync(dest), fs.realpathSync(path.join(pluginDir, 'skills', name)));
        assert.ok(fs.existsSync(path.join(dest, 'SKILL.md')));
      }
      const again = JSON.parse((await cli(['plugin', 'install', '--target', 'codex', '--json'], { env })).stdout);
      assert.deepEqual(again.actions.map((a: { action: string }) => a.action), ['unchanged', 'unchanged']);

      const copyHome = path.join(tmp, 'home-copy');
      fs.mkdirSync(path.join(copyHome, '.agents', 'skills', 'distill-ask'), { recursive: true });
      fs.writeFileSync(path.join(copyHome, '.agents', 'skills', 'distill-ask', 'SKILL.md'), 'mine');
      const copyEnv = { HOME: copyHome, DISTILL_STATE_DIR: stateDir };
      const conflict = await cli(['plugin', 'install', '--target', 'codex', '--copy', '--json'], { env: copyEnv });
      assert.equal(conflict.code, 1);
      assert.equal(JSON.parse(conflict.stdout).error.code, 'conflict');
      assert.equal(fs.readFileSync(path.join(copyHome, '.agents', 'skills', 'distill-ask', 'SKILL.md'), 'utf8'), 'mine');
      assert.equal((await cli(['plugin', 'install', '--target', 'codex', '--copy', '--force'], { env: copyEnv })).code, 0);
      const copied = path.join(copyHome, '.agents', 'skills', 'distill-ask');
      assert.equal(fs.lstatSync(copied).isSymbolicLink(), false);
      assert.match(fs.readFileSync(path.join(copied, 'SKILL.md'), 'utf8'), /^---\nname: distill-ask\n/);
    });
    it('--target is required', async () => {
      assert.equal((await cli(['plugin', 'install'])).code, 2);
    });
  });

  it('skills have exactly name and description in frontmatter', () => {
    const skillsDir = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..', 'plugin', 'skills');
    for (const name of fs.readdirSync(skillsDir)) {
      const text = fs.readFileSync(path.join(skillsDir, name, 'SKILL.md'), 'utf8');
      const fm = /^---\n([\s\S]*?)\n---\n/.exec(text)?.[1] ?? '';
      const keys = fm.split('\n').map((l) => l.split(':')[0]);
      assert.deepEqual(keys, ['name', 'description'], name);
      assert.ok(fm.startsWith(`name: ${name}\n`), name);
    }
  });

  it('runs as a subprocess against the running server (end to end)', async () => {
    // Async spawn: the test server lives in this process, so a sync spawn would deadlock.
    const entry = path.join(path.dirname(new URL(import.meta.url).pathname), 'main.ts');
    const child = spawn(process.execPath, ['--import', 'tsx', entry, 'status', '--json'], {
      env: { ...process.env, DISTILL_STATE_DIR: stateDir },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (c: Buffer) => (stdout += c));
    child.stderr.on('data', (c: Buffer) => (stderr += c));
    const code = await new Promise<number | null>((r) => child.on('close', r));
    assert.equal(code, 0, stderr);
    assert.equal(JSON.parse(stdout).server.port, server.port);
    assert.ok(HELP.length > 0);
  });
});
