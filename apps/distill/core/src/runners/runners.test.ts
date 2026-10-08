import assert from 'node:assert/strict';
import path from 'node:path';
import { describe, test } from 'node:test';
import { defaultSettings } from '../store/settings.js';
import { ClaudeCodeRunner } from './claude-code.js';
import { bypassesApproval, gateBreakingReason, suggestedRule, uniqueDenials } from './permissions.js';
import { basePath, isCancelled, runProcess, type RunProcessOptions } from './process.js';
import { createRunnerRegistry } from './registry.js';

describe('runProcess', () => {
  test('writes stdin, drains large stdout and stderr, sets PATH and env', async () => {
    const out = await runProcess({
      executable: '/bin/sh',
      args: ['-c', 'cat; echo "$PATH"; echo "$CLAUDE_OBSIDIAN_VAULT"; head -c 200000 /dev/zero | tr "\\0" e >&2; exit 3'],
      cwd: '/',
      stdin: 'hello\n',
      environment: { CLAUDE_OBSIDIAN_VAULT: '/v' },
    });
    const lines = out.stdout.toString('utf8').split('\n');
    assert.equal(lines[0], 'hello');
    assert.equal(lines[1], `/bin:${basePath()}`, 'dir of the executable, then the base PATH');
    assert.equal(lines[2], '/v');
    assert.equal(out.stderr.length, 200000);
    assert.equal(out.status, 3);
  });

  test('abort terminates the child and rejects as cancelled', async () => {
    const ac = new AbortController();
    const p = runProcess({ executable: '/bin/sh', args: ['-c', 'sleep 30'], cwd: '/', signal: ac.signal });
    setTimeout(() => ac.abort(), 20);
    await assert.rejects(p, (err) => isCancelled(err));
  });

  test('missing executable rejects as launch failure', async () => {
    await assert.rejects(runProcess({ executable: '/nope/claude', args: [], cwd: '/' }), /Could not launch/);
  });
});

describe('ClaudeCodeRunner.run', () => {
  test('maps the request to argv, prompt on stdin, cwd = vault, and parses the envelope', async () => {
    let seen: RunProcessOptions | undefined;
    const runner = new ClaudeCodeRunner(async (opts) => {
      seen = opts;
      const env = JSON.stringify({
        session_id: 's1', result: 'r', is_error: false, total_cost_usd: 0.5,
        structured_output: { status: 'done', summary: 'ok' },
        permission_denials: [{ tool_name: 'Edit', tool_input: { file_path: '/v/wiki/a.md' } }],
      });
      return { status: 0, stdout: Buffer.from(env), stderr: Buffer.alloc(0) };
    });
    const settings = { ...defaultSettings(), claudePath: '/opt/claude/bin/claude' };
    const result = await runner.run(
      {
        workingDirectory: '/v',
        prompt: 'PROMPT',
        session: { start: 'sid' },
        selection: { runnerID: 'claude-code', model: 'haiku', effort: null },
        allowedTools: ['Read', 'Bash(python3 /p/x.py transaction inspect:*)', 'Edit(//a,b/**)'],
        readableDirectories: ['/p'],
        pluginDirectory: '/p',
        outputSchema: '{}',
        systemPrompt: 'SYS',
        environment: { CLAUDE_OBSIDIAN_VAULT: '/v' },
      },
      settings,
    );
    assert.ok(seen);
    assert.equal(seen.executable, '/opt/claude/bin/claude');
    assert.equal(seen.cwd, '/v');
    assert.equal(seen.stdin, 'PROMPT');
    assert.deepEqual(seen.environment, { CLAUDE_OBSIDIAN_VAULT: '/v' });
    assert.deepEqual(seen.args, [
      '-p', '--output-format', 'json', '--model', 'haiku', '--session-id', 'sid',
      '--plugin-dir', '/p', '--add-dir', '/p', '--json-schema', '{}', '--append-system-prompt', 'SYS',
      '--setting-sources', '', '--strict-mcp-config',
      '--allowedTools', 'Read', 'Bash(python3 /p/x.py transaction inspect:*)', 'Edit(//a,b/**)',
    ]);
    assert.equal(result.sessionID, 's1');
    assert.equal(result.costUSD, 0.5);
    assert.deepEqual(result.denials, [{ toolName: 'Edit', input: { file_path: '/v/wiki/a.md' } }]);
    assert.deepEqual(result.structured, { status: 'done', summary: 'ok' });
  });

  test('empty stdout with a non-zero exit is an error with stderr', async () => {
    const runner = new ClaudeCodeRunner(async () => ({ status: 1, stdout: Buffer.alloc(0), stderr: Buffer.from('bad flag') }));
    await assert.rejects(
      runner.run({ workingDirectory: '/v', prompt: '', session: { resume: 's' }, selection: { runnerID: 'claude-code', model: 'm' }, allowedTools: [], readableDirectories: [] }, defaultSettings()),
      /Exited 1: bad flag/,
    );
  });

  test('problems: missing claude binary', () => {
    const r = new ClaudeCodeRunner();
    assert.deepEqual(r.problems({ ...defaultSettings(), claudePath: '/nope/claude' }).map((p) => p.code), ['missingClaude']);
    assert.deepEqual(r.problems({ ...defaultSettings(), claudePath: '/bin/sh' }), []);
  });

  test('resumeCommand', () => {
    const s = { ...defaultSettings(), claudePath: '/c', productRoot: '/p' };
    assert.deepEqual(new ClaudeCodeRunner().resumeCommand('sid', 'opus', s), ['/c', '--resume', 'sid', '--plugin-dir', '/p', '--model', 'opus']);
  });
});

