// Unit tests for the CLI's argument parsing and its plain-words formatting. Requests go to a fake
// core over the real API, so each test can check exactly what reached the core (or that nothing did).
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import type { RereadResult } from '@distill/core/contracts';
import {
  createFakeCore,
  ensureToken,
  releaseLock,
  sampleActivityEntry,
  sampleCollectorRun,
  sampleJob,
  startServer,
  statePaths,
  writeLock,
  type FakeCore,
  type RunningServer,
} from '@distill/core/server';
import { describeActivity, describeReread, describeRun, describeScan, parseImage, parseWhen, run, type CliIO } from './cli.js';
import type { ServerSpawner } from './client.js';

describe('CLI parsing and formatting', () => {
  let tmp: string;
  let stateDir: string;
  let core: FakeCore;
  let server: RunningServer;

  const noSpawn: ServerSpawner = () => ({ pid: undefined, exitCode: () => 1, logPath: '/dev/null' });

  async function cli(argv: string[], stdin = '', env?: NodeJS.ProcessEnv, spawner: ServerSpawner = noSpawn) {
    const out: string[] = [];
    const err: string[] = [];
    const io: CliIO = {
      stdout: (t) => out.push(t),
      stderr: (t) => err.push(t),
      env: env ?? { HOME: path.join(tmp, 'home'), DISTILL_STATE_DIR: stateDir, DISTILL_PLUGIN_DIR: path.join(tmp, 'plugin') },
      cwd: tmp,
      readStdin: async () => stdin,
      spawner,
    };
    const code = await run(argv, io);
    return { code, stdout: out.join(''), stderr: err.join('') };
  }
  /** A usage error: exit 2, the message on stderr, and nothing sent to the core. */
  async function usage(argv: string[], message: RegExp) {
    const before = core.calls.length;
    const r = await cli(argv);
    assert.equal(r.code, 2, `${argv.join(' ')}: ${r.stdout}${r.stderr}`);
    assert.match(r.stderr, message, argv.join(' '));
    assert.match(r.stderr, /Run `distill --help` for usage\./);
    assert.equal(core.calls.length, before, `${argv.join(' ')} reached the core`);
  }
  const lastCall = (m: string) => core.calls.filter((c) => c.method === m).at(-1);

  before(async () => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-cli-parse-'));
    stateDir = path.join(tmp, 'state');
    const paths = statePaths(stateDir);
    core = createFakeCore();
    server = await startServer({ core, token: ensureToken(paths) });
    writeLock(paths, { port: server.port, startedAt: new Date().toISOString(), version: '0.1.0' });
    fs.writeFileSync(path.join(tmp, 'card.png'), 'png');
    fs.writeFileSync(path.join(tmp, 'a:b.png'), 'png');
    fs.mkdirSync(path.join(tmp, 'pics'));
    fs.writeFileSync(path.join(tmp, 'note.md'), '# From a file');
    fs.mkdirSync(path.join(tmp, 'plugin', 'skills', 'distill-ask'), { recursive: true });
    fs.writeFileSync(path.join(tmp, 'plugin', 'skills', 'distill-ask', 'SKILL.md'), '---\nname: distill-ask\ndescription: d\n---\n');
    fs.mkdirSync(path.join(tmp, 'plugin', '.claude-plugin'));
    fs.writeFileSync(path.join(tmp, 'plugin', '.claude-plugin', 'plugin.json'), '{"name":"distill"}');
    fs.writeFileSync(path.join(tmp, 'plugin', '.claude-plugin', 'marketplace.json'), '{"name":"distill-local"}');
  });
  after(async () => {
    releaseLock(statePaths(stateDir));
    await server.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  });

  describe('dispatch', () => {
    it('help and version spellings; help anywhere after the command; no command is exit 2', async () => {
      for (const h of ['--help', '-h', 'help']) {
        const r = await cli([h]);
        assert.equal(r.code, 0, h);
        assert.match(r.stdout, /Exit codes/);
      }
      for (const v of ['--version', '-v', 'version']) assert.match((await cli([v])).stdout, /^distill \d+\.\d+\.\d+\n$/, v);
      const calls = core.calls.length;
      for (const argv of [['note', 'add', '--help'], ['ask', '-h']]) {
        const r = await cli(argv);
        assert.equal(r.code, 0);
        assert.match(r.stdout, /Exit codes/);
      }
      assert.equal(core.calls.length, calls);
      const none = await cli([]);
      assert.equal(none.code, 2);
      assert.match(none.stdout, /Exit codes/);
    });
    it('an unknown command names itself; with --json the error is JSON on stdout', async () => {
      await usage(['approve'], /^distill: unknown command "approve"/);
      const j = await cli(['approve', '--json']);
      assert.deepEqual(JSON.parse(j.stdout), { error: { code: 'usage', message: 'unknown command "approve"' } });
      assert.equal(j.stderr, '');
    });
  });

  describe('option parsing', () => {
    it('a string option takes the next token even when it starts with "-"; --name=value is kept as is', async () => {
      assert.equal((await cli(['note', 'add', '--title', '-dash title', '--text', '--not-a-flag', '--json'])).code, 0);
      assert.deepEqual((lastCall('addNote')?.args[0] as { title: string; text: string }).text, '--not-a-flag');
      assert.equal((lastCall('addNote')?.args[0] as { title: string }).title, '-dash title');
      assert.equal((await cli(['note', 'add', '--title=T=1', '--text=a=b', '--json'])).code, 0);
      assert.deepEqual([(lastCall('addNote')?.args[0] as { title: string }).title, (lastCall('addNote')?.args[0] as { text: string }).text], ['T=1', 'a=b']);
    });
    it('a boolean option never takes the next token', async () => {
      assert.equal((await cli(['actions', 'list', '--history', '--type', 'todo', '--json'])).code, 0);
      assert.deepEqual(lastCall('listActions')?.args[0], { type: 'todo', history: true });
    });
    it('"--" ends the options: what follows is positional, even "--json"', async () => {
      const r = await cli(['ask', '--', '--json', 'is', 'a', 'word']);
      assert.equal(r.code, 0, r.stderr);
      assert.equal((lastCall('ask')?.args[0] as { question: string }).question, '--json is a word');
    });
    it('a string option with no value, and an unknown option, are usage errors', async () => {
      await usage(['note', 'add', '--title'], /--title/);
      await usage(['queue', 'scan', '--bogus'], /bogus/);
    });
  });

  describe('labels and images', () => {
    it('--label drops a leading "#" and spaces, removes duplicates and refuses an empty name', async () => {
      assert.equal((await cli(['note', 'add', '--title', 'T', '--text', 'x', '--label', ' #tea ', '--label', 'tea', '--label', '# green', '--json'])).code, 0);
      assert.deepEqual((lastCall('addNote')?.args[0] as { labels: string[] }).labels, ['tea', 'green']);
      for (const bad of ['', '  ', '#', '# ']) await usage(['note', 'add', '--title', 'T', '--text', 'x', '--label', bad], /--label needs a name/);
    });
    it('parseImage: ":extract" / ":keep" pick the mode; keep is the default; only those suffixes are modes', () => {
      assert.deepEqual(parseImage('card.png', tmp), { path: path.join(tmp, 'card.png'), mode: 'keep' });
      assert.deepEqual(parseImage('card.png:extract', tmp), { path: path.join(tmp, 'card.png'), mode: 'extract' });
      assert.deepEqual(parseImage('card.png:keep', tmp), { path: path.join(tmp, 'card.png'), mode: 'keep' });
      assert.deepEqual(parseImage(path.join(tmp, 'card.png'), '/elsewhere'), { path: path.join(tmp, 'card.png'), mode: 'keep' });
      assert.deepEqual(parseImage('a:b.png', tmp), { path: path.join(tmp, 'a:b.png'), mode: 'keep' });
      assert.throws(() => parseImage('card.png:EXTRACT', tmp), /image not found/);
    });
    it('parseImage: no path, a missing file and a folder are refused', () => {
      assert.throws(() => parseImage(':extract', tmp), (e: Error & { code?: string }) => e.code === 'usage' && /--image needs a path, got ":extract"/.test(e.message));
      assert.throws(() => parseImage('nope.png', tmp), (e: Error & { code?: string }) => e.code === 'file_not_found' && e.message === `image not found: ${path.join(tmp, 'nope.png')}`);
      assert.throws(() => parseImage('pics', tmp), (e: Error & { code?: string }) => e.code === 'file_not_found' && e.message === `image is not a file: ${path.join(tmp, 'pics')}`);
    });
  });

  describe('ask', () => {
    it('--match and --unconfirmed take only their words; a question is required', async () => {
      await usage(['ask', 'q', '--match', 'some'], /--match must be "any" or "all"/);
      await usage(['ask', 'q', '--unconfirmed', 'yes'], /--unconfirmed must be "include" or "exclude"/);
      await usage(['ask'], /ask needs a question/);
      await usage(['ask', '  '], /ask needs a question/);
      assert.equal((await cli(['ask', '-'], '   \n')).code, 2);
    });
    it('--unconfirmed exclude sends false; labels and sources are passed; the words of a question are joined', async () => {
      const r = await cli(['ask', 'how', 'hot?', '--unconfirmed', 'exclude', '--match', 'all', '--label', '#tea', '--source', 'slack', '--source', 'mail', '--json']);
      assert.equal(r.code, 0, r.stderr);
      const req = lastCall('ask')?.args[0] as Record<string, unknown>;
      assert.equal(req.question, 'how hot?');
      assert.equal(req.includeUnconfirmed, false);
      assert.equal(req.labelMatch, 'all');
      assert.deepEqual(req.labels, ['tea']);
      assert.deepEqual(req.sources, ['slack', 'mail']);
      assert.equal(req.newSession, undefined);
      assert.equal(req.vaultPath, undefined);
    });
    it('--vault resolves against the working directory', async () => {
      assert.equal((await cli(['ask', 'q', '--vault', 'v', '--json'])).code, 0);
      assert.equal((lastCall('ask')?.args[0] as { vaultPath: string }).vaultPath, path.join(tmp, 'v'));
    });
  });

  describe('note', () => {
    it('note needs add or label; note label needs an id and a label, and no extra argument', async () => {
      await usage(['note'], /usage: distill note add --title/);
      await usage(['note', 'edit'], /unknown note command "edit"/);
      await usage(['note', 'add', '--text', 'x'], /note add needs --title/);
      await usage(['note', 'add', '--title', '  ', '--text', 'x'], /note add needs --title/);
      await usage(['note', 'add', '--title', 'T', '--text', 'x', '-'], /give the text once/);
      await usage(['note', 'add', '--title', 'T', '--text', '  '], /a note needs text/);
      await usage(['note', 'label'], /usage: distill note label <request-id>/);
      await usage(['note', 'label', ' ', '--label', 'a'], /usage: distill note label <request-id>/);
      await usage(['note', 'label', 'req-1', 'extra', '--label', 'a'], /unexpected argument "extra"/);
      await usage(['note', 'label', 'req-1'], /note label needs at least one --label/);
    });
    it('only images is a note; --source, --ref and --vault pass through; the request is from the CLI', async () => {
      assert.equal((await cli(['note', 'add', '--title', 'Card', '--image', 'card.png:extract', '--source', 'slack', '--ref', 'C1/p2', '--vault', 'v', '--no-suggest', '--json'])).code, 0);
      assert.deepEqual(lastCall('addNote')?.args[0], {
        title: 'Card', text: '', images: [{ path: path.join(tmp, 'card.png'), mode: 'extract' }], source: 'slack', sourceRef: 'C1/p2',
        vaultPath: path.join(tmp, 'v'), origin: 'cli', suggest: 'none',
      });
    });
    it('human output counts kept and read images and quotes the follow-up command for the shell', async () => {
      const r = await cli(['note', 'add', '--title', 'Two', '--text', 'x', '--image', 'card.png', '--image', 'card.png:keep', '--image', 'card.png:extract', '--label', "it's", '--label', 'plain-1']);
      assert.equal(r.code, 0, r.stderr);
      assert.match(r.stdout, /^Queued "Two" \(2 images kept, 1 read as text\): /);
      assert.match(r.stdout, /\nLabels: it's, plain-1\n/);
      const one = await cli(['note', 'add', '--title', 'One', '--image', 'card.png']);
      assert.match(one.stdout, /^Queued "One" \(1 image kept\): /);
      const plain = await cli(['note', 'add', '--title', 'Plain', '--text', 'x', '--no-suggest']);
      assert.match(plain.stdout, /^Queued "Plain": /);
      assert.doesNotMatch(plain.stdout, /No label suggestions/);
      assert.match(plain.stdout, /Set labels: distill note label \S+ --label <label>/);
    });
  });

  describe('history and actions', () => {
    it('history: unknown sub-command, missing or extra ids', async () => {
      await usage(['history', 'list'], /unknown history command "list"/);
      await usage(['history', 'show'], /usage: distill history show <conversation-id>/);
      await usage(['history', 'rm', ' '], /usage: distill history rm <conversation-id>/);
      await usage(['history', 'show', 'a', 'b'], /unexpected argument "b"/);
    });
    it('actions: each sub-command checks its arguments before calling the core', async () => {
      await usage(['actions'], /usage: distill actions list \| add/);
      await usage(['actions', 'confirm'], /unknown actions command "confirm"/);
      await usage(['actions', 'list', 'x'], /unexpected argument "x"/);
      await usage(['actions', 'add'], /usage: distill actions add "<title>"/);
      await usage(['actions', 'add', '  '], /usage: distill actions add "<title>"/);
      await usage(['actions', 'add', 'T', 'extra'], /unexpected argument "extra"/);
      for (const due of ['2026-1-05', 'tomorrow', '2026-10-05T10:00', 'x2026-10-05']) await usage(['actions', 'add', 'T', '--due', due], /--due must be a date like 2026-10-05/);
      await usage(['actions', 'found'], /usage: distill actions found <job-id>/);
      await usage(['actions', 'found', 'j', 'k'], /unexpected argument "k"/);
      await usage(['actions', 'buttons', 'todo', 'x'], /unexpected argument "x"/);
      await usage(['actions', 'preview', 'a'], /usage: distill actions preview <action-id> <button-id>/);
      await usage(['actions', 'preview', 'a', 'b', 'c'], /unexpected argument "c"/);
    });
    it('actions add: defaults to a to-do from an agent; --body, --why, --due and --vault pass through', async () => {
      assert.equal((await cli(['actions', 'add', '  Call Mei  ', '--json'])).code, 0);
      assert.deepEqual(lastCall('createAction')?.args[0], { type: 'todo', title: 'Call Mei', source: { kind: 'manual', by: 'agent' } });
      assert.equal((await cli(['actions', 'add', 'Ping', '--type', 'slack', '--body', '', '--why', 'w', '--due', '2026-10-05', '--vault', 'v', '--json'])).code, 0);
      assert.deepEqual(lastCall('createAction')?.args[0], {
        type: 'slack', title: 'Ping', source: { kind: 'manual', by: 'agent' }, body: '', why: 'w', fields: { due: '2026-10-05' }, vaultPath: path.join(tmp, 'v'),
      });
    });
  });

  describe('queue, batch, collectors, activity, trash, status, serve, plugin', () => {
    it('queue scan and sync are the same; anything else is a usage error', async () => {
      await usage(['queue', 'list'], /usage: distill queue scan/);
      assert.equal((await cli(['queue', 'sync', '--json'])).code, 0);
      assert.deepEqual(lastCall('scanQueue')?.args, [{ trigger: 'manual' }]);
    });
    it('batch reread: --per-batch is a whole number 1–10, --tokens a whole number from 1000', async () => {
      for (const bad of ['1.5', '-1', 'two', '1e1']) await usage(['batch', 'reread', 'inbox/a.md', '--per-batch', bad], /--per-batch must be a whole number from 1 to 10/);
      for (const bad of ['999', '1000.5', '5e3']) await usage(['batch', 'reread', 'inbox/a.md', '--tokens', bad], /--tokens must be a whole number, at least 1000/);
      await usage(['batch', 'reread', 'inbox/a.md', '--tokens', '2000', '--per-batch', '3'], /give --tokens or --per-batch, not both/);
      await usage(['batch'], /usage: distill batch reread/);
      await usage(['batch', 'reread'], /give inbox files or --job JOB_ID \(not both\)/);
      assert.equal((await cli(['batch', 'reread', 'inbox/a.md', '--per-batch', '1', '--json'])).code, 0);
      assert.equal((await cli(['batch', 'reread', 'inbox/a.md', '--per-batch', '10', '--json'])).code, 0);
      assert.deepEqual(lastCall('rereadSources')?.args[0], { files: ['inbox/a.md'], perBatch: 10 });
      assert.equal((await cli(['batch', 'reread', 'inbox/a.md', '--tokens', '1000', '--vault', 'v', '--json'])).code, 0);
      assert.deepEqual(lastCall('rereadSources')?.args[0], { files: ['inbox/a.md'], tokenBudget: 1000, vaultPath: path.join(tmp, 'v') });
    });
    it('collectors: sub-commands, ids and --limit', async () => {
      await usage(['collectors'], /usage: distill collectors list \| run <id> \| history <id>/);
      await usage(['collectors', 'allow', 'c'], /unknown collectors command "allow"/);
      await usage(['collectors', 'list', 'x'], /unexpected argument "x"/);
      await usage(['collectors', 'run'], /usage: distill collectors run <id>/);
      await usage(['collectors', 'run', 'a', 'b'], /unexpected argument "b"/);
      await usage(['collectors', 'history'], /usage: distill collectors history <id>/);
      await usage(['collectors', 'history', 'a', 'b'], /unexpected argument "b"/);
      for (const bad of ['0', '-3', '1.5', 'ten']) await usage(['collectors', 'history', 'col-1', '--limit', bad], /--limit must be a positive integer/);
      assert.equal((await cli(['collectors', 'history', 'col-1', '--limit', '1', '--json'])).code, 0);
      assert.deepEqual(lastCall('listCollectorRuns')?.args.slice(0, 2), ['col-1', { limit: 1 }]);
      assert.equal((await cli(['collectors', 'history', 'col-1', '--json'])).code, 0);
      assert.deepEqual(lastCall('listCollectorRuns')?.args.slice(0, 2), ['col-1', { limit: 20 }]);
    });
    it('activity: --limit 1–500; filters become query parameters; --failed asks for failures only', async () => {
      for (const bad of ['0', '501', '2.5', 'x']) await usage(['activity', '--limit', bad], /--limit must be an integer from 1 to 500/);
      await usage(['activity', 'extra'], /unexpected argument "extra"/);
      await usage(['activity', '--until', 'someday'], /"someday" is not a date, a time or an age like 24h/);
      assert.equal((await cli(['activity', '--limit', '500', '--json'])).code, 0);
      assert.equal((await cli(['activity', '--limit', '1', '--failed', '--kind', 'chat', '--search', 'tea', '--cursor', 'c1', '--until', '2026-10-01', '--json'])).code, 0);
      assert.deepEqual(lastCall('listActivity')?.args[0], { limit: 1, outcome: 'failed', objectKind: 'chat', text: 'tea', cursor: 'c1', until: '2026-10-01T00:00:00.000Z' });
    });
    it('trash: a bare flag lists; unknown sub-commands and extra ids are refused', async () => {
      assert.equal((await cli(['trash', '--json'])).code, 0);
      assert.ok(lastCall('listTrash'));
      await usage(['trash', 'empty'], /unknown trash command "empty"/);
      await usage(['trash', ''], /usage: distill trash \[list\] \| restore <id>/);
      await usage(['queue', 'scan', 'extra'], /unexpected argument "extra"/);
      await usage(['trash', 'list', 'x'], /unexpected argument "x"/);
      await usage(['trash', 'restore'], /usage: distill trash restore <trash-id>/);
      await usage(['trash', 'restore', 'a', 'b'], /unexpected argument "b"/);
      const r = await cli(['trash', 'restore', 'trash-none', '--json']);
      assert.equal(r.code, 1);
      assert.equal(JSON.parse(r.stdout).error.code, 'not_found');
    });
    it('status, serve and plugin refuse stray arguments and bad values', async () => {
      await usage(['status', 'now'], /unexpected argument "now"/);
      for (const bad of ['-1', '65536', '80.5', 'http']) await usage(['serve', '--port', bad], new RegExp(`invalid --port "${bad.replace('.', '\\.')}"`));
      await usage(['serve', 'x'], /unexpected argument "x"/);
      await usage(['plugin'], /usage: distill plugin install --target claude\|codex/);
      await usage(['plugin', 'remove'], /unknown plugin command "remove"/);
      await usage(['plugin', 'install', 'x', '--target', 'codex'], /unexpected argument "x"/);
      await usage(['plugin', 'install', '--target', 'cursor'], /--target must be "claude" or "codex"/);
    });
    it('status words each recovery state and lists problems from the core and the runners', async () => {
      const saved = core.jobs;
      core.jobs = [
        sampleJob({ id: 'job-w', state: 'awaitingApproval', files: ['inbox/w.md'], recovery: { state: 'waiting', signature: 'lock', attempts: [] } }),
        sampleJob({ id: 'job-r', state: 'running', files: [], recovery: { state: 'running', signature: 'session-gone', attempts: [] } }),
        sampleJob({ id: 'job-u', state: 'failed', files: ['inbox/u.md'], recovery: { state: 'gaveUp', signature: 'mystery' as never, attempts: [] } }),
      ];
      try {
        const r = await cli(['status']);
        assert.equal(r.code, 0, r.stderr);
        assert.match(r.stdout, /Recovery: w · the vault was locked · waiting to try again \[job-w\]/);
        assert.match(r.stdout, /Recovery: job-r · its AI session is gone · recovering \[job-r\]/);
        assert.match(r.stdout, /Recovery: u · mystery · couldn’t fix it, needs you \(in the Distill app\) \[job-u\]/);
        assert.match(r.stdout, /Jobs: +1 running · 1 waiting for review \(review in the Distill app\)/);
      } finally {
        core.jobs = saved;
      }
    });
  });

  describe('parseWhen', () => {
    const now = new Date('2026-10-06T12:00:00.000Z');
    it('an age in minutes, hours, days or weeks, any case, spaces allowed', () => {
      assert.equal(parseWhen('30m', now), '2026-10-06T11:30:00.000Z');
      assert.equal(parseWhen('24h', now), '2026-10-05T12:00:00.000Z');
      assert.equal(parseWhen(' 2 D ', now), '2026-10-04T12:00:00.000Z');
      assert.equal(parseWhen('1w', now), '2026-09-29T12:00:00.000Z');
      assert.equal(parseWhen('0h', now), now.toISOString());
    });
    it('else a date or a time; anything else is a usage error', () => {
      assert.equal(parseWhen('2026-10-01', now), '2026-10-01T00:00:00.000Z');
      assert.equal(parseWhen('2026-10-01T08:30:00Z', now), '2026-10-01T08:30:00.000Z');
      for (const bad of ['1y', 'h', 'yesterday', '']) {
        assert.throws(() => parseWhen(bad, now), (e: Error & { code?: string }) => e.code === 'usage' && e.message === `"${bad}" is not a date, a time or an age like 24h`, bad);
      }
    });
  });

  describe('describeRun', () => {
    it('counts only for finished results; added only for scripts; plural errors; seconds dropped from the time', () => {
      const counts = { copied: 2, moved: 1, skipped: 3, waiting: 4, errors: 2, added: 5 };
      assert.equal(describeRun(sampleCollectorRun({ counts, trigger: 'now' })), '2026-10-04 09:00Z  now  done  · copied 2 · moved 1 · skipped 3 already collected · 4 still changing · 2 errors');
      assert.equal(describeRun(sampleCollectorRun({ kind: 'script', counts: { ...counts, copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 1 } })), '2026-10-04 09:00Z  schedule  done  · added 5 · 1 error');
      for (const result of ['nothing', 'failed', 'stopped'] as const) assert.match(describeRun(sampleCollectorRun({ result })), / · copied 1 · skipped 2 already collected$/, result);
      for (const result of ['queued', 'running', 'timedout', 'skipped', 'notTrusted'] as const) assert.doesNotMatch(describeRun(sampleCollectorRun({ result })), /copied/, result);
      assert.equal(describeRun(sampleCollectorRun({ result: 'notTrusted', counts: { copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 0, added: 0 } })), '2026-10-04 09:00Z  schedule  not run');
    });
    it('the skip reason, the error and a non-zero exit code follow the counts', () => {
      const none = { copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 0, added: 0 };
      assert.equal(
        describeRun(sampleCollectorRun({ result: 'failed', counts: none, skipReason: 'the vault is busy', error: { code: 'x', message: 'boom' }, exitCode: 3 } as never)),
        '2026-10-04 09:00Z  schedule  failed  · the vault is busy · boom · exit 3',
      );
      assert.equal(describeRun(sampleCollectorRun({ result: 'timedout', counts: none, exitCode: 0 })), '2026-10-04 09:00Z  schedule  timed out');
      assert.equal(describeRun(sampleCollectorRun({ result: 'timedout', counts: none, exitCode: null } as never)), '2026-10-04 09:00Z  schedule  timed out');
    });
  });

  describe('describeScan and describeReread', () => {
    const entry = (name: string, kind?: 'folder') => ({ path: `/q/${name}`, name, modified: '', size: 1, settled: true, ...(kind ? { kind } : {}) });
    it('a problem wins; one of each is singular; changed entries are marked "~"', () => {
      const base = { added: 0, removed: 0, changed: 0, checkedAt: '', trigger: 'manual' as const, addedEntries: [], removedEntries: [], changedEntries: [], entries: [] };
      assert.equal(describeScan({ ...base, added: 1, problem: 'permission denied' }), "Can't read the queue folder: permission denied");
      assert.equal(
        describeScan({ ...base, added: 1, removed: 1, changed: 1, addedEntries: [entry('a.md')], removedEntries: [entry('Old', 'folder')], changedEntries: [entry('Trip', 'folder'), entry('b.md')], entries: [entry('a.md')] }),
        '1 new item found · 1 item gone · 1 item changed\n  + a.md\n  - Old/\n  ~ Trip/\n  ~ b.md\n1 item in the queue',
      );
      assert.equal(describeScan({ ...base, problem: null }), 'Nothing new\n0 items in the queue');
    });
    it('describeReread counts a folder once, not its files; waits are singular or plural; skipped sources are named', () => {
      const r: RereadResult = {
        id: 'reread-1', vaultPath: '/v', perBatch: 2, fromJob: null, started: [], waiting: 1,
        groups: [
          { files: ['inbox/Trip/a.md', 'inbox/Trip/b.md', 'inbox/x.md'], folders: ['inbox/Trip'], jobId: 'job-1' },
          { files: ['inbox/y.md'] },
        ],
        skipped: [{ path: 'inbox/z.distill.json', reason: 'a note manifest' }],
      };
      assert.equal(describeReread(r), [
        'Re-reading 3 sources in 2 batches of up to 2 (reread-1).',
        '  1. started as job-1: a.md, b.md, x.md',
        '  2. waits: y.md',
        '1 batch waits: each starts when the one before is ready for review.',
        'Skipped inbox/z.distill.json: a note manifest.',
        'Each batch waits in Review in the Distill app; nothing is applied until you approve it.',
      ].join('\n'));
      const two = describeReread({ ...r, perBatch: 0, tokenBudget: 61_500, waiting: 2, skipped: undefined, groups: [{ files: ['inbox/x.md'] }] });
      assert.match(two, /^Re-reading 1 source in 1 batch of up to about 62K tokens \(reread-1\)\./);
      assert.match(two, /\n2 batches wait: each starts/);
      assert.doesNotMatch(describeReread({ ...r, waiting: 0 }), /wait:|waits:.*each starts/);
    });
  });

  describe('describeActivity', () => {
    it('a failure is marked; the error and each kind of recovery get their own line', () => {
      const e = sampleActivityEntry({ outcome: 'failed', error: 'disk full', source: 'cli' });
      const [first, ...rest] = describeActivity(e).split('\n');
      assert.match(first!, /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}  cli        FAILED Deleted the script collector “Meeting notes”  \[collector\.deleted\]$/);
      assert.equal(rest[0], '    error: disk full');
      assert.match(rest[1]!, /^    kept in Distill's trash until 2026-11-0\d: distill trash restore trash-1791155040000-0a1b2c3d$/);
      assert.equal(describeActivity(sampleActivityEntry({ recovery: { kind: 'macosTrash', path: '/Users/x/.Trash/a.md' } })).split('\n')[1], '    moved to the macOS Trash: /Users/x/.Trash/a.md');
      assert.equal(describeActivity(sampleActivityEntry({ recovery: { kind: 'none', reason: 'too big' } })).split('\n')[1], '    no copy kept: too big');
      assert.equal(describeActivity(sampleActivityEntry({ recovery: undefined, at: 'not a time' })), 'not a time  app        Deleted the script collector “Meeting notes”  [collector.deleted]');
    });
  });

  describe('what each flag does to the request and the output', () => {
    /** The human output (not JSON) and the --json output of one command. */
    async function both(argv: string[]) {
      const human = await cli(argv);
      assert.equal(human.code, 0, `${argv.join(' ')}: ${human.stderr}`);
      assert.doesNotMatch(human.stdout, /^\s*[{[]/, `${argv.join(' ')} printed JSON without --json`);
      const json = await cli([...argv, '--json']);
      assert.equal(json.code, 0, `${argv.join(' ')} --json: ${json.stderr}`);
      return { human: human.stdout, json: JSON.parse(json.stdout) };
    }

    it('every read command prints words, and JSON only with --json', async () => {
      core.trash.push({ ...core.trash[0]!, id: 'trash-chat-1', kind: 'chat', objectID: 'conv-9', name: 'Tea chat' });
      for (const argv of [
        ['ask', 'q'], ['note', 'label', 'req-1', '--label', 'a'], ['history'], ['history', 'show', 'conv-1'], ['actions', 'list'],
        ['actions', 'add', 'T'], ['queue', 'scan'], ['batch', 'reread', 'inbox/a.md'], ['collectors', 'list'], ['collectors', 'run', 'col-1'],
        ['collectors', 'history', 'col-1'], ['activity'], ['trash'], ['trash', 'list'], ['status'], ['actions', 'buttons'],
        ['actions', 'preview', 'act-1', 'btn-1'], ['note', 'add', '--title', 'H', '--text', 'x'],
      ]) {
        if (argv[1] === 'label') {
          // A label needs a request that is still queued.
          await cli(['note', 'add', '--title', 'L', '--text', 'x', '--json']);
          await both(['note', 'label', [...core.notes.keys()].at(-1)!, '--label', 'a']);
        } else {
          await both(argv);
        }
      }
      const found = await cli(['actions', 'found', 'job-x']);
      const foundJSON = await cli(['actions', 'found', 'job-x', '--json']);
      assert.equal(found.code, foundJSON.code);
      if (found.code === 0) assert.doesNotMatch(found.stdout, /^\s*[{[]/);
      assert.ok(foundJSON.stdout.startsWith('{'));
      core.trash.push({ ...core.trash[0]!, id: 'trash-chat-2', kind: 'chat', objectID: 'conv-8', name: 'Other chat' });
      const restoreJSON = await cli(['trash', 'restore', 'trash-chat-2', '--json']);
      assert.equal(JSON.parse(restoreJSON.stdout).item.name, 'Other chat');
      const restore = await cli(['trash', 'restore', 'trash-chat-1']);
      assert.equal(restore.code, 0, restore.stderr);
      assert.match(restore.stdout, /^Restored the chat “Tea chat”/);
    });

    it('JSON errors end with a newline; a failure that is not a usage error has no usage hint', async () => {
      const j = await cli(['trash', 'restore', 'trash-none', '--json']);
      assert.ok(j.stdout.endsWith('}\n'));
      const h = await cli(['trash', 'restore', 'trash-none']);
      assert.equal(h.code, 1);
      assert.equal(h.stderr, 'distill: No trash item trash-none (see "distill trash").\n');
    });

    it('with no DISTILL_STATE_DIR the state is under $HOME/Library/Application Support/Distill; starting a server is said on stderr, never in --json', async () => {
      const dirs: string[] = [];
      const spy: ServerSpawner = (paths) => (dirs.push(paths.dir), { pid: undefined, exitCode: () => 1, logPath: '/dev/null' });
      const home = path.join(tmp, 'home2');
      const human = await cli(['status'], '', { HOME: home }, spy);
      assert.equal(human.code, 1);
      assert.deepEqual(dirs, [path.join(home, 'Library', 'Application Support', 'Distill')]);
      assert.match(human.stderr, /^starting the Distill server \(state: /);
      const json = await cli(['status', '--json'], '', { HOME: home }, spy);
      assert.doesNotMatch(json.stderr, /starting the Distill server/);
    });

    it('"--" keeps a string option after it as two words; a word that is not "--…" is never an option', async () => {
      assert.equal((await cli(['ask', 'tea', '--', '--label', 'green', '--json'])).code, 0);
      assert.equal((lastCall('ask')?.args[0] as { question: string }).question, 'tea --label green --json');
      assert.equal((await cli(['ask', 'xxlabel', 'green', '--json'])).code, 0);
      assert.equal((lastCall('ask')?.args[0] as { question: string }).question, 'xxlabel green');
    });

    it('ask sends only the fields its flags set', async () => {
      assert.equal((await cli(['ask', 'plain', '--json'])).code, 0);
      const { conversationID, ...plain } = lastCall('ask')?.args[0] as Record<string, unknown>;
      assert.ok(conversationID);
      assert.deepEqual(plain, { question: 'plain' });
      assert.equal((await cli(['ask', 'q', '--match', 'any', '--unconfirmed', 'include', '--conversation', 'conv-1', '--new-session', '--json'])).code, 0);
      const req = lastCall('ask')?.args[0] as Record<string, unknown>;
      assert.deepEqual([req.labelMatch, req.includeUnconfirmed, req.conversationID, req.newSession], ['any', true, 'conv-1', true]);
    });

    it('labels as the CLI keeps them: trimmed, one leading "#" dropped, "#" inside kept, duplicates once', async () => {
      const r = await cli(['note', 'add', '--title', 'T', '--text', 'x', '--label', ' #tea ', '--label', '# green', '--label', 'c#', '--label', 'tea']);
      assert.equal(r.code, 0, r.stderr);
      assert.match(r.stdout, /\nLabels: tea, green, c#\n/);
      const two = await cli(['note', 'label', [...core.notes.keys()].at(-1)!, '--label', 'a', '--label', 'b', '--json']);
      assert.deepEqual(JSON.parse(two.stdout).labels, ['a', 'b']);
    });

    it('an image mode is only a final ":extract" or ":keep"', () => {
      assert.throws(() => parseImage('x:extract.png', tmp), { message: `image not found: ${path.join(tmp, 'x:extract.png')}` });
    });

    it('note add: text from --file or stdin; a stray word is refused; a plain note sends only title, text, origin and suggest', async () => {
      await usage(['note', 'add', '--title', 'T', 'stray'], /unexpected argument "stray" \(use --text, --file or -\)/);
      await usage(['note', 'add', '--title', 'T', '-', 'x'], /unexpected argument "-"/);
      await usage(['note', 'add', '--title', 'T', '--file', 'note.md', '-'], /give the text once/);
      assert.equal((await cli(['note', 'add', '--title', 'F', '--file', 'note.md', '--json'])).code, 0);
      assert.equal((lastCall('addNote')?.args[0] as { text: string }).text, '# From a file');
      const missing = await cli(['note', 'add', '--title', 'F', '--file', 'none.md', '--json']);
      assert.equal(missing.code, 1);
      assert.deepEqual(JSON.parse(missing.stdout).error, { code: 'file_not_found', message: `cannot read ${path.join(tmp, 'none.md')}` });
      assert.equal((await cli(['note', 'add', '--title', 'S', '-', '--json'], 'from stdin')).code, 0);
      assert.equal((lastCall('addNote')?.args[0] as { text: string }).text, 'from stdin');
      assert.equal((await cli(['note', 'add', '--title', 'P', '--text', 'x', '--json'])).code, 0);
      assert.deepEqual(lastCall('addNote')?.args[0], { title: 'P', text: 'x', origin: 'cli', suggest: 'wait' });
    });

    it('history, actions found, buttons and preview, collectors run: the happy paths reach the core', async () => {
      assert.equal((await cli(['history', 'show', 'conv-1', '--json'])).code, 0);
      assert.equal((await cli(['actions', 'list', '--json'])).code, 0);
      assert.deepEqual(lastCall('listActions')?.args[0], {});
      const found = await cli(['actions', 'found', 'job-x', '--json']);
      assert.notEqual(found.code, 2, found.stdout);
      assert.equal((await cli(['actions', 'buttons', '--json'])).code, 0);
      const preview = await cli(['actions', 'preview', 'act-1', 'btn-1', '--json']);
      assert.notEqual(preview.code, 2, preview.stdout);
      assert.equal((await cli(['collectors', 'run', 'col-1', '--json'])).code, 0);
      assert.equal((await cli(['collectors', 'list', '--json'])).code, 0);
    });

    it('batch reread drops a leading "./" from files', async () => {
      assert.equal((await cli(['batch', 'reread', './inbox/b.md', '--json'])).code, 0);
      assert.deepEqual(lastCall('rereadSources')?.args[0], { files: ['inbox/b.md'] });
    });

    it('activity: repeated --type and --source are joined; --object and --since are sent; no flags send nothing', async () => {
      assert.equal((await cli(['activity', '--json'])).code, 0);
      assert.deepEqual(lastCall('listActivity')?.args[0], {});
      assert.equal((await cli(['activity', '--type', 'chat.deleted', '--type', 'note.added', '--source', 'app', '--source', 'cli', '--object', 'col-2', '--since', '2026-10-01', '--json'])).code, 0);
      assert.deepEqual(lastCall('listActivity')?.args[0], {
        types: ['chat.deleted', 'note.added'], sources: ['app', 'cli'], objectID: 'col-2', since: '2026-10-01T00:00:00.000Z',
      });
    });

    it('parseWhen: the age must be the whole text', () => {
      for (const bad of ['24hours', 'x24h']) assert.throws(() => parseWhen(bad), { message: `"${bad}" is not a date, a time or an age like 24h` });
    });

    it('plugin install takes both targets', async () => {
      for (const target of ['claude', 'codex']) {
        const r = await cli(['plugin', 'install', '--target', target, '--dry-run', '--json']);
        assert.equal(r.code, 0, r.stdout);
        assert.equal(JSON.parse(r.stdout).target, target);
      }
    });
  });

  describe('words for each result and problem', () => {
    it('describeRun names every result', () => {
      const none = { copied: 0, moved: 0, skipped: 0, waiting: 0, errors: 0, added: 0 };
      const words = (['queued', 'running', 'success', 'nothing', 'failed', 'timedout', 'skipped', 'notTrusted', 'stopped'] as const).map((result) =>
        describeRun(sampleCollectorRun({ result, counts: none })).split('  ')[2],
      );
      assert.deepEqual(words, ['queued', 'running', 'done', 'nothing new', 'failed', 'timed out', 'skipped', 'not run', 'stopped']);
    });

    it('describeScan marks folders in every list', () => {
      const entry = (name: string, kind?: 'folder') => ({ path: `/q/${name}`, name, modified: '', size: 1, settled: true, ...(kind ? { kind } : {}) });
      const text = describeScan({
        added: 2, removed: 2, changed: 0, checkedAt: '', trigger: 'manual',
        addedEntries: [entry('Trip', 'folder'), entry('a.md')], removedEntries: [entry('Old', 'folder'), entry('b.md')], changedEntries: [], entries: [],
      });
      assert.equal(text, '2 new items found · 2 items gone\n  + Trip/\n  + a.md\n  - Old/\n  - b.md\n0 items in the queue');
    });

    it('describeReread: a file counts once when it is in any of the folders; a name that only starts like a folder is its own source', () => {
      const r: RereadResult = {
        id: 'reread-2', vaultPath: '/v', perBatch: 3, started: [], waiting: 0,
        groups: [{ files: ['inbox/A/1.md', 'inbox/B/2.md', 'inbox/Atlas.md'], folders: ['inbox/A', 'inbox/B'] }],
      };
      assert.match(describeReread(r), /^Re-reading 3 sources in 1 batch of up to 3 \(reread-2\)\.\n/);
      assert.doesNotMatch(describeReread(r), /Skipped/);
    });

    it('status: the whole text, with every recovery problem in words', async () => {
      const signatures = ['stale-again', 'plan-error', 'runner-failed', 'denial', 'lock', 'not-recorded', 'full-read-stop', 'session-gone'] as const;
      const saved = core.status;
      core.status = async () => ({
        version: '9.9.9', activeVault: { path: '/v', queueDirectory: '/v/inbox' } as never, problems: [{ code: 'p1', message: 'Core problem' }],
        queueCount: 1, pendingApprovals: 0, runningJobs: 2, nextBatchAt: '2026-10-06T13:00:00Z',
        applyQueue: [{ id: 'job-q', name: 'Sync', vaultPath: '/v', position: 1 }],
        recovering: [
          ...signatures.map((signature, i) => ({ id: `job-${i}`, name: `B${i}`, signature, state: 'running' as const })),
          { id: 'job-w', name: 'W', signature: 'lock' as const, state: 'waiting' as const, waitUntil: '2026-10-06T12:05:00Z' },
        ],
        runners: [
          { id: 'claude-code', displayName: 'Claude Code', enabled: true, problems: [] },
          { id: 'codex', displayName: 'Codex', enabled: false, problems: [{ code: 'r1', message: 'Not signed in' }] },
        ],
      }) as never;
      try {
        const r = await cli(['status']);
        assert.equal(r.code, 0, r.stderr);
        const [head, ...rest] = r.stdout.split('\n');
        assert.match(head!, /^Distill 9\.9\.9 · server pid \d+ on 127\.0\.0\.1:\d+$/);
        assert.equal(rest.join('\n'), [
          'Vault:   /v', 'Queue:   /v/inbox',
          'Queued:  1 file · next batch 2026-10-06T13:00:00Z',
          'Jobs:    2 running · 0 waiting for review',
          'Applies: 1. Sync (approved, waiting its turn in v) [job-q]',
          'Recovery: B0 · its plan keeps going out of date · recovering [job-0]',
          'Recovery: B1 · the vault core couldn’t check its plan · recovering [job-1]',
          'Recovery: B2 · the AI run stopped with an error · recovering [job-2]',
          'Recovery: B3 · Claude was blocked from running a command · recovering [job-3]',
          'Recovery: B4 · the vault was locked · recovering [job-4]',
          'Recovery: B5 · the apply wasn’t recorded · recovering [job-5]',
          'Recovery: B6 · a source couldn’t be read in full · recovering [job-6]',
          'Recovery: B7 · its AI session is gone · recovering [job-7]',
          'Recovery: W · the vault was locked · next try at 2026-10-06T12:05:00Z [job-w]',
          'Runner:  Claude Code (claude-code)',
          'Runner:  Codex (codex) disabled · 1 problem(s)',
          'Problems:', '  - Core problem [p1]', '  - Not signed in [r1]', '',
        ].join('\n'));
        core.status = async () => ({ ...(await saved()), activeVault: null, queueCount: 3, applyQueue: undefined, recovering: undefined }) as never;
        const plain = (await cli(['status'])).stdout;
        assert.match(plain, /\nVault:   none selected\nQueued:  3 files\nJobs: /);
        assert.doesNotMatch(plain, /Problems:|Applies:|Recovery:/);
        assert.ok(plain.endsWith('Runner:  Claude Code (claude-code)\n'));
      } finally {
        core.status = saved;
      }
    });
  });
});
