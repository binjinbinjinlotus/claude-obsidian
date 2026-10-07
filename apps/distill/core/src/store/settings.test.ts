import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { DEFAULT_ACTION_PREFERENCES, DEFAULT_ASK_PREFERENCES, DEFAULT_LABELING_PREFERENCES, DEFAULT_RECOVERY_PREFERENCES, DEFAULT_SOURCE_TAXONOMY, type Settings } from '../contracts.js';
import {
  actionPreferences,
  activeVault,
  askPreferences,
  AI_TASKS,
  coreScriptPath,
  decodeActionPreferences,
  decodeSettings,
  defaultQueueDirectory,
  defaultSelection,
  defaultSettings,
  detectProductRoot,
  encodeSettings,
  fallbackModel,
  labelingPreferences,
  recoveryPreferences,
  selectionFor,
  SettingsStore,
  sourceTaxonomy,
  upsertVault,
} from './settings.js';

/** Every key the core stores, as settings.json holds it. */
function fullSettings(): Record<string, unknown> {
  return {
    vaults: [{ path: '/v', queueDirectory: '/q' }],
    activeVaultPath: '/v',
    batchIntervalMinutes: 15,
    settleSeconds: 5,
    model: 'opus',
    claudePath: '/bin/claude',
    pythonPath: '/bin/python3',
    productRoot: '/p',
    extraAllowedTools: ['WebFetch'],
    autoProcessEnabled: false,
    enabledRunners: ['claude-code', 'codex'],
    taskDefaults: { ask: { runnerID: 'claude-code', model: 'sonnet', effort: 'high' }, ingest: { runnerID: 'codex', model: 'gpt' } },
    nodePath: '/bin/node',
    sourceTaxonomy: [{ id: 'g', label: 'G', sources: [{ id: 's', label: 'S' }] }],
    askPreferences: { labelMatch: 'all', includeUnconfirmed: false, keepHistory: false, historyDays: 3 },
    recovery: { automatic: false, maxAttempts: 3, maxCostUSD: 2.5 },
    labeling: { autoLabelQueueFolder: false, cliFallbackToAI: false },
    shortcuts: { ask: 'ctrl+space', addNote: null },
    runnerOptions: { codex: { sandbox: 'read-only' } },
    actionPreferences: {
      sources: { notes: { detectTodos: false, confirm: true, future: 1 }, ask: { disabledTypes: ['jira'] }, other: { x: 1 } },
      types: { todo: { enabled: false, draftWhen: 'onRequest', improveAfterEdit: true, draftSelection: null, improveSelection: { runnerID: 'r', model: 'm' }, draftPrompt: null, improvePrompt: 'p', fieldDefaults: { due: 'today' }, handlesFor: ['you'], newKey: [1] } },
      findSelection: { runnerID: 'r', model: 'm', effort: 'low' },
      findPrompt: 'find',
      todo: { defaultSort: 'priority', defaultGroup: 'none', remindOverdue: true, later: 'x' },
      historyDays: 0,
      people: [{ id: 'you', name: 'Jin', aliases: ['J'], color: 'blue' }],
      future: { y: 2 },
    },
    queueScanMinutes: 30,
    batchSourceTokens: 50_000,
    detailLevel: { meeting: 'detailed', research: 'nearComplete' },
  };
}

