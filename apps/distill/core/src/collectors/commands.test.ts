import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, test } from 'node:test';
import type { ScriptCommand } from '../contracts.js';
import { approvalHash, buildArgv, displayArgv, maskSecrets, parseResult, placeholdersIn, renderArg } from './commands.js';

/** The Slack CLI's send, as declared in action-buttons.md. */
const SEND: ScriptCommand = {
  id: 'send',
  label: 'Send a message',
  args: [
    { name: 'send', kind: 'word', value: 'send' },
    { name: 'thread', kind: 'flag', flag: '--thread' },
    { name: 'target', kind: 'positional', pattern: '^(#\\S+|@\\S+|[CGDUW][A-Z0-9]+)$', hint: '#channel, @handle or an ID' },
    { name: 'text', kind: 'positional' },
  ],
  result: { keyPattern: 'ts ([0-9]+\\.[0-9]+)\\)' },
};
const BIND = { target: '{fields.to}', text: '{body}', thread: '' };

describe('templates (action-buttons.md safety contract)', () => {
  test('one template is one element, byte for byte, in a single pass', () => {
    const body = `Hi "Mei" it's $(touch /tmp/x) \`id\`; a | b\nline 2 🍵 {title}`;
    const out = buildArgv(SEND, BIND, { 'fields.to': '@mei', body, title: 'T' });
    assert.deepEqual(out.problems, []);
    assert.deepEqual(out.args, ['send', '--', '@mei', body]);
  });

  test('an unknown placeholder is an error, never left as typed', () => {
    assert.throws(() => renderArg('{fields.channel}', { 'fields.to': 'x' }), /isn’t a field/);
    const out = buildArgv(SEND, { ...BIND, target: '{fields.channel}' }, { 'fields.to': '@m', body: 'b' });
    assert.match(out.problems[0]!, /^target: \{fields.channel\}/);
  });

  test('{{ and }} are literal braces', () => {
    assert.equal(renderArg('{{x}} {title}', { title: 'T' }), '{x} T');
    assert.deepEqual(placeholdersIn('{{x}} {title} {fields.to}'), ['title', 'fields.to']);
  });

  test('empty: a required value is a problem; an optional flag is left out with its flag; a switch needs on', () => {
    assert.match(buildArgv(SEND, BIND, { 'fields.to': '@m', body: '' }).problems[0]!, /text: needs a value/);
    assert.deepEqual(buildArgv(SEND, { ...BIND, thread: '{x}' }, { 'fields.to': '@m', body: 'b', x: '' }).args, ['send', '--', '@m', 'b']);
    assert.deepEqual(buildArgv(SEND, { ...BIND, thread: '1.2' }, { 'fields.to': '@m', body: 'b' }).args, ['send', '--thread', '1.2', '--', '@m', 'b']);
    const sw: ScriptCommand = { id: 'u', label: 'u', args: [{ name: 'all', kind: 'switch', flag: '--all' }] };
    assert.deepEqual(buildArgv(sw, { all: 'yes' }, {}).args, ['--all']);
    assert.deepEqual(buildArgv(sw, { all: 'no' }, {}).args, []);
  });

  test('a pattern miss names the hint; NUL and huge values are refused', () => {
    assert.match(buildArgv(SEND, BIND, { 'fields.to': 'Mei Tanaka', body: 'b' }).problems[0]!, /“Mei Tanaka” isn’t #channel, @handle or an ID/);
    assert.match(buildArgv(SEND, BIND, { 'fields.to': '@m', body: 'a\u0000b' }).problems[0]!, /NUL/);
    assert.match(buildArgv(SEND, BIND, { 'fields.to': '@m', body: 'x'.repeat(100 * 1024 + 1) }).problems[0]!, /too long/);
  });

  test('a body starting with - stays text after --; endOptions off leaves it out', () => {
    assert.deepEqual(buildArgv(SEND, BIND, { 'fields.to': '@m', body: '--done' }).args, ['send', '--', '@m', '--done']);
    assert.deepEqual(buildArgv({ ...SEND, endOptions: false }, BIND, { 'fields.to': '@m', body: 'b' }).args, ['send', '@m', 'b']);
  });

  test('the argv reaches a real process unchanged, with no shell', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-cmd-'));
    const marker = path.join(dir, 'pwned');
    const body = `$(touch ${marker}) \`touch ${marker}\`; touch ${marker} | x "q" 'q'`;
    const { args } = buildArgv(SEND, BIND, { 'fields.to': '@m', body });
    const echo = path.join(dir, 'echo.py');
    fs.writeFileSync(echo, 'import json,sys\nprint(json.dumps(sys.argv[1:]))\n');
    const out = execFileSync('python3', [echo, ...args]).toString();
    assert.deepEqual(JSON.parse(out), args);
    assert.equal(fs.existsSync(marker), false, 'nothing in the text ran');
    fs.rmSync(dir, { recursive: true, force: true });
  });
});

describe('results, approval and display', () => {
  test('a key from a regex; a JSON line wins; the last line is the message', () => {
    const r = parseResult('connecting\nsent to #general (channel, ts 1759600000.123456)\n', SEND.result);
    assert.equal(r.key, '1759600000.123456');
    assert.equal(r.message, 'sent to #general (channel, ts 1759600000.123456)');
    const j = parseResult('x\n{"key":"PX-1","url":"https://j/PX-1","message":"created"}\n', { json: true });
    assert.deepEqual(j, { key: 'PX-1', url: 'https://j/PX-1', message: 'created' });
    assert.deepEqual(parseResult('', undefined), {});
  });

  test('the approval changes with the script, the command or the mapping', () => {
    const b = { bindings: BIND, scriptId: 'col-1', commandId: 'send' };
    const h = approvalHash('s1', SEND, b);
    assert.equal(approvalHash('s1', SEND, { ...b, bindings: { thread: '', text: '{body}', target: '{fields.to}' } }), h, 'key order does not matter');
    assert.notEqual(approvalHash('s2', SEND, b), h);
    assert.notEqual(approvalHash('s1', { ...SEND, endOptions: false }, b), h);
    assert.notEqual(approvalHash('s1', SEND, { ...b, bindings: { ...BIND, text: '{title}' } }), h);
  });

  test('display quotes for reading; secrets are masked', () => {
    assert.equal(displayArgv(['python3', 'a b', "it's", '@m']), `python3 'a b' 'it'\\''s' @m`);
    assert.equal(maskSecrets('token xoxb-123-abc and Bearer abc.def https://u:p@h/x'), 'token xox*-*** and Bearer *** https://***@h/x');
  });
});
