import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { capturedPath, stableSourceId } from './archive.js';
import { estimateTokens, makeReadingCopy, MAX_LINE, planSections } from './copy.js';
import { computeCoverage, continuationPrompt, mergeRanges, newRecord, partialWording, readsFor, subtractRanges } from './coverage.js';
import { parseTurn } from './stream.js';
import { batchBudget, contextWindowFor, ModelWindows } from './store.js';

let tmp: string;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-coverage-')));
  fs.mkdirSync(path.join(tmp, 'vault', 'inbox'), { recursive: true });
});
afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

const vault = () => path.join(tmp, 'vault');
function write(rel: string, data: string | Buffer): void {
  fs.mkdirSync(path.dirname(path.join(vault(), rel)), { recursive: true });
  fs.writeFileSync(path.join(vault(), rel), data);
}

/** One stream-json Read: the call and its result with the span the tool returned. */
function readLines(id: string, file: string, from: number, count: number, total: number, o: { cut?: boolean; usage?: number; parent?: boolean; error?: boolean; meta?: boolean } = {}): string[] {
  const call = { type: 'assistant', ...(o.parent ? { parent_tool_use_id: 'task-1' } : {}), message: { content: [{ type: 'tool_use', id, name: 'Read', input: { file_path: file, offset: from, limit: count } }], usage: { input_tokens: 10, cache_read_input_tokens: o.usage ?? 1000, cache_creation_input_tokens: 0 } } };
  const text = Array.from({ length: count }, (_, i) => `${String(from + i).padStart(6)}→line`).join('\n');
  const result = {
    type: 'user',
    ...(o.parent ? { parent_tool_use_id: 'task-1' } : {}),
    message: { content: [{ type: 'tool_result', tool_use_id: id, content: text, ...(o.error ? { is_error: true } : {}) }] },
    ...(o.meta === false ? {} : { tool_use_result: { type: 'text', file: { filePath: file, startLine: from, numLines: count, totalLines: total }, ...(o.cut ? { truncatedByTokenCap: true } : {}) } }),
  };
  return [JSON.stringify(call), JSON.stringify(result)];
}

describe('the reading copy', () => {
  test('copy line n is source line n: an image is one placeholder; a long line is split after the last line', () => {
    const long = 'x'.repeat(MAX_LINE + 500);
    const img = `[image1]: <data:image/png;base64,${'A'.repeat(90_000)}>`;
    write('inbox/a.md', ['# Notes', 'para', long, 'end', img].join('\n') + '\n');
    const c = makeReadingCopy(vault(), 'inbox/a.md', path.join(tmp, 'job'), 1);
    assert.equal(c.unreadable, undefined);
    const lines = fs.readFileSync(c.copy!, 'utf8').split('\n');
    assert.equal(lines[0], '# Notes');
    assert.equal(lines[2]!.endsWith('→ L3↪'), true);
    assert.equal(lines[3], 'end');
    assert.match(lines[4]!, /^\[image1: embedded PNG, \d+ KB, not text\]$/);
    assert.equal(lines[5], `L3↪ ${'x'.repeat(500)}`);
    assert.equal(c.sourceLines, 5);
    assert.equal(c.lines, 6);
    assert.equal(c.imageLines, 1);
    assert.equal(c.longLines, 1);
    // The 90 KB image is not text: the estimate is the copy's.
    assert.ok(c.estTokens < 2000);
  });

  test('a file that is not UTF-8 text is unreadable, decided by the core, with the line', () => {
    write('inbox/bad.md', Buffer.concat([Buffer.from('ok\nfine\n'), Buffer.from([0xff, 0xfe, 0x41]), Buffer.from('\n')]));
    const c = makeReadingCopy(vault(), 'inbox/bad.md', path.join(tmp, 'job'), 1);
    assert.equal(c.unreadable, 'it isn’t valid UTF-8 text from line 3');
    assert.equal(c.copy, undefined);
    write('inbox/nul.txt', 'a\nb\u0000c\n');
    assert.match(makeReadingCopy(vault(), 'inbox/nul.txt', path.join(tmp, 'job'), 2).unreadable!, /NUL byte on line 2/);
    write('inbox/empty.md', '\n\n');
    assert.equal(makeReadingCopy(vault(), 'inbox/empty.md', path.join(tmp, 'job'), 3).unreadable, 'it has no text in it');
  });

  test('sections: at most 400 lines, broken at headings or blank lines', () => {
    const lines = Array.from({ length: 1000 }, (_, i) => (i % 50 === 0 ? `### **00:${String(i % 60).padStart(2, '0')}:00**` : `line ${i}`));
    const s = planSections(lines);
    assert.ok(s.every((x) => x.to - x.from + 1 <= 400));
    assert.equal(s[0]!.from, 1);
    assert.equal(s.at(-1)!.to, 1000);
    for (let i = 1; i < s.length; i++) assert.equal(s[i]!.from, s[i - 1]!.to + 1);
  });

  test('the token estimate leaves embedded images out', () => {
    write('inbox/img.md', `text\n[image1]: <data:image/png;base64,${'A'.repeat(260_000)}>\n`);
    assert.ok(estimateTokens(path.join(vault(), 'inbox/img.md')) < 100);
  });
});