describe('decodeSettings / encodeSettings', () => {
  test('every stored key round-trips unchanged', () => {
    const raw = fullSettings();
    assert.deepEqual(encodeSettings(decodeSettings(raw)), raw);
  });

  test('not an object: defaults', () => {
    for (const raw of [undefined, null, [], 'x']) assert.deepEqual(decodeSettings(raw), defaultSettings());
  });

  test('defaults: every required key and no optional ones', () => {
    const d = defaultSettings();
    assert.deepEqual({ ...d, claudePath: '', productRoot: '' }, {
      vaults: [], batchIntervalMinutes: 10, settleSeconds: 600, model: 'sonnet', claudePath: '', pythonPath: '/usr/bin/python3', productRoot: '',
      extraAllowedTools: [], autoProcessEnabled: true, enabledRunners: ['claude-code'], taskDefaults: {},
    });
    assert.equal(d.claudePath, path.join(os.homedir(), '.local', 'bin', 'claude'));
    const enc = encodeSettings(d);
    for (const k of ['activeVaultPath', 'nodePath', 'sourceTaxonomy', 'askPreferences', 'recovery', 'labeling', 'shortcuts', 'runnerOptions', 'actionPreferences', 'queueScanMinutes', 'batchSourceTokens', 'detailLevel']) {
      assert.equal(k in enc, false, k);
    }
  });

  test('mistyped keys take their defaults', () => {
    const s = decodeSettings({
      vaults: [{ path: '/v' }, { queueDirectory: '/q' }, 'x', { path: '/a', queueDirectory: '/b' }],
      activeVaultPath: 1, batchIntervalMinutes: '5', settleSeconds: null, model: 1, claudePath: [], pythonPath: {}, productRoot: false,
      extraAllowedTools: 'x', autoProcessEnabled: 'no', enabledRunners: {}, taskDefaults: [], nodePath: 2,
    });
    const d = defaultSettings();
    assert.deepEqual(s, { ...d, vaults: [{ path: '/a', queueDirectory: '/b' }] });
  });

  test('null entries in lists are skipped, never a crash', () => {
    const s = decodeSettings({ vaults: [null], sourceTaxonomy: [null, { id: 'g', label: 'G', sources: [null, { label: 'S' }] }], detailLevel: null, actionPreferences: { people: [null] } });
    assert.deepEqual(s.vaults, []);
    assert.deepEqual(s.sourceTaxonomy, [{ id: 'g', label: 'G', sources: [] }]);
    assert.equal(s.detailLevel, undefined);
    assert.deepEqual(s.actionPreferences!.people, []);
  });

  test('every AI task is listed', () => {
    assert.deepEqual(AI_TASKS, ['ingest', 'ask', 'labelSuggest', 'imageText', 'actionFind', 'actionDraft', 'actionImprove', 'recovery']);
  });

  test('numbers are truncated', () => {
    const s = decodeSettings({ batchIntervalMinutes: 7.9, settleSeconds: -3.5 });
    assert.equal(s.batchIntervalMinutes, 7);
    assert.equal(s.settleSeconds, -3);
  });

  test('taskDefaults: entries without a runnerID or model are dropped; effort is optional', () => {
    const s = decodeSettings({ taskDefaults: { ask: { model: 'm' }, ingest: { runnerID: 'r' }, recovery: 'x', labelSuggest: { runnerID: 'r', model: 'm', effort: 3 } } });
    assert.deepEqual(s.taskDefaults, { labelSuggest: { runnerID: 'r', model: 'm' } });
  });

  test('sourceTaxonomy: groups without id or label dropped, bad sources dropped; non-list stays absent', () => {
    const s = decodeSettings({ sourceTaxonomy: [{ id: 'g' }, { label: 'L' }, { id: 'g', label: 'G', sources: [{ id: 's' }, { id: 's', label: 'S' }, 'x'] }, { id: 'h', label: 'H', sources: 'x' }] });
    assert.deepEqual(s.sourceTaxonomy, [{ id: 'g', label: 'G', sources: [{ id: 's', label: 'S' }] }, { id: 'h', label: 'H', sources: [] }]);
    assert.equal(decodeSettings({ sourceTaxonomy: {} }).sourceTaxonomy, undefined);
  });

  test('askPreferences: unknown labelMatch dropped, historyDays at least 1 and whole', () => {
    assert.deepEqual(decodeSettings({ askPreferences: { labelMatch: 'some', historyDays: 0.5, keepHistory: 'yes' } }).askPreferences, { historyDays: 1 });
    assert.deepEqual(decodeSettings({ askPreferences: { labelMatch: 'any', historyDays: 12.7 } }).askPreferences, { labelMatch: 'any', historyDays: 12 });
    assert.deepEqual(decodeSettings({ askPreferences: { labelMatch: 'all' } }).askPreferences, { labelMatch: 'all' });
    assert.equal(decodeSettings({ askPreferences: 'x' }).askPreferences, undefined);
  });

  test('recovery: attempts clamped to 1–5 and rounded, cost clamped to 0–20, mistyped dropped', () => {
    assert.deepEqual(decodeSettings({ recovery: { maxAttempts: 9, maxCostUSD: 99 } }).recovery, { maxAttempts: 5, maxCostUSD: 20 });
    assert.deepEqual(decodeSettings({ recovery: { maxAttempts: 0, maxCostUSD: -1 } }).recovery, { maxAttempts: 1, maxCostUSD: 0 });
    assert.deepEqual(decodeSettings({ recovery: { maxAttempts: 2.5, maxCostUSD: 3.25 } }).recovery, { maxAttempts: 3, maxCostUSD: 3.25 });
    assert.deepEqual(decodeSettings({ recovery: { automatic: 'yes', maxAttempts: Number.NaN, maxCostUSD: '1' } }).recovery, {});
    // JSON's 1e999 parses as Infinity.
    assert.deepEqual(decodeSettings(JSON.parse('{"recovery":{"maxAttempts":1e999,"maxCostUSD":1e999}}')).recovery, {});
    assert.equal(decodeSettings({ recovery: [] }).recovery, undefined);
  });

  test('labeling, shortcuts and runnerOptions decode leniently', () => {
    assert.deepEqual(decodeSettings({ labeling: { autoLabelQueueFolder: 'no', cliFallbackToAI: true } }).labeling, { cliFallbackToAI: true });
    assert.deepEqual(decodeSettings({ labeling: { autoLabelQueueFolder: true } }).labeling, { autoLabelQueueFolder: true });
    assert.deepEqual(decodeSettings({ shortcuts: { ask: null, addNote: 3, other: 'x' } }).shortcuts, { ask: null });
    assert.deepEqual(decodeSettings({ shortcuts: { addNote: 'cmd+n' } }).shortcuts, { addNote: 'cmd+n' });
    assert.deepEqual(decodeSettings({ runnerOptions: { codex: { a: 'b', n: 1 }, bad: 'x' } }).runnerOptions, { codex: { a: 'b' } });
    for (const k of ['labeling', 'shortcuts', 'runnerOptions'] as const) assert.equal(decodeSettings({ [k]: 'x' })[k], undefined);
  });

  test('queueScanMinutes: whole minutes from 0 to a day', () => {
    assert.equal(decodeSettings({ queueScanMinutes: -5 }).queueScanMinutes, 0);
    assert.equal(decodeSettings({ queueScanMinutes: 0 }).queueScanMinutes, 0);
    assert.equal(decodeSettings({ queueScanMinutes: 10.9 }).queueScanMinutes, 10);
    assert.equal(decodeSettings({ queueScanMinutes: 24 * 60 }).queueScanMinutes, 1440);
    assert.equal(decodeSettings({ queueScanMinutes: 99_999 }).queueScanMinutes, 1440);
    assert.equal(decodeSettings({ queueScanMinutes: '5' }).queueScanMinutes, undefined);
  });

  test('batchSourceTokens: positive, rounded, clamped to 10K–300K; 0 or absent is Automatic', () => {
    assert.equal(decodeSettings({ batchSourceTokens: 0 }).batchSourceTokens, undefined);
    assert.equal(decodeSettings({ batchSourceTokens: -1 }).batchSourceTokens, undefined);
    assert.equal(decodeSettings({ batchSourceTokens: 1 }).batchSourceTokens, 10_000);
    assert.equal(decodeSettings({ batchSourceTokens: 10_000 }).batchSourceTokens, 10_000);
    assert.equal(decodeSettings({ batchSourceTokens: 20_000.6 }).batchSourceTokens, 20_001);
    assert.equal(decodeSettings({ batchSourceTokens: 300_000 }).batchSourceTokens, 300_000);
    assert.equal(decodeSettings({ batchSourceTokens: 1e9 }).batchSourceTokens, 300_000);
  });

  test('detailLevel: known types and levels only; nothing known stays absent', () => {
    assert.deepEqual(decodeSettings({ detailLevel: { meeting: 'highlights', conversation: 'detailed', other: 'nearComplete', research: 'all', email: 'detailed' } }).detailLevel, { meeting: 'highlights', conversation: 'detailed', other: 'nearComplete' });
    assert.equal(decodeSettings({ detailLevel: { email: 'detailed' } }).detailLevel, undefined);
    assert.equal(decodeSettings({ detailLevel: ['meeting'] }).detailLevel, undefined);
    assert.equal(decodeSettings({ detailLevel: 'detailed' }).detailLevel, undefined);
    assert.equal('detailLevel' in encodeSettings({ ...defaultSettings(), detailLevel: {} }), false);
  });

  test('encodeSettings keeps unknown top-level keys and replaces known ones', () => {
    const out = encodeSettings(defaultSettings(), { model: 'stale', nodePath: 'stale', future: [1] });
    assert.equal(out.model, 'sonnet');
    assert.equal('nodePath' in out, false);
    assert.deepEqual(out.future, [1]);
  });

  test('encodeSettings skips an unset task default', () => {
    const s: Settings = { ...defaultSettings(), taskDefaults: { ask: undefined } as Settings['taskDefaults'] };
    assert.deepEqual(encodeSettings(s).taskDefaults, {});
  });
});

