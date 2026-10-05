import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { decodeRun } from './store.js';
import { OrderedTail, startProcess } from './script.js';

describe('ordered output log (v7)', () => {
  test('keeps both streams in order; one stream within a second joins its chunk', () => {
    let t = Date.parse('2026-10-05T10:14:01.100Z');
    const tail = new OrderedTail(64, () => new Date(t));
    tail.push('stdout', Buffer.from('a\n'));
    tail.push('stdout', Buffer.from('b\n'));
    tail.push('stderr', Buffer.from('oops\n'));
    t += 1000;
    tail.push('stdout', Buffer.from('c\n'));
    assert.deepEqual(tail.chunksCopy(), [
      { stream: 'stdout', text: 'a\nb\n', at: '2026-10-05T10:14:01.100Z' },
      { stream: 'stderr', text: 'oops\n', at: '2026-10-05T10:14:01.100Z' },
      { stream: 'stdout', text: 'c\n', at: '2026-10-05T10:14:02.100Z' },
    ]);
  });

  test('bounded: the oldest output goes first, a split character never shows', () => {
    let t = 0;
    const tail = new OrderedTail(10, () => new Date((t += 2000)));
    tail.push('stdout', Buffer.from('0123456789'));
    tail.push('stderr', Buffer.from('ab'));
    tail.push('stdout', Buffer.from('“xy'));
    const chunks = tail.chunksCopy();
    const total = chunks.reduce((n, c) => n + Buffer.byteLength(c.text), 0);
    assert.ok(total <= 10, `kept ${total} bytes`);
    assert.equal(chunks.at(-1)!.text, '“xy');
    assert.ok(!chunks.some((c) => c.text.includes('�')));
  });

  test('a real process: stdout and stderr interleaved as printed', async () => {
    const h = startProcess({
      command: '/bin/sh',
      args: ['-c', 'echo one; sleep 0.05; echo two >&2; sleep 0.05; echo three'],
      cwd: '/tmp',
      env: { PATH: '/usr/bin:/bin' },
      timeoutMs: 5000,
    });
    const o = await h.done;
    assert.deepEqual(o.outputLog.map((c) => [c.stream, c.text]), [['stdout', 'one\n'], ['stderr', 'two\n'], ['stdout', 'three\n']]);
  });

  test('a saved run keeps its output log; a bad chunk is dropped', () => {
    const run = decodeRun({
      id: 'run-1', collectorId: 'c', kind: 'script', vaultPath: '/v', trigger: 'now', startedAt: '2026-10-05T10:14:01Z', result: 'success',
      counts: {}, filesAdded: [],
      outputLog: [{ stream: 'stdout', text: 'hi\n', at: '2026-10-05T10:14:01Z' }, { stream: 'other', text: 'x', at: 'y' }],
    });
    assert.deepEqual(run?.outputLog, [{ stream: 'stdout', text: 'hi\n', at: '2026-10-05T10:14:01Z' }]);
  });
});
