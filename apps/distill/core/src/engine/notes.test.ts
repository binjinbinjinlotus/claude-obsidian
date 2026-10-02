import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { defaultSettings } from '../store/settings.js';
import { newJob } from '../store/jobs.js';
import { IngestJobKind, JobContext } from './job-kinds.js';
import { noteStem, writeNote } from './notes.js';
import { claimFiles, pendingFiles } from './queue.js';

let tmp: string;
let vault: { path: string; queueDirectory: string };
const NOW = new Date(2026, 9, 1, 15, 42, 0);

beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-notes-')));
  vault = { path: path.join(tmp, 'vault'), queueDirectory: path.join(tmp, 'queue') };
  fs.mkdirSync(path.join(vault.path, 'inbox'), { recursive: true });
});
afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

function image(name: string, bytes = 'PNGDATA'): string {
  const p = path.join(tmp, name);
  fs.writeFileSync(p, bytes);
  return p;
}

describe('addNote (writeNote)', () => {
  test('writes note, images and manifest into the queue', () => {
    const card = image('card.PNG', 'card');
    const setup = image('setup.jpg', 'setup');
    const result = writeNote(
      {
        title: 'Gyokuro at 60 °C',
        text: 'Steep for two minutes.\n',
        images: [{ path: card, mode: 'extract' }, { path: setup, mode: 'keep' }],
        source: 'in-person',
        sourceRef: '#tea-club · with Mei',
      },
      vault,
      NOW,
    );
    const q = vault.queueDirectory;
    assert.equal(result.notePath, path.join(q, 'Gyokuro at 60 °C.md'));
    assert.deepEqual(result.queued, [
      path.join(q, 'Gyokuro at 60 °C.md'),
      path.join(q, 'Gyokuro at 60 °C image 1.png'),
      path.join(q, 'Gyokuro at 60 °C image 2.jpg'),
      path.join(q, 'Gyokuro at 60 °C.distill.json'),
    ]);
    assert.equal(
      fs.readFileSync(result.notePath, 'utf8'),
      '---\ntitle: "Gyokuro at 60 °C"\nsource_type: "in-person"\nsource_ref: "#tea-club · with Mei"\ncreated: 2026-10-01\n---\n\nSteep for two minutes.\n',
    );
    assert.equal(fs.readFileSync(path.join(q, 'Gyokuro at 60 °C image 1.png'), 'utf8'), 'card');
    assert.ok(fs.existsSync(card), 'originals are untouched');
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(q, 'Gyokuro at 60 °C.distill.json'), 'utf8')), {
      title: 'Gyokuro at 60 °C',
      source: 'in-person',
      sourceRef: '#tea-club · with Mei',
      images: [
        { file: 'Gyokuro at 60 °C image 1.png', mode: 'extract' },
        { file: 'Gyokuro at 60 °C image 2.jpg', mode: 'keep' },
      ],
    });
  });

  test('images default to keep; source fields are omitted when not given', () => {
    const img = image('a.png');
    const result = writeNote({ title: 'Plain', text: '', images: [{ path: img } as never] }, vault, NOW);
    const manifest = JSON.parse(fs.readFileSync(path.join(vault.queueDirectory, 'Plain.distill.json'), 'utf8'));
    assert.deepEqual(manifest, { title: 'Plain', images: [{ file: 'Plain image 1.png', mode: 'keep' }] });
    assert.equal(fs.readFileSync(result.notePath, 'utf8'), '---\ntitle: "Plain"\ncreated: 2026-10-01\n---\n');
  });

  test('stem avoids names already in the queue or the inbox', () => {
    fs.mkdirSync(vault.queueDirectory, { recursive: true });
    fs.writeFileSync(path.join(vault.path, 'inbox', 'Tea.md'), 'old');
    fs.writeFileSync(path.join(vault.queueDirectory, 'Tea 2.distill.json'), '{}');
    const result = writeNote({ title: 'Tea', text: 'x' }, vault, NOW);
    assert.equal(path.basename(result.notePath), 'Tea 3.md');
    // The whole set moves into the inbox without being renamed.
    const claimed = claimFiles(pendingFiles(vault.queueDirectory).filter((e) => e.name.startsWith('Tea 3')), vault, new Set());
    assert.deepEqual(claimed.sort(), ['inbox/Tea 3.distill.json', 'inbox/Tea 3.md']);
  });

  test('titles become safe, visible file names', () => {
    assert.equal(noteStem('../.hidden: a/b'), 'hidden- a-b');
    assert.equal(noteStem('  .  '), 'Note');
    assert.equal(noteStem('x'.repeat(300)).length, 120);
  });

  test('rejects empty notes and missing images', () => {
    assert.throws(() => writeNote({ title: ' ', text: 'x' }, vault, NOW), /title/);
    assert.throws(() => writeNote({ title: 'T', text: '  ' }, vault, NOW), /text or at least one image/);
    assert.throws(() => writeNote({ title: 'T', text: 'x', images: [{ path: path.join(tmp, 'nope.png'), mode: 'keep' }] }, vault, NOW), /Image not found/);
    assert.equal(fs.existsSync(vault.queueDirectory) && fs.readdirSync(vault.queueDirectory).length > 0, false, 'nothing half-written');
  });

  test('the ingest prompt tells the agent to honor manifests', () => {
    const settings = { ...defaultSettings(), productRoot: '/prod' };
    const withManifest = newJob({ id: 'j', kind: 'ingest', vaultPath: vault.path, files: ['inbox/Tea.md', 'inbox/Tea image 1.png', 'inbox/Tea.distill.json'], model: 'm', now: NOW });
    const prompt = IngestJobKind.initialPrompt(new JobContext(withManifest, vault, settings));
    assert.ok(prompt.includes('- inbox/Tea.distill.json'));
    assert.ok(prompt.includes('not a source'));
    assert.ok(prompt.includes('`mode: keep`'));
    assert.ok(prompt.includes('wiki/attachments/'));
    assert.ok(prompt.includes('`mode: extract`'));
    assert.ok(prompt.includes('do NOT store or embed the image'));
    const plain = newJob({ id: 'j', kind: 'ingest', vaultPath: vault.path, files: ['inbox/a.md'], model: 'm', now: NOW });
    assert.ok(!IngestJobKind.initialPrompt(new JobContext(plain, vault, settings)).includes('manifest'));
  });
});
