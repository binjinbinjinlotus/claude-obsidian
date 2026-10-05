import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { RunRequest, RunnerStep, Settings } from '../contracts.js';
import { claudeArguments, claudeStreamSteps, ClaudeCodeRunner, parseClaudeJSON, parseClaudeStream } from './claude-code.js';
import { codexStepReader } from './codex.js';
import { LineSplitter, type ProcessOutput, type RunProcessOptions } from './process.js';

// The shape `claude -p --output-format stream-json --verbose --json-schema …` printed (2.x, 2026-10-05).
const STREAM = [
  { type: 'system', subtype: 'init', session_id: 's-1', tools: ['Read', 'StructuredOutput'] },
  { type: 'assistant', message: { content: [{ type: 'thinking', thinking: '' }] }, parent_tool_use_id: null, session_id: 's-1' },
  { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'toolu_1', name: 'Read', input: { file_path: '/v/inbox/a.md' } }] }, parent_tool_use_id: null },
  { type: 'user', message: { content: [{ tool_use_id: 'toolu_1', type: 'tool_result', content: '1\thello tea\n' }] }, parent_tool_use_id: null },
  { type: 'assistant', message: { content: [{ type: 'text', text: 'Reading the first source.' }] }, parent_tool_use_id: null },
  { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'toolu_x', name: 'Read', input: { file_path: '/v/b.md' } }] }, parent_tool_use_id: 'toolu_task' },
  { type: 'rate_limit_event', rate_limit_info: { status: 'allowed' } },
  { type: 'assistant', message: { content: [{ type: 'tool_use', id: 'toolu_2', name: 'StructuredOutput', input: { word: 'hello' } }] }, parent_tool_use_id: null },
  { type: 'user', message: { content: [{ tool_use_id: 'toolu_2', type: 'tool_result', content: 'Structured output provided successfully', is_error: false }] }, parent_tool_use_id: null },
  {
    type: 'result', subtype: 'success', is_error: false, result: '{"word":"hello"}', session_id: 's-1', total_cost_usd: 0.0193,
    permission_denials: [{ tool_name: 'Bash', tool_input: { command: 'git status' } }], structured_output: { word: 'hello' },
  },
].map((o) => JSON.stringify(o));

const ENVELOPE = JSON.stringify({ type: 'result', is_error: false, result: '{"word":"hello"}', session_id: 's-1', total_cost_usd: 0.0193, permission_denials: [{ tool_name: 'Bash', tool_input: { command: 'git status' } }], structured_output: { word: 'hello' } });

function request(onStep?: (s: RunnerStep) => void): RunRequest {
  return {
    workingDirectory: '/v', prompt: 'p', session: { start: 's-1' }, selection: { runnerID: 'claude-code', model: 'haiku' },
    allowedTools: ['Read'], readableDirectories: [], outputSchema: '{"type":"object"}', ...(onStep ? { onStep } : {}),
  };
}

