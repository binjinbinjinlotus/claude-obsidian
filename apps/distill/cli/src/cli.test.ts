import assert from 'node:assert/strict';
import { spawn } from "node:child_process";
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, describe, it } from 'node:test';
import {
  currentSource,
  createFakeCore,
  ensureToken,
  releaseLock,
  sampleConversation,
  startServer,
  statePaths,
  writeLock,
  type FakeCore,
  type RunningServer,
} from '@distill/core/server';
import { describeScan, HELP, run, type CliIO } from './cli.js';
import { clientName, loaderArgs, type ServerSpawner } from './client.js';

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
  /** The last ask request without the conversationID the CLI picks for a new chat (checked to be a UUID). */
  const newChatAsk = () => {
    const { conversationID, ...rest } = lastCall('ask')?.args[0] as { conversationID?: string };
    assert.match(conversationID ?? '', /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    return rest;
  };

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
      for (const s of [
        'distill ask', 'note add', 'note label', 'distill history', 'history show', 'history rm', '--match any|all',
        '--unconfirmed include|exclude', '--no-suggest', 'status', 'serve', 'plugin install', 'no approve',
        'no confirm-labels command', '"requestID"', '"suggestedLabels"', '"conversations"', '"deleted": true', '"notices"',
        '--json output', 'Exit codes',
      ]) {
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
      assert.deepEqual(newChatAsk(), { question: 'How hot for sencha?', labels: ['tea', 'green'], sources: ['slack'] });
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
    it('a gone session: plain message, nothing asked, exit 1, names --new-session; --new-session sends newSession', async () => {
      const original = core.ask;
      const { CoreError } = await import('@distill/core/contracts');
      core.ask = async (req) => {
        if (!req.newSession) {
          throw new CoreError('session_unavailable', 'This conversation’s AI session isn’t available anymore (Claude Code couldn’t find it). Distill will start a new session to continue.', {
            place: 'conversation', reason: 'notFound', message: 'm', detail: 'No conversation found with session ID: s-1', action: 'ask',
          });
        }
        return original(req);
      };
      try {
        const r = await cli(['ask', 'And gyokuro?', '--conversation', 'conv-7']);
        assert.equal(r.code, 1);
        assert.equal(r.stdout, '');
        assert.match(r.stderr, /isn’t available anymore/);
        assert.match(r.stderr, /run the same command with --new-session/);
        assert.match(r.stderr, /detail: No conversation found/);
        const j = await cli(['ask', 'And gyokuro?', '--conversation', 'conv-7', '--json']);
        const err = JSON.parse(j.stdout).error;
        assert.equal(err.code, 'session_unavailable');
        assert.equal(err.reason, 'notFound');
        const ok = await cli(['ask', 'And gyokuro?', '--conversation', 'conv-7', '--new-session', '--json']);
        assert.equal(ok.code, 0, ok.stderr);
        assert.equal((lastCall('ask')?.args[0] as { newSession?: boolean }).newSession, true);
      } finally {
        core.ask = original;
      }
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
      const id = (lastCall('ask')?.args[0] as { conversationID: string }).conversationID;
      assert.ok(r.stdout.includes(`--conversation ${id}`));
    });
    it('in a terminal: live status line on stderr from progress events; stdout stays the answer', async () => {
      const original = core.ask;
      core.ask = async (req) => {
        const key = `ask:${req.conversationID}`;
        const startedAt = new Date(Date.now() - 5000).toISOString();
        core.emit({ type: 'progress', progress: { key: 'ask:other', kind: 'ask', message: 'Someone else', startedAt } });
        core.emit({ type: 'progress', progress: { key, kind: 'ask', message: 'Reading your notes', startedAt, runnerID: 'claude-code', model: 'haiku' } });
        await new Promise((r) => setTimeout(r, 50));
        core.emit({ type: 'progress', progress: { key, kind: 'ask', message: 'Reading your notes', startedAt, finished: true } });
        return original(req);
      };
      try {
        const r = await cli(['ask', 'q'], { isTTY: true });
        assert.equal(r.code, 0, r.stderr);
        assert.match(r.stderr, /Reading your notes… · claude-code · haiku · 0:0[5-9] · Ctrl-C to stop/);
        assert.ok(!r.stderr.includes('Someone else'));
        assert.ok(r.stderr.endsWith('\r\x1b[2K'), 'the line is cleared');
        assert.ok(!r.stdout.includes('Reading your notes'));
        const j = await cli(['ask', 'q', '--json'], { isTTY: true });
        assert.equal(j.stderr, '', '--json keeps stderr quiet');
        JSON.parse(j.stdout);
      } finally {
        core.ask = original;
      }
      for (let i = 0; i < 50 && core.listenerCount() > 0; i++) await new Promise((r) => setTimeout(r, 10));
      assert.equal(core.listenerCount(), 0, 'the event stream is closed');
    });
    it('Ctrl-C cancels the turn: POST cancel, exit 130, nothing on stdout', async () => {
      const original = core.ask;
      let handler: (() => void) | undefined;
      let removed = false;
      let asked: string | undefined;
      core.ask = async (req) => {
        asked = req.conversationID;
        handler?.();
        for (let i = 0; i < 100 && !core.calls.some((c) => c.method === 'cancelAsk' && c.args[0] === req.conversationID); i++) {
          await new Promise((r) => setTimeout(r, 5));
        }
        const { CoreError } = await import('@distill/core/contracts');
        throw new CoreError('invalid_state', 'Stopped');
      };
      try {
        const onInterrupt = (h: () => void) => {
          handler = h;
          return () => (removed = true);
        };
        const r = await cli(['ask', 'slow', '--json'], { onInterrupt });
        assert.equal(r.code, 130);
        assert.deepEqual(JSON.parse(r.stdout), { error: { code: 'stopped', message: 'Stopped. Your question was not saved.' } });
        assert.ok(asked);
        assert.deepEqual(lastCall('cancelAsk')?.args, [asked]);
        assert.ok(removed, 'the handler is removed');
        const human = await cli(['ask', 'slow'], { onInterrupt });
        assert.equal(human.code, 130);
        assert.match(human.stderr, /Stopping…\n[\s\S]*Stopped\. Your question was not saved\./);
      } finally {
        core.ask = original;
      }
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
      assert.deepEqual(Object.keys(res).sort(), ['notePath', 'queued', 'requestID', 'suggestedLabels']);
      assert.deepEqual(res.suggestedLabels, [
        { name: 'tea', existing: true },
        { name: 'gyokuro', existing: false },
      ]);
      assert.deepEqual(lastCall('addNote')?.args[0], {
        title: 'Gyokuro at 60 °C',
        text: 'Steep 2 min.',
        images: [
          { path: path.join(tmp, 'card.png'), mode: 'extract' },
          { path: path.join(tmp, 'setup.jpg'), mode: 'keep' },
        ],
        source: 'in-person',
        sourceRef: 'with Mei',
        origin: 'cli',
        suggest: 'wait',
      });
    });
    it('--label sends labels without a suggestion; --no-suggest skips it', async () => {
      const r = await cli(['note', 'add', '--title', 'L', '--text', 'x', '--label', '#tea', '--label', 'green', '--label', 'tea', '--json']);
      assert.equal(r.code, 0, r.stdout);
      assert.deepEqual(lastCall('addNote')?.args[0], { title: 'L', text: 'x', origin: 'cli', labels: ['tea', 'green'], suggest: 'none' });
      assert.equal(JSON.parse(r.stdout).suggestedLabels, undefined);
      const human = await cli(['note', 'add', '--title', 'L', '--text', 'x', '--label', 'tea']);
      assert.match(human.stdout, /Labels: tea\n/);
      const ns = await cli(['note', 'add', '--title', 'N', '--text', 'x', '--no-suggest', '--json']);
      assert.equal(ns.code, 0, ns.stdout);
      assert.deepEqual(lastCall('addNote')?.args[0], { title: 'N', text: 'x', origin: 'cli', suggest: 'none' });
      assert.deepEqual(Object.keys(JSON.parse(ns.stdout)).sort(), ['notePath', 'queued', 'requestID']);
      assert.equal((await cli(['note', 'add', '--title', 'E', '--text', 'x', '--label', '#'])).code, 2);
    });
    it('human output prints the request ID, suggestions (new marked) and the exact follow-up command', async () => {
      const r = await cli(['note', 'add', '--title', 'Sug', '--text', 'x']);
      assert.equal(r.code, 0, r.stderr);
      const id = /Request ID: (\S+)/.exec(r.stdout)?.[1];
      assert.ok(id, r.stdout);
      assert.match(r.stdout, /Suggested labels: tea, gyokuro \(new\)\n/);
      assert.ok(r.stdout.includes(`distill note label ${id} --label tea --label gyokuro\n`), r.stdout);
      // The printed command works as-is.
      const follow = await cli(['note', 'label', id!, '--label', 'tea', '--label', 'gyokuro', '--json']);
      assert.equal(follow.code, 0, follow.stdout);
    });
    it('human output reports a suggestion error with a template command', async () => {
      core.suggestError = 'no runner can do labelSuggest';
      try {
        const r = await cli(['note', 'add', '--title', 'Err', '--text', 'x']);
        assert.equal(r.code, 0);
        assert.match(r.stdout, /No label suggestions: no runner can do labelSuggest/);
        assert.match(r.stdout, /Set labels: distill note label req-\d+ --label <label>/);
        const j = JSON.parse((await cli(['note', 'add', '--title', 'Err', '--text', 'x', '--json'])).stdout);
        assert.equal(j.suggestError, 'no runner can do labelSuggest');
      } finally {
        core.suggestError = undefined;
      }
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

  describe('note label', () => {
    it('--json returns {notePath, labels} and calls labelNote with the request ID', async () => {
      const added = JSON.parse((await cli(['note', 'add', '--title', 'To label', '--text', 'x', '--json'])).stdout);
      const r = await cli(['note', 'label', added.requestID, '--label', '#tea', '--label', 'sencha', '--json']);
      assert.equal(r.code, 0, r.stdout);
      assert.deepEqual(JSON.parse(r.stdout), { notePath: added.notePath, labels: ['tea', 'sencha'] });
      assert.deepEqual(lastCall('labelNote')?.args, [added.requestID, ['tea', 'sencha']]);
      const human = await cli(['note', 'label', added.requestID, '--label', 'tea']);
      assert.match(human.stdout, /Labels for .*: tea/);
    });
    it('usage errors: no id, no labels, extra args', async () => {
      assert.equal((await cli(['note', 'label', '--label', 'tea'])).code, 2);
      assert.equal((await cli(['note', 'label', 'req-1'])).code, 2);
      assert.equal((await cli(['note', 'label', 'req-1', 'req-2', '--label', 'x'])).code, 2);
      assert.equal((await cli(['note', 'bogus'])).code, 2);
    });
    it('an unknown or already-ingested request ID exits 1 with the server error', async () => {
      const r = await cli(['note', 'label', 'req-unknown', '--label', 'tea', '--json']);
      assert.equal(r.code, 1);
      assert.equal(JSON.parse(r.stdout).error.code, 'not_found');
      core.failNext('labelNote', Object.assign(new Error('the batch already took this note'), { code: 'invalid_state' }));
      const late = await cli(['note', 'label', 'req-1', '--label', 'tea', '--json']);
      assert.equal(late.code, 1);
      assert.equal(JSON.parse(late.stdout).error.code, 'invalid_state');
    });
  });

  describe('ask filters', () => {
    it('--match and --unconfirmed map to labelMatch/includeUnconfirmed; omitted = server defaults', async () => {
      await cli(['ask', 'q', '--label', 'tea', '--label', 'green', '--match', 'all', '--unconfirmed', 'exclude', '--json']);
      assert.deepEqual(newChatAsk(), { question: 'q', labels: ['tea', 'green'], labelMatch: 'all', includeUnconfirmed: false });
      await cli(['ask', 'q', '--unconfirmed', 'include', '--json']);
      assert.deepEqual(newChatAsk(), { question: 'q', includeUnconfirmed: true });
      await cli(['ask', 'q', '--json']);
      assert.deepEqual(newChatAsk(), { question: 'q' });
      assert.equal((await cli(['ask', 'q', '--match', 'some'])).code, 2);
      assert.equal((await cli(['ask', 'q', '--unconfirmed', 'yes'])).code, 2);
    });
    it('prints notices above the answer and returns them in --json', async () => {
      const notice = 'Started a new session because the filter changed.';
      const original = core.ask;
      core.ask = async (req) => ({ ...(await original(req)), notices: [notice] });
      try {
        const r = await cli(['ask', 'q']);
        assert.ok(r.stdout.startsWith(`Note: ${notice}\n`), r.stdout);
        const j = JSON.parse((await cli(['ask', 'q', '--json'])).stdout);
        assert.deepEqual(j.notices, [notice]);
      } finally {
        core.ask = original;
      }
    });
  });

  describe('history', () => {
    it('lists conversations (--json {conversations}) and human', async () => {
      const r = await cli(['history', '--json']);
      assert.equal(r.code, 0, r.stdout);
      const res = JSON.parse(r.stdout);
      assert.deepEqual(Object.keys(res), ['conversations']);
      assert.deepEqual(Object.keys(res.conversations[0]).sort(), ['createdAt', 'id', 'pinned', 'title', 'turnCount', 'updatedAt', 'vaultPath']);
      assert.equal(lastCall('listConversations')?.method, 'listConversations');
      const human = await cli(['history']);
      assert.match(human.stdout, /conv-1 .*How hot for sencha\?/);
      assert.equal((await cli(['history', 'bogus'])).code, 2);
    });
    it('show prints the turns (--json AskConversation)', async () => {
      const r = await cli(['history', 'show', 'conv-1', '--json']);
      assert.equal(r.code, 0, r.stdout);
      const c = JSON.parse(r.stdout);
      assert.equal(c.id, 'conv-1');
      assert.equal(c.turns[0].request.question, 'How hot for sencha?');
      assert.deepEqual(lastCall('getConversation')?.args, ['conv-1']);
      const human = await cli(['history', 'show', 'conv-1']);
      assert.match(human.stdout, /Q1 .*How hot for sencha\?/);
      assert.match(human.stdout, /\[1\] Sencha/);
      assert.match(human.stdout, /--conversation conv-1/);
      const missing = await cli(['history', 'show', 'conv-x', '--json']);
      assert.equal(missing.code, 1);
      assert.equal(JSON.parse(missing.stdout).error.code, 'conversation_not_found');
      assert.equal((await cli(['history', 'show'])).code, 2);
    });
    it('rm deletes (--json {id, deleted})', async () => {
      core.conversations.push(sampleConversation({ id: 'conv-rm' }));
      const r = await cli(['history', 'rm', 'conv-rm', '--json']);
      assert.equal(r.code, 0, r.stdout);
      assert.deepEqual(JSON.parse(r.stdout), { id: 'conv-rm', deleted: true });
      assert.deepEqual(lastCall('deleteConversation')?.args, ['conv-rm']);
      const again = await cli(['history', 'rm', 'conv-rm']);
      assert.equal(again.code, 1);
    });
  });

  describe('actions', () => {
    it('list: human and --json, with --type and --history', async () => {
      const r = await cli(['actions', 'list']);
      assert.equal(r.code, 0, r.stderr);
      assert.match(r.stdout, /act-1 {2}todo {2}to confirm {2}Book the tasting room for Saturday {2}due 2026-10-04 {2}\(wiki\/sources\/tea.md\)/);
      const j = await cli(['actions', 'list', '--type', 'todo', '--history', '--json']);
      assert.equal(j.code, 0);
      assert.equal(JSON.parse(j.stdout).actions[0].id, 'act-1');
      assert.deepEqual(lastCall('listActions')?.args[0], { type: 'todo', history: true });
    });
    it('add: a to-do by hand (source manual); no confirm command exists', async () => {
      const r = await cli(['actions', 'add', 'Order tasting cups', '--due', '2026-10-09', '--why', 'Club on Saturday', '--json']);
      assert.equal(r.code, 0, r.stderr);
      const item = JSON.parse(r.stdout);
      assert.equal(item.title, 'Order tasting cups');
      assert.deepEqual(lastCall('createAction')?.args[0], { type: 'todo', title: 'Order tasting cups', source: { kind: 'manual', by: 'agent' }, why: 'Club on Saturday', fields: { due: '2026-10-09' } });
      const human = await cli(['actions', 'add', 'Ping Mei', '--type', 'slack']);
      assert.match(human.stdout, /^Added slack act-\d+: Ping Mei\n/);
      assert.equal((await cli(['actions', 'add'])).code, 2);
      assert.equal((await cli(['actions', 'add', 'x', '--due', 'friday'])).code, 2);
      assert.equal((await cli(['actions', 'confirm', 'act-1'])).code, 2);
      assert.equal((await cli(['actions'])).code, 2);
      const help = await cli(['--help']);
      assert.ok(help.stdout.includes('distill actions list'));
      assert.ok(help.stdout.includes('no command to confirm, complete, send or create actions'));
    });
  });

  describe('collectors', () => {
    it('list: human and --json', async () => {
      const r = await cli(['collectors', 'list']);
      assert.equal(r.code, 0, r.stderr);
      assert.match(r.stdout, /^col-1 {2}Distill Inbox {2}Folder \/tmp\/Distill Inbox \(copy\) {2}\[on · 0 \* \* \* \* · next 2026-10-04T10:00:00Z\]\n {4}vault: \/tmp\/vault\n/);
      const j = await cli(['collectors', 'list', '--json']);
      assert.equal(JSON.parse(j.stdout).collectors[0].id, 'col-1');
    });
    it('run: waits for the run and prints it; history lists runs', async () => {
      const r = await cli(['collectors', 'run', 'col-1']);
      assert.equal(r.code, 0, r.stderr);
      assert.equal(r.stdout, '2026-10-04 09:00Z  now  done  · copied 1 · skipped 2 already collected\n');
      assert.deepEqual(lastCall('runCollector')?.args, ['col-1']);
      const j = await cli(['collectors', 'run', 'col-1', '--json']);
      assert.equal(JSON.parse(j.stdout).run.result, 'success');
      const h = await cli(['collectors', 'history', 'col-1', '--limit', '1']);
      assert.equal(h.code, 0, h.stderr);
      assert.equal(h.stdout.split('\n').filter(Boolean).length, 1);
      assert.deepEqual(lastCall('listCollectorRuns')?.args, ['col-1', { limit: 1 }]);
      const hj = await cli(['collectors', 'history', 'col-1', '--json']);
      assert.ok(Array.isArray(JSON.parse(hj.stdout).runs));
    });
    it('usage errors, unknown ids, and no consent command', async () => {
      assert.equal((await cli(['collectors'])).code, 2);
      assert.equal((await cli(['collectors', 'run'])).code, 2);
      assert.equal((await cli(['collectors', 'history', 'col-1', '--limit', '0'])).code, 2);
      assert.equal((await cli(['collectors', 'allow', 'col-1'])).code, 2);
      const missing = await cli(['collectors', 'run', 'col-nope', '--json']);
      assert.equal(missing.code, 1);
      assert.equal(JSON.parse(missing.stdout).error.code, 'not_found');
      const help = await cli(['--help']);
      assert.ok(help.stdout.includes('distill collectors list'));
      assert.ok(help.stdout.includes('never allows (consents to) a collector script'));
    });
  });

  describe('activity and trash', () => {
    it('lists activity with filters turned into query parameters, and says who asked', async () => {
      let seen = '';
      const original = core.listActivity.bind(core);
      core.listActivity = async (q) => {
        seen = currentSource();
        return original(q);
      };
      try {
        const r = await cli(['activity', '--type', 'collector', '--type', 'chat.deleted', '--source', 'app', '--search', 'meeting', '--failed', '--limit', '5', '--object', 'col-2']);
        assert.equal(r.code, 0, r.stderr);
        const q = lastCall('listActivity')?.args[0] as Record<string, unknown>;
        assert.deepEqual(q.types, ['collector', 'chat.deleted']);
        assert.deepEqual(q.sources, ['app']);
        assert.equal(q.text, 'meeting');
        assert.equal(q.outcome, 'failed');
        assert.equal(q.limit, 5);
        assert.equal(q.objectID, 'col-2');
        assert.equal(seen, 'cli');
        const agent = await cli(['activity'], { env: { HOME: path.join(tmp, 'home'), DISTILL_STATE_DIR: stateDir, CLAUDECODE: '1' } });
        assert.equal(agent.code, 0);
        assert.equal(seen, 'agent');
      } finally {
        core.listActivity = original;
      }
    });

    it('prints entries with their recovery path, and JSON', async () => {
      const r = await cli(['activity']);
      assert.equal(r.code, 0);
      assert.match(r.stdout, /Deleted the script collector “Meeting notes”  \[collector\.deleted\]/);
      assert.match(r.stdout, /kept in Distill's trash until 2026-11-0\d: distill trash restore trash-1791155040000-0a1b2c3d/);
      const j = await cli(['activity', '--json']);
      const page = JSON.parse(j.stdout);
      assert.equal(page.entries[0].type, 'collector.deleted');
      assert.equal(page.nextCursor, null);
    });

    it('--since takes an age or a date; bad values are usage errors', async () => {
      await cli(['activity', '--since', '24h']);
      const since = (lastCall('listActivity')?.args[0] as { since: string }).since;
      assert.ok(Math.abs(Date.parse(since) - (Date.now() - 86_400_000)) < 60_000);
      assert.equal((await cli(['activity', '--since', 'soonish'])).code, 2);
      assert.equal((await cli(['activity', '--limit', '0'])).code, 2);
    });

    it('trash lists items; restore refuses collectors (the app restores those) and restores chats', async () => {
      const list = await cli(['trash']);
      assert.equal(list.code, 0);
      assert.match(list.stdout, /trash-1791155040000-0a1b2c3d  collector  “Meeting notes”/);
      const refused = await cli(['trash', 'restore', 'trash-1791155040000-0a1b2c3d', '--json']);
      assert.equal(refused.code, 1);
      assert.equal(JSON.parse(refused.stdout).error.code, 'use_app');
      assert.equal(lastCall('restoreFromTrash'), undefined);
      core.trash.push({ ...core.trash[0]!, id: 'trash-1791155040001-0a1b2c3e', kind: 'chat', objectID: 'chat-1', name: 'Sencha' });
      const ok = await cli(['trash', 'restore', 'trash-1791155040001-0a1b2c3e']);
      assert.equal(ok.code, 0, ok.stderr);
      assert.match(ok.stdout, /Restored the chat “Sencha”/);
      assert.equal((await cli(['trash', 'restore', 'trash-0000000000000-00000000'])).code, 1);
    });

    it('clientName: DISTILL_CLIENT wins, agents are detected, else cli', () => {
      assert.equal(clientName({}), 'cli');
      assert.equal(clientName({ CLAUDECODE: '1' }), 'agent');
      assert.equal(clientName({ CODEX_SANDBOX: 'seatbelt' }), 'agent');
      assert.equal(clientName({ CLAUDECODE: '1', DISTILL_CLIENT: 'cli' }), 'cli');
      assert.equal(clientName({ DISTILL_CLIENT: 'plugin' }), 'agent');
    });
  });

  describe('queue scan', () => {
    it('scans now (sync is the same command) and prints what changed; --json is the scan result', async () => {
      const r = await cli(['queue', 'scan']);
      assert.equal(r.code, 0, r.stderr);
      assert.match(r.stdout, /^Nothing new\n\d+ items? in the queue\n$/);
      assert.deepEqual(lastCall('scanQueue')?.args, [{ trigger: 'manual' }]);
      const j = await cli(['queue', 'sync', '--json']);
      assert.equal(j.code, 0, j.stderr);
      const res = JSON.parse(j.stdout);
      assert.deepEqual([res.added, res.removed, res.changed, res.trigger], [0, 0, 0, 'manual']);
      assert.equal((await cli(['queue'])).code, 2);
      assert.equal((await cli(['queue', 'scan', 'extra'])).code, 2);
      assert.ok((await cli(['--help'])).stdout.includes('distill queue scan'));
    });
    it('describeScan words changes like Refresh', () => {
      const entry = (name: string, kind?: 'folder') => ({ path: `/q/${name}`, name, modified: '', size: 1, settled: true, ...(kind ? { kind } : {}) });
      const text = describeScan({
        added: 2, removed: 1, changed: 0, checkedAt: '', trigger: 'manual',
        addedEntries: [entry('Trip', 'folder'), entry('a.md')], removedEntries: [entry('old.md')], changedEntries: [],
        entries: [entry('Trip', 'folder'), entry('a.md')],
      });
      assert.equal(text, '2 new items found · 1 item gone\n  + Trip/\n  + a.md\n  - old.md\n2 items in the queue');
    });
  });

  describe('batch reread', () => {
    it('--job sends the job id; files go as given; --per-batch and --instruction pass through', async () => {
      const r = await cli(['batch', 'reread', '--job', 'job-20261001-120000-abcd']);
      assert.equal(r.code, 0, r.stderr);
      assert.deepEqual(lastCall('rereadSources')?.args, [{ jobId: 'job-20261001-120000-abcd' }]);
      assert.match(r.stdout, /^Re-reading 1 source from job-20261001-120000-abcd in 1 batch of up to 3 \(reread-/);
      assert.match(r.stdout, /1\. started as job-reread-1: a\.md/);
      assert.match(r.stdout, /nothing is applied until you approve it/);

      const j = await cli(['batch', 'reread', 'inbox/a.md', './inbox/b.md', 'inbox/c.md', 'inbox/d.md', '--per-batch', '2', '--instruction', 'Keep owners.', '--json']);
      assert.equal(j.code, 0, j.stderr);
      assert.deepEqual(lastCall('rereadSources')?.args, [{ files: ['inbox/a.md', 'inbox/b.md', 'inbox/c.md', 'inbox/d.md'], perBatch: 2, instruction: 'Keep owners.' }]);
      const res = JSON.parse(j.stdout);
      assert.deepEqual(res.groups.map((g: { files: string[] }) => g.files.length), [2, 2]);
      assert.equal(res.waiting, 1);
      assert.equal(res.started[0].reread.group, 1);
    });
    it('usage errors: both or neither, bad --per-batch, unknown sub-command', async () => {
      assert.equal((await cli(['batch', 'reread'])).code, 2);
      assert.equal((await cli(['batch', 'reread', 'inbox/a.md', '--job', 'j'])).code, 2);
      assert.equal((await cli(['batch', 'reread', 'inbox/a.md', '--per-batch', '0'])).code, 2);
      assert.equal((await cli(['batch', 'reread', 'inbox/a.md', '--per-batch', '11'])).code, 2);
      assert.equal((await cli(['batch', 'run'])).code, 2);
      assert.ok((await cli(['--help'])).stdout.includes('distill batch reread'));
    });
    it('an unknown job is refused by the route', async () => {
      const unknown = await cli(['batch', 'reread', '--job', 'job-nope', '--json']);
      assert.equal(unknown.code, 1);
      assert.equal(JSON.parse(unknown.stdout).error.code, 'job_not_found');
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