describe('what a turn read, from stream-json', () => {
  test('credits the lines the tool returned, not the lines asked for; errors and subagents credit nothing', () => {
    const raw = [
      ...readLines('r1', '/v/inbox/a.md', 1, 139, 644, { cut: true }),
      ...readLines('r2', '/v/inbox/b.md', 1, 50, 50, { error: true }),
      ...readLines('r3', '/v/inbox/c.md', 1, 50, 50, { parent: true }),
      ...readLines('r4', '/v/inbox/d.md', 10, 5, 100, { meta: false }),
    ].join('\n');
    const p = parseTurn(raw);
    const reads = p.events.filter((e) => e.t === 'read');
    assert.deepEqual(reads.map((r) => (r.t === 'read' ? [r.path, r.from, r.to, r.cut ?? false] : [])), [
      ['/v/inbox/a.md', 1, 139, true],
      ['/v/inbox/d.md', 10, 14, false],
    ]);
  });

  test('a compaction: a compact_boundary event, or the context under 60% of the message before (no-usage and subagent messages skipped)', () => {
    const msg = (ctx: number, parent = false) => JSON.stringify({ type: 'assistant', ...(parent ? { parent_tool_use_id: 'x' } : {}), message: { content: [], usage: { input_tokens: 0, cache_read_input_tokens: ctx, cache_creation_input_tokens: 0 } } });
    const p = parseTurn([msg(100_000), msg(0), msg(10_000, true), msg(99_000), msg(2_000)].join('\n'));
    assert.equal(p.events.filter((e) => e.t === 'compact').length, 1);
    assert.equal(p.lastContext, 2_000);
    // Across turns: the next turn compares with the last context of this one.
    const next = parseTurn(msg(1_900), p.nextSeq, p.lastContext);
    assert.equal(next.events.length, 0);
    const boundary = parseTurn(JSON.stringify({ type: 'system', subtype: 'compact_boundary' }));
    assert.equal(boundary.events[0]?.t, 'compact');
    const windows = parseTurn(JSON.stringify({ type: 'result', modelUsage: { 'claude-sonnet-5-5': { contextWindow: 1_000_000 } } }));
    assert.deepEqual(windows.contextWindows, { 'claude-sonnet-5-5': 1_000_000 });
  });
});