describe('decodeActionPreferences', () => {
  test('not an object: undefined', () => {
    assert.equal(decodeActionPreferences([]), undefined);
    assert.equal(decodeActionPreferences(null), undefined);
  });

  test('mistyped known keys are dropped; unknown keys kept at every level', () => {
    const p = decodeActionPreferences({
      sources: { notes: { detectTodos: 'x', detectTypes: true, disabledTypes: 'jira', z: 1 }, ask: 'x' },
      types: { todo: { enabled: 1, draftWhen: 'sometimes', improveAfterEdit: 'x', draftSelection: { model: 'm' }, improveSelection: 'x', draftPrompt: 3, fieldDefaults: { a: 'b', c: 1 }, handlesFor: ['you', 'you', 'p1'] }, bad: 'x' },
      findSelection: 'x',
      findPrompt: 3,
      todo: { defaultSort: 'alpha', defaultGroup: 'week', remindOverdue: 'x' },
      historyDays: 'x',
      people: 'x',
    })!;
    assert.deepEqual(p, {
      sources: { notes: { detectTypes: true, z: 1 } },
      types: { todo: { fieldDefaults: { a: 'b' }, handlesFor: ['you', 'p1'] } },
      todo: {},
    });
  });

  test('null selections and prompts mean "cleared" and are kept', () => {
    const p = decodeActionPreferences({ findSelection: null, findPrompt: null, types: { t: { draftSelection: null, improvePrompt: null } } })!;
    assert.equal(p.findSelection, null);
    assert.equal(p.findPrompt, null);
    assert.deepEqual(p.types, { t: { draftSelection: null, improvePrompt: null } });
  });

  test('each todo sort and group, each draftWhen', () => {
    for (const s of ['due', 'created', 'priority', 'note']) assert.equal(decodeActionPreferences({ todo: { defaultSort: s } })!.todo!.defaultSort, s);
    for (const g of ['due', 'note', 'none']) assert.equal(decodeActionPreferences({ todo: { defaultGroup: g } })!.todo!.defaultGroup, g);
    for (const w of ['onFind', 'onRequest']) assert.equal(decodeActionPreferences({ types: { t: { draftWhen: w } } })!.types!.t!.draftWhen, w);
  });

  test('historyDays is truncated, not clamped (0 or less = forever)', () => {
    assert.equal(decodeActionPreferences({ historyDays: -4.5 })!.historyDays, -4);
    assert.equal(decodeActionPreferences({ historyDays: 30.9 })!.historyDays, 30);
  });

  test('people: trimmed, de-duplicated, nameless dropped except you, you first', () => {
    const p = decodeActionPreferences({
      people: [
        { id: ' p1 ', name: ' Aditya ', aliases: [' A ', 'A', '', 3] },
        'x',
        { id: 'p1', name: 'Dup' },
        { id: 'p2', name: '  ' },
        { name: 'No id' },
        { id: '', name: 'Empty id' },
        { id: 'you', aliases: ['me'], extra: true },
      ],
    })!;
    assert.deepEqual(p.people, [
      { extra: true, id: 'you', name: '', aliases: ['me'] },
      { id: 'p1', name: 'Aditya', aliases: ['A'] },
    ]);
    assert.deepEqual(decodeActionPreferences({ people: [{ id: 'you', name: 'Me' }, { id: 'p', name: 'P' }] })!.people!.map((x) => x.id), ['you', 'p']);
    // Without the user the order is kept.
    assert.deepEqual(decodeActionPreferences({ people: [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }] })!.people, [{ id: 'a', name: 'A', aliases: [] }, { id: 'b', name: 'B', aliases: [] }]);
  });
});