describe('Claude Code stream-json', () => {
  test('streams only when asked; the json envelope stays the default', () => {
    const base = { claudePath: '/c', workingDirectory: '/v', prompt: 'p', session: { start: 's' }, model: 'haiku', allowedTools: [], addDirectories: [], environment: {} };
    assert.deepEqual(claudeArguments(base).slice(0, 5), ['-p', '--output-format', 'json', '--model', 'haiku']);
    assert.deepEqual(claudeArguments({ ...base, stream: true }).slice(0, 6), ['-p', '--output-format', 'stream-json', '--verbose', '--model', 'haiku']);
  });

  test('the result event decodes exactly like the json envelope (structured output, denials, cost, session)', () => {
    const raw = STREAM.join('\n') + '\n';
    const streamed = parseClaudeStream(raw);
    const { raw: _a, ...a } = streamed;
    const { raw: _b, ...b } = parseClaudeJSON(ENVELOPE);
    assert.deepEqual(a, b);
    assert.deepEqual(streamed.structured, { word: 'hello' });
    assert.equal(streamed.raw, raw);
    assert.throws(() => parseClaudeStream(STREAM.slice(0, 3).join('\n')), /Unreadable/);
  });

  test('steps: tool calls, results and text; a subagent’s inner calls are left out', () => {
    const steps = STREAM.flatMap(claudeStreamSteps);
    assert.deepEqual(steps, [
      { kind: 'tool', tool: 'Read', input: { file_path: '/v/inbox/a.md' }, id: 'toolu_1' },
      { kind: 'toolDone', id: 'toolu_1' },
      { kind: 'message', text: 'Reading the first source.' },
      { kind: 'tool', tool: 'StructuredOutput', input: { word: 'hello' }, id: 'toolu_2' },
      { kind: 'toolDone', id: 'toolu_2' },
    ]);
    assert.deepEqual(claudeStreamSteps('not json'), []);
  });

  test('run(): with onStep it streams line by line and returns the same result', async () => {
    const seen: RunProcessOptions[] = [];
    const launch = async (opts: RunProcessOptions): Promise<ProcessOutput> => {
      seen.push(opts);
      const raw = STREAM.join('\n') + '\n';
      // Deliver in odd-sized chunks, as a pipe does.
      const split = new LineSplitter((l) => opts.onStdoutLine?.(l));
      const buf = Buffer.from(raw);
      for (let i = 0; i < buf.length; i += 37) split.push(buf.subarray(i, i + 37));
      split.flush();
      return { status: 0, stdout: buf, stderr: Buffer.alloc(0) };
    };
    const runner = new ClaudeCodeRunner(launch);
    const steps: RunnerStep[] = [];
    const result = await runner.run(request((s) => steps.push(s)), { claudePath: '/c' } as Settings);
    assert.ok(seen[0]!.args.includes('stream-json'));
    assert.deepEqual(result.structured, { word: 'hello' });
    assert.equal(result.sessionID, 's-1');
    assert.equal(result.denials.length, 1);
    assert.equal(steps.length, 5);

    // Without onStep: the envelope, unchanged.
    const plain = new ClaudeCodeRunner(async (opts) => {
      seen.push(opts);
      return { status: 0, stdout: Buffer.from(ENVELOPE), stderr: Buffer.alloc(0) };
    });
    const r2 = await plain.run(request(), { claudePath: '/c' } as Settings);
    assert.ok(seen[1]!.args.includes('json') && !seen[1]!.args.includes('stream-json') && seen[1]!.onStdoutLine === undefined);
    assert.deepEqual(r2.structured, { word: 'hello' });
  });

  test('a throwing step handler never breaks the run', async () => {
    const runner = new ClaudeCodeRunner(async (opts) => {
      for (const l of STREAM) opts.onStdoutLine?.(l);
      return { status: 0, stdout: Buffer.from(STREAM.join('\n')), stderr: Buffer.alloc(0) };
    });
    const r = await runner.run(request(() => {
      throw new Error('boom');
    }), { claudePath: '/c' } as Settings);
    assert.deepEqual(r.structured, { word: 'hello' });
  });
});

describe('Codex --json steps', () => {
  test('commands, file changes and messages, read as they arrive', () => {
    const read = codexStepReader();
    const lines = [
      { type: 'thread.started', thread_id: 't' },
      { type: 'item.started', item: { id: 'i1', type: 'command_execution', command: "bash -lc 'sed -n 1,200p inbox/a.md'", status: 'in_progress' } },
      { type: 'item.completed', item: { id: 'i1', type: 'command_execution', command: "bash -lc 'sed -n 1,200p inbox/a.md'", exit_code: 0, status: 'completed' } },
      { type: 'item.completed', item: { id: 'i2', type: 'command_execution', command: 'false', exit_code: 1, status: 'failed' } },
      { type: 'item.completed', item: { id: 'i3', type: 'file_change', changes: [{ path: '/v/.vault-meta/worker/j/drafts/s1.md', kind: 'add' }, { path: '/v/x', kind: 'update' }] } },
      { type: 'item.completed', item: { id: 'i4', type: 'agent_message', text: 'Reading sources now.' } },
      { type: 'item.completed', item: { id: 'i5', type: 'agent_message', text: '{"status":"needs_approval"}' } },
      { type: 'item.completed', item: { id: 'i6', type: 'reasoning', text: 'thinking' } },
    ].map((o) => JSON.stringify(o));
    assert.deepEqual(lines.flatMap(read), [
      { kind: 'tool', tool: 'Bash', input: { command: "bash -lc 'sed -n 1,200p inbox/a.md'" }, id: 'i1' },
      { kind: 'toolDone', id: 'i1' },
      { kind: 'tool', tool: 'Bash', input: { command: 'false' }, id: 'i2' },
      { kind: 'toolDone', id: 'i2', isError: true },
      { kind: 'tool', tool: 'Write', input: { file_path: '/v/.vault-meta/worker/j/drafts/s1.md', files: 2 }, id: 'i3' },
      { kind: 'toolDone', id: 'i3' },
      { kind: 'message', text: 'Reading sources now.' },
    ]);
  });
});

describe('LineSplitter', () => {
  test('splits across chunks, keeps multi-byte characters whole, flushes the last line', () => {
    const got: string[] = [];
    const s = new LineSplitter((l) => got.push(l));
    const b = Buffer.from('first “line”\r\nsecond\nthird');
    for (let i = 0; i < b.length; i++) s.push(b.subarray(i, i + 1));
    s.flush();
    assert.deepEqual(got, ['first “line”', 'second', 'third']);
  });
});