describe('RunnerRegistry', () => {
  test('candidates lists only enabled runners that support the task', () => {
    const reg = createRunnerRegistry([new ClaudeCodeRunner()]);
    const s = defaultSettings();
    assert.deepEqual(reg.candidates('ingest', s).map((r) => r.id), ['claude-code']);
    assert.deepEqual(reg.candidates('ingest', { ...s, enabledRunners: [] }), []);
    assert.equal(reg.get('nope'), undefined);
  });
});

describe('permission denials', () => {
  test('rules per tool', () => {
    assert.equal(suggestedRule({ toolName: 'Bash', input: { command: 'cd /x' } }), undefined);
    assert.equal(suggestedRule({ toolName: 'Bash', input: { command: 'cat a | wc' } }), undefined);
    assert.equal(suggestedRule({ toolName: 'MultiEdit', input: { file_path: '/v/a.md' } }), 'Edit(//v/a.md)');
    assert.equal(suggestedRule({ toolName: 'WebFetch', input: { url: 'https://example.com/a' } }), 'WebFetch(domain:example.com)');
    assert.equal(suggestedRule({ toolName: 'WebFetch', input: { url: 'not a url' } }), undefined);
    assert.equal(suggestedRule({ toolName: 'Glob', input: {} }), 'Glob');
  });

  test('bypassesApproval: Bash and Edit outside the job dir', () => {
    assert.equal(bypassesApproval({ toolName: 'Bash', input: { command: 'ls' } }), true);
    assert.equal(bypassesApproval({ toolName: 'Write', input: { file_path: '/v/wiki/a.md' } }), true);
    assert.equal(bypassesApproval({ toolName: 'Write', input: { file_path: path.join('/v/.vault-meta/worker/j/x.md') } }), false);
    assert.equal(bypassesApproval({ toolName: 'Read', input: { file_path: '/etc/hosts' } }), false);
    // `..` no longer slips past the substring test.
    assert.equal(bypassesApproval({ toolName: 'Write', input: { file_path: '/v/.vault-meta/worker/j/../../../wiki/a.md' } }), true);
    // With the job known: only this job's folder.
    const ctx = { coreCommand: 'python3 /p/scripts/claude-obsidian.py', corePath: '/p/scripts/claude-obsidian.py', stateDirectory: '/v/.vault-meta/worker/j' };
    assert.equal(bypassesApproval({ toolName: 'Write', input: { file_path: '/v/.vault-meta/worker/j/x.md' } }, ctx), false);
    assert.equal(bypassesApproval({ toolName: 'Write', input: { file_path: '/v/.vault-meta/worker/other/x.md' } }, ctx), true);
    assert.equal(bypassesApproval({ toolName: 'Bash', input: { command: 'ls' } }, ctx), true);
  });

  test('gateBreakingReason: one classifier for planningTools, allow() and the warning', () => {
    const ctx = { coreCommand: "python3 '/p q/scripts/claude-obsidian.py'", corePath: '/p q/scripts/claude-obsidian.py', stateDirectory: '/v/.vault-meta/worker/j' };
    const breaking = [
      'Bash', 'Bash()', 'Bash(*)', 'Bash(:*)', 'Bash(*foo)',
      'Bash(python3:*)', 'Bash(python3 *)', 'Bash(/usr/bin/python3:*)', 'Bash(p*)', "Bash(python3 '/p q/scripts/claude-obsidian.py':*)",
      "Bash(python3 '/p q/scripts/claude-obsidian.py' transaction  apply b --vault v)", "Bash(x transaction 'apply' y)",
      'Bash(sh:*)', 'Bash(bash -c x)', 'Bash(zsh:*)', 'Bash(env FOO=1:*)', 'Bash(/usr/bin/env:*)', 'Bash(xargs:*)', 'Bash(eval x)',
      'Edit', 'Write', 'MultiEdit()', 'NotebookEdit', 'Edit(wiki/**)', 'Edit(/v/.vault-meta/worker/j/**)', 'Edit(~/x)',
      'Edit(//v/wiki/**)', 'Edit(//v/.vault-meta/worker/j/../../../wiki/**)', 'Edit(//v/.vault-meta/worker/other/**)',
      'Edit(//v/.vault-meta/worker/j/*/x)', 'Edit(//v/.vault-meta/worker/j/**/x)', 'Write(//v/wiki/a.md)', 'Edit(//v/.vault-meta/worker/jj/**)',
      'not a rule(',
    ];
    for (const r of breaking) assert.ok(gateBreakingReason(r, ctx), r);
    const fine = [
      'Read', 'Read(//etc/**)', 'Glob', 'Grep', 'Skill', 'WebFetch(domain:example.com)',
      'Bash(ls /tmp)', 'Bash(shasum -a 256:*)', "Bash(python3 '/p q/scripts/claude-obsidian.py' transaction inspect:*)",
      "Bash(python3 '/p q/scripts/claude-obsidian.py' lint:*)",
      'Edit(//v/.vault-meta/worker/j/**)', 'Edit(//v/.vault-meta/worker/j)', 'Edit(//v/.vault-meta/worker/j/drafts/a.md)', 'Write(//v/.vault-meta/worker/j/*)',
    ];
    for (const r of fine) assert.equal(gateBreakingReason(r, ctx), undefined, r);
  });

  test('uniqueDenials dedupes by deep equality regardless of key order', () => {
    const a = { toolName: 'Edit', input: { file_path: '/a', old_string: 'x' } };
    const b = { toolName: 'Edit', input: { old_string: 'x', file_path: '/a' } };
    assert.equal(uniqueDenials([a, b, { toolName: 'Edit', input: { file_path: '/b' } }]).length, 2);
  });
});