describe('derived values', () => {
  test('actionPreferences fills every default and merges nested objects', () => {
    assert.deepEqual(actionPreferences(defaultSettings()), DEFAULT_ACTION_PREFERENCES);
    const s = decodeSettings({ actionPreferences: { sources: { notes: { confirm: false } }, todo: { remindOverdue: true }, historyDays: 7, findPrompt: 'f', findSelection: null, people: [] } });
    const p = actionPreferences(s);
    assert.deepEqual(p.sources.notes, { detectTodos: true, detectTypes: true, confirm: false });
    assert.deepEqual(p.sources.ask, DEFAULT_ACTION_PREFERENCES.sources.ask);
    const q = actionPreferences(decodeSettings({ actionPreferences: { sources: { ask: { detectTodos: false } }, types: { jira: { enabled: false } } } }));
    assert.deepEqual(q.sources.ask, { detectTodos: false, detectTypes: true, confirm: true });
    assert.deepEqual(q.types, { jira: { enabled: false } });
    assert.deepEqual(p.todo, { defaultSort: 'due', defaultGroup: 'due', remindOverdue: true });
    assert.equal(p.historyDays, 7);
    assert.equal(p.findPrompt, 'f');
    assert.equal(p.findSelection, null);
    assert.deepEqual(p.people, []);
    assert.equal('findPrompt' in actionPreferences(defaultSettings()), false);
  });

  test('fallbackModel and defaultSelection per task', () => {
    assert.equal(fallbackModel('labelSuggest'), 'haiku');
    assert.equal(fallbackModel('ask'), 'sonnet');
    const s = { ...defaultSettings(), model: 'opus' };
    assert.deepEqual(defaultSelection(s, 'imageText'), { runnerID: 'claude-code', model: 'haiku', effort: 'low' });
    assert.deepEqual(defaultSelection(s, 'actionFind'), { runnerID: 'claude-code', model: 'sonnet', effort: 'medium' });
    assert.deepEqual(defaultSelection(s, 'recovery'), { runnerID: 'claude-code', model: 'opus', effort: 'medium' });
    assert.deepEqual(defaultSelection(s, 'ingest'), { runnerID: 'claude-code', model: 'opus', effort: null });
    assert.deepEqual(defaultSelection(s, 'ask'), { runnerID: 'claude-code', model: 'opus', effort: null });
    assert.deepEqual(defaultSelection(s, 'labelSuggest'), { runnerID: 'claude-code', model: 'haiku', effort: null });
    assert.deepEqual(defaultSelection(s, 'actionDraft'), { runnerID: 'claude-code', model: 'sonnet', effort: null });
    assert.ok(AI_TASKS.includes('recovery'));
  });

  test('selectionFor prefers the task default', () => {
    const s = { ...defaultSettings(), taskDefaults: { ask: { runnerID: 'codex', model: 'gpt' } } };
    assert.deepEqual(selectionFor(s, 'ask'), { runnerID: 'codex', model: 'gpt' });
    assert.equal(selectionFor(s, 'ingest').model, 'sonnet');
  });

  test('labelingPreferences and askPreferences fill defaults', () => {
    assert.deepEqual(labelingPreferences(defaultSettings()), DEFAULT_LABELING_PREFERENCES);
    assert.deepEqual(labelingPreferences({ ...defaultSettings(), labeling: { cliFallbackToAI: false } }), { ...DEFAULT_LABELING_PREFERENCES, cliFallbackToAI: false });
    assert.deepEqual(askPreferences(defaultSettings()), DEFAULT_ASK_PREFERENCES);
    assert.deepEqual(askPreferences({ ...defaultSettings(), askPreferences: { historyDays: 3 } }), { ...DEFAULT_ASK_PREFERENCES, historyDays: 3 });
  });

  test('recoveryPreferences and sourceTaxonomy fill defaults', () => {
    assert.deepEqual(recoveryPreferences(defaultSettings()), DEFAULT_RECOVERY_PREFERENCES);
    assert.deepEqual(recoveryPreferences({ ...defaultSettings(), recovery: { maxAttempts: 4 } }), { ...DEFAULT_RECOVERY_PREFERENCES, maxAttempts: 4 });
    assert.equal(sourceTaxonomy(defaultSettings()), DEFAULT_SOURCE_TAXONOMY);
    assert.deepEqual(sourceTaxonomy({ ...defaultSettings(), sourceTaxonomy: [] }), []);
  });

  test('activeVault: the active one, else the first; upsertVault replaces by path or appends', () => {
    const s = defaultSettings();
    assert.equal(activeVault(s), undefined);
    upsertVault(s, { path: '/a', queueDirectory: '/qa' });
    upsertVault(s, { path: '/b', queueDirectory: '/qb' });
    assert.equal(activeVault(s)!.path, '/a');
    s.activeVaultPath = '/b';
    assert.equal(activeVault(s)!.path, '/b');
    s.activeVaultPath = '/gone';
    assert.equal(activeVault(s)!.path, '/a');
    upsertVault(s, { path: '/a', queueDirectory: '/new' });
    assert.deepEqual(s.vaults, [{ path: '/a', queueDirectory: '/new' }, { path: '/b', queueDirectory: '/qb' }]);
  });

  test('coreScriptPath and defaultQueueDirectory', () => {
    assert.equal(coreScriptPath({ ...defaultSettings(), productRoot: '/p' }), '/p/scripts/claude-obsidian.py');
    assert.equal(defaultQueueDirectory('/x/My Vault'), path.join(os.homedir(), 'Documents', 'Distill Queue', 'My Vault'));
  });
});

