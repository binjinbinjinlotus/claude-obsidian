import assert from 'node:assert/strict';
import { test } from 'node:test';
import { listValue, parseFrontmatter, scalarValue } from './frontmatter.js';
import { expandSources, normalizeSourceID } from './taxonomy.js';
import { normalizeTag, tagMatches } from './filters.js';

test('parses scalars, block lists and flow lists', () => {
  const fm = parseFrontmatter(
    [
      '---',
      'type: source',
      'title: "Sencha: brewing"',
      "author: 'O''Brien'",
      'source_type: slack   # from the channel',
      'tags:',
      '  - tea',
      '  - "#green/japan"',
      '  -   ',
      'aliases: [Sencha, "Green, tea"]',
      'related:',
      '  - "[[Matcha]]"',
      'nested:',
      '  child: x',
      'empty:',
      '---',
      'tags: not-frontmatter',
    ].join('\n'),
  );
  assert.equal(fm.type, 'source');
  assert.equal(fm.title, 'Sencha: brewing');
  assert.equal(fm.author, "O'Brien");
  assert.equal(fm.source_type, 'slack');
  assert.deepEqual(fm.tags, ['tea', '#green/japan']);
  assert.deepEqual(fm.aliases, ['Sencha', 'Green, tea']);
  assert.deepEqual(fm.related, ['[[Matcha]]']);
  assert.deepEqual(fm.nested, []);
  assert.deepEqual(fm.empty, []);
});

test('handles BOM and CRLF; requires --- on line 1', () => {
  const fm = parseFrontmatter('﻿---\r\ntitle: X\r\ntags:\r\n  - a\r\n---\r\nbody');
  assert.equal(fm.title, 'X');
  assert.deepEqual(fm.tags, ['a']);
  assert.deepEqual(parseFrontmatter('\n---\ntitle: X\n---\n'), {});
  assert.deepEqual(parseFrontmatter('---\ntitle: unterminated\n'), {});
  assert.deepEqual(parseFrontmatter('no frontmatter'), {});
});

test('listValue and scalarValue coerce shapes', () => {
  const fm = parseFrontmatter('---\na: one\nb:\n  - x\n  - y\n---\n');
  assert.deepEqual(listValue(fm, 'a'), ['one']);
  assert.deepEqual(listValue(fm, 'b'), ['x', 'y']);
  assert.deepEqual(listValue(fm, 'missing'), []);
  assert.equal(scalarValue(fm, 'b'), 'x');
  assert.equal(scalarValue(fm, 'missing'), undefined);
});

test('tag normalization and nested matching', () => {
  assert.equal(normalizeTag(' #Tea/Green '), 'tea/green');
  assert.ok(tagMatches('tea', 'tea'));
  assert.ok(tagMatches('tea', 'tea/green'));
  assert.ok(!tagMatches('tea', 'teapot'));
  assert.ok(!tagMatches('tea/green', 'tea'));
  assert.ok(tagMatches('tea/green', 'tea/green/japan'));
});

test('source ids normalize and groups expand or narrow', () => {
  assert.equal(normalizeSourceID('GitHub review'), 'github-review');
  assert.equal(normalizeSourceID('in_person'), 'in-person');
  assert.deepEqual(
    [...expandSources(['discussion'])].sort(),
    ['email', 'github-review', 'in-person', 'jira-comment', 'meeting', 'slack'],
  );
  assert.deepEqual([...expandSources(['Discussion', 'Slack'])], ['slack']);
  assert.deepEqual([...expandSources(['personal', 'paper'])].sort(), ['idea', 'paper', 'remember-this']);
  assert.deepEqual([...expandSources(['Web page', 'podcast'])].sort(), ['podcast', 'web-page']);
});
