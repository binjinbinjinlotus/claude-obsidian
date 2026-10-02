import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { createRunnerRegistry } from '../runners/registry.js';
import { statePaths } from '../store/paths.js';
import { createEngine } from './index.js';
import { clampPageLimit, rankPages, searchVaultPages, type PageRef } from './pages.js';

let tmp: string;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-pages-')));
});
afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

function writePage(vault: string, rel: string, text: string) {
  const p = path.join(vault, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, text);
}

const pages: PageRef[] = [
  { path: 'wiki/sources/sencha.md', title: 'Sencha basics' },
  { path: 'wiki/sources/kyoto-tea-shops.md', title: 'Kyoto tea shops' },
  { path: 'wiki/concepts/gyokuro.md', title: 'Gyokuro' },
  { path: 'wiki/concepts/green-tea.md', title: 'Green tea' },
  { path: 'wiki/concepts/matcha-whisking.md', title: 'Matcha whisking' },
  { path: 'wiki/entities/café-sen.md', title: 'Café Sen' },
];

describe('rankPages', () => {
  test('exact, prefix, word prefix, substring, then in-order letters', () => {
    assert.deepEqual(
      rankPages(pages, 'sen').map((p) => p.title),
      ['Sencha basics', 'Café Sen'], // title prefix beats word prefix
    );
    assert.equal(rankPages(pages, 'gyokuro')[0]!.title, 'Gyokuro');
    assert.equal(rankPages(pages, 'TEA SH')[0]!.title, 'Kyoto tea shops');
    assert.deepEqual(rankPages(pages, 'kts').map((p) => p.title), ['Kyoto tea shops']); // subsequence
    assert.deepEqual(rankPages(pages, 'zzz'), []);
  });

  test('accents fold, file names count, every word may match', () => {
    assert.equal(rankPages(pages, 'cafe')[0]!.title, 'Café Sen');
    assert.equal(rankPages(pages, 'whisk')[0]!.title, 'Matcha whisking');
    assert.equal(rankPages(pages, 'green-tea')[0]!.title, 'Green tea'); // by file name
    assert.equal(rankPages(pages, 'kyo sho')[0]!.title, 'Kyoto tea shops');
  });

  test('empty query lists alphabetically; limit clamps', () => {
    assert.deepEqual(rankPages(pages, '  ', 3).map((p) => p.title), ['Café Sen', 'Green tea', 'Gyokuro']);
    assert.equal(rankPages(pages, '', 100).length, pages.length);
    assert.equal(clampPageLimit(undefined), 8);
    assert.equal(clampPageLimit(0), 1);
    assert.equal(clampPageLimit(500), 50);
  });
});

describe('searchVaultPages / engine.searchPages', () => {
  test('scans wiki/**/*.md, uses frontmatter title or the file name, skips system pages', async () => {
    const vault = path.join(tmp, 'vault');
    writePage(vault, 'wiki/index.md', '# Index\n');
    writePage(vault, 'wiki/log.md', '# Log\n');
    writePage(vault, 'wiki/meta/dashboard.md', '---\ntitle: Sencha dashboard\n---\n');
    writePage(vault, 'wiki/sources/sencha.md', '---\ntitle: "Sencha basics"\ntags: [tea]\n---\n# Sencha\n');
    writePage(vault, 'wiki/concepts/Sencha Brewing.md', 'No frontmatter.\n');
    writePage(vault, 'wiki/.hidden/sencha.md', '---\ntitle: Sencha hidden\n---\n');
    writePage(vault, 'inbox/sencha.md', '---\ntitle: Sencha inbox\n---\n');
    assert.deepEqual(await searchVaultPages(vault, 'sencha'), [
      { path: 'wiki/sources/sencha.md', title: 'Sencha basics' },
      { path: 'wiki/concepts/Sencha Brewing.md', title: 'Sencha Brewing' },
    ]);
    assert.deepEqual(await searchVaultPages(path.join(tmp, 'missing'), 'x'), []);

    const state = path.join(tmp, 'state');
    fs.mkdirSync(state, { recursive: true });
    fs.writeFileSync(path.join(vault, '.claude-obsidian.json'), '{}');
    fs.writeFileSync(
      path.join(state, 'settings.json'),
      JSON.stringify({ vaults: [{ path: vault, queueDirectory: path.join(tmp, 'queue') }], activeVaultPath: vault, autoProcessEnabled: false }),
    );
    const engine = createEngine({ paths: statePaths(state), runners: createRunnerRegistry([]), tickMs: 60_000 });
    assert.deepEqual(await engine.searchPages('brew'), [{ path: 'wiki/concepts/Sencha Brewing.md', title: 'Sencha Brewing' }]);
    assert.equal((await engine.searchPages('', { vaultPath: vault, limit: 1 })).length, 1);
    await assert.rejects(engine.searchPages('x', { vaultPath: path.join(tmp, 'other') }), /Unknown vault/);
    await engine.stop();
  });
});