describe('detectProductRoot and SettingsStore', () => {
  let dir: string;
  beforeEach(() => {
    dir = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-settings-')));
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  test('detectProductRoot walks up to the checkout; none found is ""', () => {
    fs.mkdirSync(path.join(dir, 'scripts'));
    fs.writeFileSync(path.join(dir, 'scripts', 'claude-obsidian.py'), '');
    const deep = path.join(dir, 'a', 'b');
    fs.mkdirSync(deep, { recursive: true });
    assert.equal(detectProductRoot(deep), dir);
    assert.equal(detectProductRoot(dir), dir);
    // An empty scripts/ folder is not a checkout either.
    const empty = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-empty-')));
    try {
      fs.mkdirSync(path.join(empty, 'scripts'));
      assert.notEqual(detectProductRoot(empty), empty);
    } finally {
      fs.rmSync(empty, { recursive: true, force: true });
    }
    // The script must be in scripts/, not next to it.
    const loose = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-loose-')));
    try {
      fs.writeFileSync(path.join(loose, 'claude-obsidian.py'), '');
      assert.notEqual(detectProductRoot(loose), loose);
    } finally {
      fs.rmSync(loose, { recursive: true, force: true });
    }
    const other = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-noroot-')));
    try {
      // Only meaningful when nothing above the temp dir is a checkout.
      if (!fs.existsSync('/scripts/claude-obsidian.py')) assert.equal(detectProductRoot('/'), '');
      assert.notEqual(detectProductRoot(other), other);
    } finally {
      fs.rmSync(other, { recursive: true, force: true });
    }
  });

  test('an object file loads without a copy; a list is set aside and loads defaults', () => {
    const file = path.join(dir, 'settings.json');
    fs.writeFileSync(file, '{"model":"opus"}');
    const ok = new SettingsStore(file);
    assert.equal(ok.load().model, 'opus');
    assert.equal(ok.preserved, undefined);
    fs.writeFileSync(file, '["not", "settings"]');
    const bad = new SettingsStore(file);
    assert.deepEqual(bad.load(), defaultSettings());
    assert.equal(fs.readFileSync(bad.preserved!, 'utf8'), '["not", "settings"]');
    // Saving over it no longer carries the list's junk.
    bad.save(defaultSettings());
    assert.equal(JSON.parse(fs.readFileSync(file, 'utf8')).model, 'sonnet');
  });

  test('save keeps unknown keys across two saves', () => {
    const file = path.join(dir, 'settings.json');
    fs.writeFileSync(file, '{"future":{"a":1}}');
    const store = new SettingsStore(file);
    store.save(store.load());
    store.save({ ...store.load(), model: 'opus' });
    const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(saved.future, { a: 1 });
    assert.equal(saved.model, 'opus');
  });
});
