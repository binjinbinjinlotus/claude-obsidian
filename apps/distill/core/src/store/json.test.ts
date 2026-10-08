import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { bool, encodeJSON, isObject, isoDate, normalizeDate, num, parseDate, preserveUnreadable, readJSON, str, strArray, writeFileAtomic, writeJSONAtomic } from './json.js';

let dir: string;
beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-json-'));
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('dates', () => {
  test('isoDate drops milliseconds (Swift .iso8601 rejects them)', () => {
    assert.equal(isoDate(new Date('2026-10-01T15:42:00.123Z')), '2026-10-01T15:42:00Z');
    assert.equal(isoDate(new Date('2026-10-01T15:42:00Z')), '2026-10-01T15:42:00Z');
  });
  test('parseDate takes strings only and rejects invalid ones', () => {
    assert.equal(parseDate('2026-10-01T15:42:00.5Z')?.toISOString(), '2026-10-01T15:42:00.500Z');
    assert.equal(parseDate('not a date'), undefined);
    assert.equal(parseDate(1_700_000_000_000), undefined);
    assert.equal(parseDate(null), undefined);
  });
  test('normalizeDate rewrites a stored date or falls back', () => {
    const fallback = new Date('2020-01-02T03:04:05Z');
    assert.equal(normalizeDate('2026-10-01T15:42:00.999Z', fallback), '2026-10-01T15:42:00Z');
    assert.equal(normalizeDate('garbage', fallback), '2020-01-02T03:04:05Z');
    assert.equal(normalizeDate(undefined, fallback), '2020-01-02T03:04:05Z');
  });
});

describe('value readers', () => {
  test('isObject: plain objects only', () => {
    assert.equal(isObject({}), true);
    assert.equal(isObject([]), false);
    assert.equal(isObject(null), false);
    assert.equal(isObject('x'), false);
  });
  test('str, num, bool, strArray keep the right type and drop the rest', () => {
    assert.equal(str('a'), 'a');
    assert.equal(str(''), '');
    assert.equal(str(1), undefined);
    assert.equal(num(0), 0);
    assert.equal(num(-2.5), -2.5);
    assert.equal(num(Number.NaN), undefined);
    assert.equal(num(Number.POSITIVE_INFINITY), undefined);
    assert.equal(num('3'), undefined);
    assert.equal(bool(false), false);
    assert.equal(bool('true'), undefined);
    assert.deepEqual(strArray(['a', 1, null, 'b']), ['a', 'b']);
    assert.deepEqual(strArray([]), []);
    assert.equal(strArray('a'), undefined);
  });
});

describe('readJSON', () => {
  test('missing and unparseable files read as undefined', () => {
    assert.equal(readJSON(path.join(dir, 'none.json')), undefined);
    fs.writeFileSync(path.join(dir, 'bad.json'), '{ nope');
    assert.equal(readJSON(path.join(dir, 'bad.json')), undefined);
    fs.writeFileSync(path.join(dir, 'ok.json'), '[1,2]');
    assert.deepEqual(readJSON(path.join(dir, 'ok.json')), [1, 2]);
  });
});

describe('encodeJSON', () => {
  test('sorts keys at every level, drops undefined, keeps null and array order, ends with a newline', () => {
    const text = encodeJSON({ b: 1, a: { d: [{ z: 1, y: 2 }, 3], c: undefined, n: null } });
    assert.equal(text, '{\n  "a": {\n    "d": [\n      {\n        "y": 2,\n        "z": 1\n      },\n      3\n    ],\n    "n": null\n  },\n  "b": 1\n}\n');
  });
});

describe('writeFileAtomic', () => {
  test('creates missing directories, replaces the file and leaves no temp file', () => {
    const file = path.join(dir, 'nested', 'deeper', 'state.json');
    writeFileAtomic(file, 'one');
    writeJSONAtomic(file, { b: 2, a: 1 });
    assert.equal(fs.readFileSync(file, 'utf8'), '{\n  "a": 1,\n  "b": 2\n}\n');
    assert.deepEqual(fs.readdirSync(path.dirname(file)), ['state.json']);
  });
  test('applies the mode (default 0644)', () => {
    const a = path.join(dir, 'a');
    const b = path.join(dir, 'b');
    writeFileAtomic(a, 'x');
    writeFileAtomic(b, 'x', 0o600);
    assert.equal(fs.statSync(a).mode & 0o777, 0o644 & ~process.umask());
    assert.equal(fs.statSync(b).mode & 0o777, 0o600);
  });
  test('a failed rename removes the temp file and throws', () => {
    const target = path.join(dir, 'is-a-dir');
    fs.mkdirSync(path.join(target, 'child'), { recursive: true });
    assert.throws(() => writeFileAtomic(target, 'x'));
    assert.deepEqual(fs.readdirSync(dir), ['is-a-dir']);
  });
});

describe('preserveUnreadable', () => {
  test('copies the bytes once next to the file, 0600, stamped without colons', () => {
    const file = path.join(dir, 'settings.json');
    fs.writeFileSync(file, '{ broken');
    const copy = preserveUnreadable(file, new Date('2026-10-01T15:42:07.300Z'));
    assert.equal(copy, path.join(dir, 'settings.json.unreadable-2026-10-01T154207Z'));
    assert.equal(fs.readFileSync(copy!, 'utf8'), '{ broken');
    assert.equal(fs.statSync(copy!).mode & 0o777, 0o600);
    // The same bytes are not copied twice.
    assert.equal(preserveUnreadable(file, new Date('2026-10-02T00:00:00Z')), undefined);
    assert.equal(fs.readdirSync(dir).length, 2);
  });
  test('different bytes get a new copy; the old copy stays', () => {
    const file = path.join(dir, 'jobs.json');
    fs.writeFileSync(file, 'v1');
    const first = preserveUnreadable(file, new Date('2026-10-01T00:00:00Z'));
    fs.writeFileSync(file, 'v2');
    const second = preserveUnreadable(file, new Date('2026-10-02T00:00:00Z'));
    assert.ok(first && second && first !== second);
    assert.equal(fs.readFileSync(first, 'utf8'), 'v1');
    assert.equal(fs.readFileSync(second, 'utf8'), 'v2');
  });
  test('a copy of another file with the same bytes does not count', () => {
    fs.writeFileSync(path.join(dir, 'other.json.unreadable-2026-10-01T000000Z'), 'same');
    const file = path.join(dir, 'jobs.json');
    fs.writeFileSync(file, 'same');
    assert.ok(preserveUnreadable(file));
  });
  test('a missing file makes no copy', () => {
    assert.equal(preserveUnreadable(path.join(dir, 'none.json')), undefined);
    assert.deepEqual(fs.readdirSync(dir), []);
  });
});