describe('coverage', () => {
  test('ranges', () => {
    assert.deepEqual(mergeRanges([[5, 9], [1, 3], [4, 4], [20, 30]]), [[1, 9], [20, 30]]);
    assert.deepEqual(subtractRanges([[1, 100]], [[1, 10], [50, 60]]), [[11, 49], [61, 100]]);
    assert.deepEqual(readsFor([[1, 900]], [{ from: 1, to: 300 }, { from: 301, to: 700 }, { from: 701, to: 900 }]), [[1, 300], [301, 700], [701, 900]]);
  });

  test('a source is read in full only when every non-image line came back; the owner’s 139-of-644 read is not', () => {
    const lines = Array.from({ length: 643 }, (_, i) => `line ${i + 1}`);
    write('inbox/aidr.md', [...lines, `[image1]: <data:image/png;base64,${'A'.repeat(80_000)}>`].join('\n') + '\n');
    const c = makeReadingCopy(vault(), 'inbox/aidr.md', path.join(tmp, 'job'), 1);
    const r = newRecord('s', [c]);
    r.events = parseTurn(readLines('r1', c.copy!, 1, 139, 644, { cut: true }).join('\n')).events;
    let cov = computeCoverage(r, { vaultPath: vault() });
    assert.equal(cov[0]!.full, false);
    assert.deepEqual(cov[0]!.missing, [[140, 643]]);
    const prompt = continuationPrompt(r, cov, '/job/bundle.json', vault());
    assert.match(prompt, /lines 140–643/);
    assert.match(prompt, /Read offset 140 limit/);
    r.events.push(...parseTurn(readLines('r2', c.copy!, 140, 504, 644).join('\n'), 10).events);
    cov = computeCoverage(r, { vaultPath: vault() });
    // Line 644 is the image placeholder: never required.
    assert.equal(cov[0]!.full, true);
    assert.equal(cov[0]!.required, 643);
  });

  test('after a compaction, a read counts only when a later write of its page draft follows it', () => {
    write('inbox/a.md', Array.from({ length: 10 }, (_, i) => `l${i}`).join('\n') + '\n');
    const c = makeReadingCopy(vault(), 'inbox/a.md', path.join(tmp, 'job'), 1);
    const r = newRecord('s', [c]);
    r.events = [
      { t: 'read', seq: 1, path: c.copy!, from: 1, to: 10 },
      { t: 'compact', seq: 2 },
    ];
    const drafts = new Map([[path.join(tmp, 'job', 'a.md'), 'inbox/a.md']]);
    assert.equal(computeCoverage(r, { vaultPath: vault(), drafts })[0]!.full, false);
    r.events.splice(1, 0, { t: 'write', seq: 1.5, path: path.join(tmp, 'job', 'a.md') });
    assert.equal(computeCoverage(r, { vaultPath: vault(), drafts })[0]!.full, true);
    // No compaction: order doesn't matter.
    r.events = [{ t: 'read', seq: 1, path: c.copy!, from: 1, to: 10 }];
    assert.equal(computeCoverage(r, { vaultPath: vault() })[0]!.full, true);
  });

  test('partial wording: the owner’s pages match; ordinary words do not', () => {
    for (const s of [
      'Gemini quick notes and summary read; the remaining details and transcript were not, so this page is partial.',
      'the transcript was only read for its first minutes (the file is long), so this page is partial on transcript detail.',
      'Several transcripts were not read.',
    ]) assert.ok(partialWording(s), s);
    for (const s of ['They agreed a partial payment for the vendor.', 'Every line was read in full.', 'The partial rollout starts Monday.']) assert.equal(partialWording(s), undefined, s);
  });
});

describe('budget and archive names', () => {
  test('Automatic is 30% of the context window, at most 100K; an unknown model counts as 200K', () => {
    const w = new ModelWindows(path.join(tmp, 'models.json'));
    assert.equal(contextWindowFor('mystery', w), 200_000);
    assert.equal(batchBudget(null, 200_000), 60_000);
    assert.equal(batchBudget(undefined, 1_000_000), 100_000);
    assert.equal(batchBudget(200_000, 1_000_000), 200_000);
    // An explicit size the model can't hold is capped at half its window.
    assert.equal(batchBudget(200_000, 200_000), 100_000);
    w.set({ 'claude-sonnet-5-5': 1_000_000 }, 'sonnet');
    assert.equal(contextWindowFor('sonnet', new ModelWindows(path.join(tmp, 'models.json'))), 1_000_000);
  });

  test('captured paths and source IDs match claude-obsidian', () => {
    assert.equal(capturedPath('ab'.repeat(32), 'inbox/A.MD'), `.raw/captured/${'ab'.repeat(32)}.md`);
    assert.equal(capturedPath('ab'.repeat(32), 'inbox/x.docx'), `.raw/captured/${'ab'.repeat(32)}.bin`);
    // python3 -c "from claude_obsidian.ledgers import stable_source_id as s; print(s('file','inbox/a.md','00'*32))"
    assert.equal(stableSourceId('file', 'inbox/a.md', '00'.repeat(32)), 'src-3d88ff1684781387e750');
  });
});
