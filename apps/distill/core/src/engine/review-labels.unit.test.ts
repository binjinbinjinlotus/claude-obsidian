/**
 * Pure helpers of review-labels.ts (no engine, no python core): bundles, source pages, revisions, the
 * rebuilt-part checks and the part prompt. The engine paths are in review-labels.test.ts.
 */
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import {
  confirmedText, contentFileFor, inspectReason, ledgerProblems, needsRevision, pageShas, partPrompt, readBundle, reviewSources, sourcePages,
  suggestedText, verifyRebuilt, wikiWrites, writeRevision, type LoadedBundle,
} from './review-labels.js';
import { pageTags } from '../labels/vault.js';

const sha = (s: string) => createHash('sha256').update(s).digest('hex');

let dir: string;
beforeEach(() => {
  dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-review-unit-')));
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

function bundle(writes: unknown[], extra: Record<string, unknown> = {}): LoadedBundle {
  const p = path.join(dir, 'bundle.json');
  fs.writeFileSync(p, JSON.stringify({ operation: 'op', ...extra, writes }));
  return readBundle(p)!;
}

const page = (fm: string[], body = 'Body.') => ['---', ...fm, '---', '', body, ''].join('\n');
const AI = page(['type: source', 'title: "Source A"', 'source_path: "inbox/a.md"', 'tags:', '  - x', 'labels_by: ai', 'labels_reviewed: false']);

describe('readBundle', () => {
  test('undefined for a missing file, bad JSON, no writes array; writes without a string path are left out', () => {
    assert.equal(readBundle(path.join(dir, 'none.json')), undefined);
    fs.writeFileSync(path.join(dir, 'bad.json'), '{');
    assert.equal(readBundle(path.join(dir, 'bad.json')), undefined);
    fs.writeFileSync(path.join(dir, 'arr.json'), '[]');
    assert.equal(readBundle(path.join(dir, 'arr.json')), undefined);
    fs.writeFileSync(path.join(dir, 'nowrites.json'), '{"writes": {}}');
    assert.equal(readBundle(path.join(dir, 'nowrites.json')), undefined);
    const b = bundle([{ path: 'wiki/a.md', content: 'a' }, { path: 3 }, 'x', null]);
    assert.deepEqual(b.writes.map((w) => w.path), ['wiki/a.md']);
    assert.equal(b.dir, dir);
    assert.equal(b.raw.operation, 'op');
  });
});

describe('wikiWrites and pageShas', () => {
  test('Markdown under wiki/ only, inline or from a content file (relative or absolute); unreadable files are skipped', () => {
    fs.writeFileSync(path.join(dir, 'b.md'), 'B');
    const abs = path.join(dir, 'abs.md');
    fs.writeFileSync(abs, 'ABS');
    const b = bundle([
      { path: 'wiki/a.md', content: 'A' },
      { path: 'wiki/b.MD', content_file: 'b.md' },
      { path: 'wiki/abs.md', content_file: abs },
      { path: 'wiki/gone.md', content_file: 'gone.md' },
      { path: 'wiki/none.md' },
      { path: 'wiki/data.json', content: '{}' },
      { path: 'inbox/x.md', content: 'X' },
    ]);
    assert.deepEqual(wikiWrites(b), [
      { path: 'wiki/a.md', text: 'A' },
      { path: 'wiki/b.MD', text: 'B' },
      { path: 'wiki/abs.md', text: 'ABS' },
    ]);
    assert.deepEqual([...pageShas(b)], [
      ['wiki/a.md', sha('A')], ['wiki/b.MD', sha('B')], ['wiki/abs.md', sha('ABS')], ['wiki/data.json', sha('{}')], ['inbox/x.md', sha('X')],
    ]);
  });
});

describe('sourcePages and reviewSources', () => {
  test('pages with label properties or type: source; who labelled them; the source, title and origin', () => {
    const b = bundle([
      { path: 'wiki/sources/a.md', content: AI },
      { path: 'wiki/sources/u.md', content: page(['labels_by: user', 'sources:', '  - "inbox/u.md"', 'labels_origin: queue-folder']) },
      { path: 'wiki/sources/t.md', content: page(['type: source', 'tags:', '  - y']) },
      { path: 'wiki/sources/n.md', content: page(['type: source']) },
      { path: 'wiki/concepts/c.md', content: page(['type: concept', 'tags:', '  - z']) },
      { path: 'wiki/sources/plain.md', content: 'no front matter' },
      { path: 'wiki/sources/x.txt', content: AI },
      { path: 'raw/a.md', content: AI },
      { path: 'wiki/sources/missing.md', content_file: 'missing.md' },
    ]);
    const pages = sourcePages(b);
    assert.deepEqual(pages.map((p) => [p.page, p.title, p.by, p.unconfirmed, p.source, p.origin, p.labels]), [
      ['wiki/sources/a.md', 'Source A', 'ai', true, 'inbox/a.md', undefined, ['x']],
      ['wiki/sources/u.md', 'u', 'user', false, 'inbox/u.md', 'queue-folder', []],
      ['wiki/sources/t.md', 't', 'user', false, undefined, undefined, ['y']],
      ['wiki/sources/n.md', 'n', 'none', false, undefined, undefined, []],
    ]);
    assert.ok(!('source' in pages[2]!) && !('origin' in pages[0]!), 'absent fields are left out, not undefined');
    const review = reviewSources(pages);
    assert.deepEqual(review[0], { page: 'wiki/sources/a.md', title: 'Source A', labels: ['x'], by: 'ai', source: 'inbox/a.md' });
    assert.ok(!('source' in review[2]!));
    review[0]!.labels.push('mutated');
    assert.deepEqual(pages[0]!.labels, ['x'], 'Review gets a copy of the labels');
  });
});

describe('needsRevision', () => {
  test('an unconfirmed page, an origin, or an override needs one; a confirmed page does not', () => {
    const b = bundle([
      { path: 'wiki/sources/a.md', content: AI },
      { path: 'wiki/sources/t.md', content: page(['type: source', 'tags:', '  - y']) },
      { path: 'wiki/sources/o.md', content: page(['type: source', 'labels_origin: batch']) },
    ]);
    const [a, t, o] = sourcePages(b);
    assert.equal(needsRevision([a!]), true);
    assert.equal(needsRevision([t!]), false);
    assert.equal(needsRevision([o!]), true);
    assert.equal(needsRevision([t!], new Map([['wiki/sources/t.md', ['z']]])), true);
    assert.equal(needsRevision([t!], new Map([['wiki/sources/other.md', ['z']]])), false);
    assert.equal(needsRevision([]), false);
  });
});

describe('suggestedText and confirmedText', () => {
  test('a suggestion is the AI\'s and unreviewed; a confirmation is the user\'s, with the given or current tags', () => {
    const [a] = sourcePages(bundle([{ path: 'wiki/sources/a.md', content: AI }]));
    const s = suggestedText(a!, ['p', 'q']);
    assert.match(s, /labels_by: ai/);
    assert.match(s, /labels_reviewed: false/);
    assert.match(s, /- p\n\s+- q|\[p, q\]|- p/);
    const kept = confirmedText(a!, undefined);
    assert.match(kept, /labels_by: user/);
    assert.match(kept, /\bx\b/);
    assert.doesNotMatch(kept, /labels_reviewed: false/);
    const cleared = confirmedText(a!, []);
    assert.match(cleared, /labels_by: user/);
    assert.deepEqual(pageTags(cleared), []);
    assert.deepEqual(pageTags(confirmedText(a!, ['p'])), ['p']);
  });
});

describe('writeRevision', () => {
  test('nothing to change: undefined and no files', () => {
    const b = bundle([{ path: 'wiki/sources/t.md', content: page(['type: source', 'tags:', '  - y']) }]);
    assert.equal(writeRevision(b, sourcePages(b)), undefined);
    assert.ok(!fs.existsSync(path.join(dir, 'bundle-labels-1.json')));
  });

  test('inline and file writes get new content; sha256 follows when present; other entries are kept in place; the next free number', () => {
    fs.writeFileSync(path.join(dir, 'bundle-labels-1.json'), '{}');
    fs.mkdirSync(path.join(dir, 'drafts'));
    fs.writeFileSync(path.join(dir, 'drafts', 'f.md'), AI);
    fs.writeFileSync(path.join(dir, 'drafts', 'g.md'), AI);
    const b = bundle([
      { path: 'wiki/sources/a.md', content: AI, sha256: sha(AI) },
      'kept-as-is',
      { path: 'wiki/sources/f.md', content_file: 'drafts/f.md' },
      { path: 7, note: 'not a page write' },
      { path: 'wiki/sources/g.md', content_file: 'drafts/g.md', op: 'create' },
      { path: 'wiki/sources/n.md', content: AI.replace('labels_by: ai', 'labels_by: ai\nx: 1') },
      { path: 'wiki/concepts/c.md', content: 'C' },
    ]);
    const pages = sourcePages(b);
    // A write with neither inline content nor a file name gets page-<n>.md.
    const rev = writeRevision(b, pages)!;
    assert.equal(rev.revision, 2);
    assert.equal(rev.bundlePath, path.join(dir, 'bundle-labels-2.json'));
    assert.deepEqual(rev.changed, ['wiki/sources/a.md', 'wiki/sources/f.md', 'wiki/sources/g.md', 'wiki/sources/n.md']);
    const out = JSON.parse(fs.readFileSync(rev.bundlePath, 'utf8'));
    assert.equal(out.operation, 'op');
    assert.equal(out.writes[1], 'kept-as-is');
    assert.match(out.writes[0].content, /labels_by: user/);
    assert.equal(out.writes[0].sha256, sha(out.writes[0].content));
    assert.equal(out.writes[2].content_file, 'labels-2/f.md');
    assert.ok(!('sha256' in out.writes[2]), 'no sha256 is added where there was none');
    assert.match(fs.readFileSync(path.join(dir, 'labels-2', 'f.md'), 'utf8'), /labels_by: user/);
    assert.equal(fs.readFileSync(path.join(dir, 'drafts', 'f.md'), 'utf8'), AI, 'the original draft is never modified');
    assert.deepEqual(out.writes[3], { path: 7, note: 'not a page write' }, 'an entry that is not a page write stays where it was');
    assert.deepEqual(out.writes[4], { path: 'wiki/sources/g.md', content_file: 'labels-2/g.md', op: 'create' }, 'every other field of the write is kept');
    assert.equal(out.writes[5].path, 'wiki/sources/n.md');
    assert.deepEqual(out.writes[6], { path: 'wiki/concepts/c.md', content: 'C' });
    assert.ok(fs.readFileSync(rev.bundlePath, 'utf8').endsWith('}\n'));
  });

  test('a page found by path only (no content) gets page-<n>.md; suggest mode writes only overrides, as the AI\'s', () => {
    fs.writeFileSync(path.join(dir, 'abs.md'), AI);
    const b = bundle([
      { path: 'wiki/sources/t.md', content: page(['type: source', 'tags:', '  - y']) },
      { path: 'wiki/sources/a.md', content: AI },
    ]);
    const pages = sourcePages(b);
    const sug = writeRevision(b, pages, new Map([['wiki/sources/t.md', ['new']]]), 'suggest')!;
    assert.deepEqual(sug.changed, ['wiki/sources/t.md'], 'the unconfirmed page is left alone in suggest mode');
    const out = JSON.parse(fs.readFileSync(sug.bundlePath, 'utf8'));
    assert.match(out.writes[0].content, /labels_by: ai/);
    assert.match(out.writes[0].content, /labels_reviewed: false/);
    assert.match(out.writes[0].content, /new/);
    // A page whose write has no content and no file name: its draft is page-<index+1>.md.
    const p0 = pages[1]!;
    const bare = { ...b, writes: [b.writes[0]!, { path: 'wiki/sources/a.md' }] };
    const rev = writeRevision(bare, [{ ...p0, write: bare.writes[1]! }])!;
    const out2 = JSON.parse(fs.readFileSync(rev.bundlePath, 'utf8'));
    assert.equal(out2.writes[1].content_file, `labels-${rev.revision}/page-2.md`);
    // keep mode: only overrides.
    assert.equal(writeRevision(b, pages, undefined, 'keep'), undefined);
  });

  test('confirm mode writes an override as the user\'s; an override that changes nothing is no revision', () => {
    const [a] = sourcePages(bundle([{ path: 'wiki/sources/a.md', content: AI }]));
    const done = confirmedText(a!, ['x']);
    const b = bundle([{ path: 'wiki/sources/a.md', content: AI }, { path: 'wiki/sources/d.md', content: done }]);
    const pages = sourcePages(b);
    const rev = writeRevision(b, pages, new Map([['wiki/sources/a.md', ['n']]]))!;
    const out = JSON.parse(fs.readFileSync(rev.bundlePath, 'utf8'));
    assert.match(out.writes[0].content, /labels_by: user/);
    assert.deepEqual(pageTags(out.writes[0].content), ['n']);
    assert.equal(writeRevision(b, [pages[1]!], new Map([['wiki/sources/d.md', ['x']]])), undefined, 'already confirmed with these labels');
  });
});

describe('inspectReason', () => {
  test('the ERR line with its code, else the first non-empty line, cut at 300', () => {
    assert.equal(inspectReason('trace\nERR STALE_HASH:  wiki/a.md changed  \nmore'), 'wiki/a.md changed (STALE_HASH)');
    assert.equal(inspectReason('\n\n  first line  \nsecond'), 'first line');
    assert.equal(inspectReason(''), '');
    assert.equal(inspectReason('x'.repeat(300)), 'x'.repeat(300));
    assert.equal(inspectReason('x'.repeat(301)), `${'x'.repeat(300)}…`);
    assert.equal(inspectReason('ERR lower: no'), 'ERR lower: no', 'the code is upper case');
  });
});

describe('contentFileFor', () => {
  test('the content file of a page, an inline page written out first, undefined otherwise', () => {
    fs.writeFileSync(path.join(dir, 'f.md'), 'F');
    const b = bundle([{ path: 'wiki/f.md', content_file: 'f.md' }, { path: 'wiki/sub/i.md', content: 'I' }, { path: 'wiki/none.md' }]);
    assert.equal(contentFileFor(b, 'wiki/f.md', path.join(dir, 'scratch')), path.join(dir, 'f.md'));
    const scratch = path.join(dir, 'scratch', 'deep');
    const written = contentFileFor(b, 'wiki/sub/i.md', scratch)!;
    assert.equal(written, path.join(scratch, 'i.md'));
    assert.equal(fs.readFileSync(written, 'utf8'), 'I');
    assert.equal(contentFileFor(b, 'wiki/none.md', scratch), undefined);
    assert.equal(contentFileFor(b, 'wiki/missing.md', scratch), undefined);
  });
});

describe('verifyRebuilt and ledgerProblems', () => {
  const ledger = (sources: unknown) => ({ path: 'wiki/meta/ledgers/source-ledger.json', content: JSON.stringify({ sources }) });

  test('missing pages, different pages, excluded pages and pages of an excluded source', () => {
    const b = bundle([
      { path: 'wiki/sources/a.md', content: AI },
      { path: 'wiki/sources/b.md', content: AI.replace(/inbox\/a\.md/, 'inbox/b.md') },
      { path: 'wiki/x.md', content: 'X' },
    ]);
    assert.deepEqual(verifyRebuilt(b, { 'wiki/sources/a.md': sha(AI) }, []), []);
    assert.deepEqual(verifyRebuilt(b, { 'wiki/sources/z.md': sha(AI), 'wiki/x.md': sha('Y') }, ['wiki/x.md', 'wiki/other.md']), [
      'wiki/sources/z.md is missing',
      'wiki/x.md is not the page you approved',
      'wiki/x.md should not be in it',
    ]);
    assert.deepEqual(verifyRebuilt(b, {}, [], ['inbox/b.md']), ['wiki/sources/b.md (from inbox/b.md) should not be in it']);
    assert.deepEqual(verifyRebuilt(b, { 'wiki/sources/b.md': sha(AI.replace(/inbox\/a\.md/, 'inbox/b.md')) }, [], ['inbox/b.md']), [], 'a page the user approved is expected, not excluded');
  });

  test('ledger records of a left-out source, by locator (NFC) or content sha (any case); unchanged records are fine', () => {
    const cafe = 'inbox/café.md';
    const b = bundle([
      ledger({
        s1: { origin: { locator: 'inbox/café.md' } },
        s2: { content_sha256: 'ABC' },
        s3: { origin: { locator: 'inbox/keep.md' }, content_sha256: 'def' },
        s4: 'not a record',
        s5: { origin: { locator: 'inbox/old.md' } },
      }),
    ]);
    assert.deepEqual(ledgerProblems(b, [], []), []);
    const broken = bundle([{ path: 'wiki/meta/ledgers/source-ledger.json', content: '{' }]);
    assert.deepEqual(ledgerProblems(broken, [], []), [], 'nothing left out: the ledger is not read');
    assert.deepEqual(verifyRebuilt(broken, {}, []), [], 'by default nothing is left out');
    assert.deepEqual(ledgerProblems(b, [cafe, 'inbox/old.md'], ['abc'], { sources: { s5: { origin: { locator: 'inbox/old.md' } } } }), [
      'source ledger record s1 (inbox/café.md) should not be in it',
      'source ledger record s2 (abc) should not be in it',
    ]);
    assert.deepEqual(ledgerProblems(b, ['inbox/old.md'], [], { sources: { s5: { origin: { locator: 'inbox/older.md' } } } }), [
      'source ledger record s5 (inbox/old.md) should not be in it',
    ], 'a changed record counts');
    assert.deepEqual(ledgerProblems(b, [], ['']), [], 'an empty sha never matches a record without one');
    assert.deepEqual(verifyRebuilt(b, {}, [], ['inbox/old.md']), ['source ledger record s5 (inbox/old.md) should not be in it']);
    assert.deepEqual(verifyRebuilt(b, {}, [], [], ['ABC']), ['source ledger record s2 (abc) should not be in it']);
  });

  test('no ledger write is fine; an unreadable or invalid ledger is a problem; odd shapes are no records', () => {
    assert.deepEqual(ledgerProblems(bundle([{ path: 'wiki/a.md', content: 'A' }]), ['x'], []), []);
    assert.deepEqual(ledgerProblems(bundle([{ path: 'wiki/meta/ledgers/source-ledger.json', content_file: 'none.json' }]), ['x'], []), ['its source ledger could not be read']);
    assert.deepEqual(ledgerProblems(bundle([{ path: 'wiki/meta/ledgers/source-ledger.json', content: '{' }]), [], ['a']), ['its source ledger is not valid JSON']);
    assert.deepEqual(ledgerProblems(bundle([{ path: 'wiki/meta/ledgers/source-ledger.json', content: '[]' }]), ['x'], []), []);
    assert.deepEqual(ledgerProblems(bundle([ledger([{ origin: { locator: 'x' } }])]), ['x'], []), [], 'an array of sources holds no records');
    assert.deepEqual(ledgerProblems(bundle([ledger({ s: { origin: { locator: 5 }, content_sha256: 7 }, junk: 'text' })]), [''], []), ['source ledger record s () should not be in it'], 'no locator matches an empty file name');
  });
});

describe('partPrompt', () => {
  const keep = [{ page: 'wiki/sources/a.md', source: 'inbox/a.md', contentFile: '/j/a.md', sha256: 'aa' }, { page: 'wiki/sources/b.md', contentFile: '/j/b.md', sha256: 'bb' }];
  test('why, the bundle path, each kept page with its file and sha, the left-out and removed sources when there are any', () => {
    const p = partPrompt({ reason: 'partial', bundlePath: '/j/bundle-part-1.json', keep, leaveOut: [{ page: 'wiki/sources/c.md', source: 'inbox/c.md' }], removed: [{ page: 'wiki/sources/d.md', source: null }] });
    assert.ok(p.startsWith('The user approved only some of the sources in this batch.\n\n'));
    assert.match(p, /at `\/j\/bundle-part-1\.json`/);
    assert.match(p, /\n- wiki\/sources\/a\.md \(from inbox\/a\.md\): \/j\/a\.md \(sha256 aa\)\n- wiki\/sources\/b\.md: \/j\/b\.md \(sha256 bb\)\n/);
    assert.match(p, /\.json` \(leave every earlier bundle as it is\), for the vault as it is now\.\n\nIt must create/);
    assert.match(p, /\(sha256 bb\)\n\nLeave these sources out entirely[^\n]*\n- wiki\/sources\/c\.md \(from inbox\/c\.md\)\n/);
    assert.match(p, /\(from inbox\/c\.md\)\n\nThe user removed these sources; never write a page for them:\n- wiki\/sources\/d\.md\n\nWrite the index/);
    assert.match(p, /finish with `needs_approval`/);
    const q = partPrompt({ reason: 'remaining', bundlePath: '/b', keep, leaveOut: [], removed: [], appliedOperation: 'op-7' });
    assert.match(q, /^The part the user approved was applied \(operation op-7\)\. Now build/);
    assert.doesNotMatch(q, /Leave these sources out|never write a page/);
    assert.match(partPrompt({ reason: 'remaining', bundlePath: '/b', keep, leaveOut: [], removed: [] }), /^The part the user approved was applied\. Now build/);
    assert.match(partPrompt({ reason: 'stale', bundlePath: '/b', keep, leaveOut: [], removed: [] }), /^The vault changed after the user reviewed this batch/);
  });
});
