import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_ACTION_PREFERENCES,
  DEFAULT_ASK_PREFERENCES,
  DEFAULT_RECOVERY_PREFERENCES,
  type RecoveryPreferences,
  DEFAULT_LABELING_PREFERENCES,
  DEFAULT_SOURCE_TAXONOMY,
  type AITask,
  type ActionPerson,
  type ActionPreferences,
  type ActionSourcePreferences,
  type ActionTypePreferences,
  type AskPreferences,
  type LabelingPreferences,
  type LabelMatch,
  type ModelSelection,
  type Settings,
  type SourceDefinition,
  type SourceGroup,
  type VaultProfile,
} from '../contracts.js';
import { bool, encodeJSON, isObject, num, preserveUnreadable, readJSON, str, strArray, writeFileAtomic, type JSONObject } from './json.js';

export const DEFAULT_RUNNER_ID = 'claude-code';
export const AI_TASKS: AITask[] = ['ingest', 'ask', 'labelSuggest', 'imageText', 'actionFind', 'actionDraft', 'actionImprove', 'recovery'];

/** Keys the core understands; everything else in settings.json is carried through untouched. */
const KNOWN_KEYS = [
  'vaults',
  'activeVaultPath',
  'batchIntervalMinutes',
  'settleSeconds',
  'model',
  'claudePath',
  'pythonPath',
  'productRoot',
  'extraAllowedTools',
  'autoProcessEnabled',
  'enabledRunners',
  'taskDefaults',
  'nodePath',
  'sourceTaxonomy',
  'askPreferences',
  'recovery',
  'labeling',
  'shortcuts',
  'runnerOptions',
  'actionPreferences',
  'queueScanMinutes',
  'batchSourceTokens',
  'detailLevel',
] as const;

/**
 * The claude-obsidian checkout this core runs from (contains
 * scripts/claude-obsidian.py). Mirrors Swift's Info.plist
 * `ClaudeObsidianProductRoot`: a fresh install points at its own checkout.
 */
export function detectProductRoot(start = path.dirname(fileURLToPath(import.meta.url))): string {
  let dir = start;
  for (;;) {
    if (fs.existsSync(path.join(dir, 'scripts', 'claude-obsidian.py'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) return '';
    dir = parent;
  }
}

export function defaultSettings(): Settings {
  return {
    vaults: [],
    batchIntervalMinutes: 10,
    settleSeconds: 600,
    model: 'sonnet',
    claudePath: path.join(os.homedir(), '.local', 'bin', 'claude'),
    pythonPath: '/usr/bin/python3',
    productRoot: detectProductRoot(),
    extraAllowedTools: [],
    autoProcessEnabled: true,
    enabledRunners: [DEFAULT_RUNNER_ID],
    taskDefaults: {},
  };
}

function decodeVault(v: unknown): VaultProfile | undefined {
  if (!isObject(v)) return undefined;
  const p = str(v.path);
  const q = str(v.queueDirectory);
  return p !== undefined && q !== undefined ? { path: p, queueDirectory: q } : undefined;
}

function decodeSelection(v: unknown): ModelSelection | undefined {
  if (!isObject(v)) return undefined;
  const runnerID = str(v.runnerID);
  const model = str(v.model);
  if (runnerID === undefined || model === undefined) return undefined;
  const effort = str(v.effort);
  return effort === undefined ? { runnerID, model } : { runnerID, model, effort };
}

function decodeSource(v: unknown): SourceDefinition | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const label = str(v.label);
  return id !== undefined && label !== undefined ? { id, label } : undefined;
}

function decodeSourceGroup(v: unknown): SourceGroup | undefined {
  if (!isObject(v)) return undefined;
  const id = str(v.id);
  const label = str(v.label);
  if (id === undefined || label === undefined) return undefined;
  const sources = Array.isArray(v.sources)
    ? v.sources.map(decodeSource).filter((x): x is SourceDefinition => x !== undefined)
    : [];
  return { id, label, sources };
}

function decodeAskPreferences(v: unknown): Partial<AskPreferences> | undefined {
  if (!isObject(v)) return undefined;
  const out: Partial<AskPreferences> = {};
  if (v.labelMatch === 'any' || v.labelMatch === 'all') out.labelMatch = v.labelMatch as LabelMatch;
  const includeUnconfirmed = bool(v.includeUnconfirmed);
  if (includeUnconfirmed !== undefined) out.includeUnconfirmed = includeUnconfirmed;
  const keepHistory = bool(v.keepHistory);
  if (keepHistory !== undefined) out.keepHistory = keepHistory;
  const historyDays = num(v.historyDays);
  if (historyDays !== undefined) out.historyDays = Math.max(1, Math.trunc(historyDays));
  return out;
}

function decodeLabeling(v: unknown): Partial<LabelingPreferences> | undefined {
  if (!isObject(v)) return undefined;
  const out: Partial<LabelingPreferences> = {};
  const autoLabelQueueFolder = bool(v.autoLabelQueueFolder);
  if (autoLabelQueueFolder !== undefined) out.autoLabelQueueFolder = autoLabelQueueFolder;
  const cliFallbackToAI = bool(v.cliFallbackToAI);
  if (cliFallbackToAI !== undefined) out.cliFallbackToAI = cliFallbackToAI;
  return out;
}

function decodeShortcuts(v: unknown): NonNullable<Settings['shortcuts']> | undefined {
  if (!isObject(v)) return undefined;
  const out: NonNullable<Settings['shortcuts']> = {};
  for (const key of ['ask', 'addNote'] as const) {
    if (v[key] === null) out[key] = null;
    else {
      const value = str(v[key]);
      if (value !== undefined) out[key] = value;
    }
  }
  return out;
}

function decodeRunnerOptions(v: unknown): Record<string, Record<string, string>> | undefined {
  if (!isObject(v)) return undefined;
  const out: Record<string, Record<string, string>> = {};
  for (const [runnerID, options] of Object.entries(v)) {
    if (!isObject(options)) continue;
    const kept: Record<string, string> = {};
    for (const [name, value] of Object.entries(options)) {
      if (typeof value === 'string') kept[name] = value;
    }
    out[runnerID] = kept;
  }
  return out;
}

const SORTS = ['due', 'created', 'priority', 'note'] as const;
const GROUPS = ['due', 'note', 'none'] as const;
const DRAFT_WHEN = ['onFind', 'onRequest'] as const;

/** Unknown keys of a nested object, carried through so a newer build's settings survive. */
function unknownKeys(v: JSONObject, known: readonly string[]): JSONObject {
  const out: JSONObject = {};
  for (const [k, value] of Object.entries(v)) if (!known.includes(k)) out[k] = value;
  return out;
}

function optionalSelection(v: unknown): ModelSelection | null | undefined {
  if (v === null) return null;
  return decodeSelection(v);
}

function optionalString(v: unknown): string | null | undefined {
  if (v === null) return null;
  return str(v);
}

function decodeActionSource(v: unknown): Partial<ActionSourcePreferences> | undefined {
  if (!isObject(v)) return undefined;
  const known = ['detectTodos', 'detectTypes', 'disabledTypes', 'confirm'] as const;
  const out = unknownKeys(v, known) as Partial<ActionSourcePreferences>;
  for (const key of ['detectTodos', 'detectTypes', 'confirm'] as const) {
    const b = bool(v[key]);
    if (b !== undefined) out[key] = b;
  }
  const disabled = strArray(v.disabledTypes);
  if (disabled) out.disabledTypes = disabled;
  return out;
}

function decodeActionType(v: unknown): Partial<ActionTypePreferences> | undefined {
  if (!isObject(v)) return undefined;
  const known = [
    'enabled', 'draftWhen', 'improveAfterEdit', 'draftSelection', 'improveSelection', 'draftPrompt', 'improvePrompt', 'fieldDefaults', 'handlesFor',
  ] as const;
  const out = unknownKeys(v, known) as Partial<ActionTypePreferences>;
  const enabled = bool(v.enabled);
  if (enabled !== undefined) out.enabled = enabled;
  if ((DRAFT_WHEN as readonly unknown[]).includes(v.draftWhen)) out.draftWhen = v.draftWhen as ActionTypePreferences['draftWhen'];
  const improve = bool(v.improveAfterEdit);
  if (improve !== undefined) out.improveAfterEdit = improve;
  for (const key of ['draftSelection', 'improveSelection'] as const) {
    const sel = optionalSelection(v[key]);
    if (sel !== undefined) out[key] = sel;
  }
  for (const key of ['draftPrompt', 'improvePrompt'] as const) {
    const text = optionalString(v[key]);
    if (text !== undefined) out[key] = text;
  }
  if (isObject(v.fieldDefaults)) {
    const fd: Record<string, string> = {};
    for (const [k, value] of Object.entries(v.fieldDefaults)) if (typeof value === 'string') fd[k] = value;
    out.fieldDefaults = fd;
  }
  const handles = strArray(v.handlesFor);
  if (handles) out.handlesFor = [...new Set(handles)];
  return out;
}

/** actions-routing.md: People, the user ("you") first; entries without an id or a name are dropped. */
function decodePeople(v: unknown): ActionPerson[] | undefined {
  if (!Array.isArray(v)) return undefined;
  const out: ActionPerson[] = [];
  for (const e of v) {
    if (!isObject(e)) continue;
    const id = str(e.id)?.trim();
    const name = str(e.name)?.trim() ?? '';
    if (!id || out.some((x) => x.id === id) || (name === '' && id !== 'you')) continue;
    const aliases = [...new Set((strArray(e.aliases) ?? []).map((a) => a.trim()).filter(Boolean))];
    out.push({ ...(unknownKeys(e, ['id', 'name', 'aliases']) as object), id, name, aliases });
  }
  const you = out.findIndex((x) => x.id === 'you');
  if (you > 0) out.unshift(...out.splice(you, 1));
  return out;
}

/**
 * Lenient decode of `actionPreferences`: mistyped known keys are dropped (they
 * take their defaults), unknown keys at every level are kept so a newer build's
 * preferences survive a save. `historyDays <= 0` means keep forever (no clamp).
 */
export function decodeActionPreferences(v: unknown): Partial<ActionPreferences> | undefined {
  if (!isObject(v)) return undefined;
  const known = ['sources', 'types', 'findSelection', 'findPrompt', 'todo', 'historyDays', 'people'] as const;
  const out = unknownKeys(v, known) as Partial<ActionPreferences>;
  if (isObject(v.sources)) {
    const sources = unknownKeys(v.sources, ['notes', 'ask']) as JSONObject;
    for (const key of ['notes', 'ask'] as const) {
      const src = decodeActionSource(v.sources[key]);
      if (src) sources[key] = src;
    }
    out.sources = sources as unknown as ActionPreferences['sources'];
  }
  if (isObject(v.types)) {
    const types: Record<string, Partial<ActionTypePreferences>> = {};
    for (const [id, t] of Object.entries(v.types)) {
      const decoded = decodeActionType(t);
      if (decoded) types[id] = decoded;
    }
    out.types = types;
  }
  const findSelection = optionalSelection(v.findSelection);
  if (findSelection !== undefined) out.findSelection = findSelection;
  const findPrompt = optionalString(v.findPrompt);
  if (findPrompt !== undefined) out.findPrompt = findPrompt;
  if (isObject(v.todo)) {
    const todo = unknownKeys(v.todo, ['defaultSort', 'defaultGroup', 'remindOverdue']) as JSONObject;
    if ((SORTS as readonly unknown[]).includes(v.todo.defaultSort)) todo.defaultSort = v.todo.defaultSort;
    if ((GROUPS as readonly unknown[]).includes(v.todo.defaultGroup)) todo.defaultGroup = v.todo.defaultGroup;
    const remind = bool(v.todo.remindOverdue);
    if (remind !== undefined) todo.remindOverdue = remind;
    out.todo = todo as unknown as ActionPreferences['todo'];
  }
  const historyDays = num(v.historyDays);
  if (historyDays !== undefined) out.historyDays = Math.trunc(historyDays);
  const people = decodePeople(v.people);
  if (people) out.people = people;
  return out;
}

/** actionPreferences with every default filled in (nested objects merged key by key). */
export function actionPreferences(s: Settings): ActionPreferences {
  const p = s.actionPreferences ?? {};
  const d = DEFAULT_ACTION_PREFERENCES;
  const out: ActionPreferences = {
    sources: {
      notes: { ...d.sources.notes, ...(p.sources?.notes ?? {}) },
      ask: { ...d.sources.ask, ...(p.sources?.ask ?? {}) },
    },
    types: { ...d.types, ...(p.types ?? {}) },
    todo: { ...d.todo, ...(p.todo ?? {}) },
    historyDays: p.historyDays ?? d.historyDays,
  };
  if (p.findSelection !== undefined) out.findSelection = p.findSelection;
  if (p.findPrompt !== undefined) out.findPrompt = p.findPrompt;
  if (p.people !== undefined) out.people = p.people;
  return out;
}

/** Tolerant decode: missing or mistyped keys fall back to defaults (Swift `init(from:)`). */
export function decodeSettings(raw: unknown): Settings {
  const d = defaultSettings();
  if (!isObject(raw)) return d;
  const s: Settings = { ...d };
  if (Array.isArray(raw.vaults)) {
    s.vaults = raw.vaults.map(decodeVault).filter((v): v is VaultProfile => v !== undefined);
  }
  const active = str(raw.activeVaultPath);
  if (active !== undefined) s.activeVaultPath = active;
  s.batchIntervalMinutes = Math.trunc(num(raw.batchIntervalMinutes) ?? d.batchIntervalMinutes);
  s.settleSeconds = Math.trunc(num(raw.settleSeconds) ?? d.settleSeconds);
  s.model = str(raw.model) ?? d.model;
  s.claudePath = str(raw.claudePath) ?? d.claudePath;
  s.pythonPath = str(raw.pythonPath) ?? d.pythonPath;
  s.productRoot = str(raw.productRoot) ?? d.productRoot;
  s.extraAllowedTools = strArray(raw.extraAllowedTools) ?? d.extraAllowedTools;
  s.autoProcessEnabled = bool(raw.autoProcessEnabled) ?? d.autoProcessEnabled;
  s.enabledRunners = strArray(raw.enabledRunners) ?? d.enabledRunners;
  if (isObject(raw.taskDefaults)) {
    const td: Settings['taskDefaults'] = {};
    for (const [k, v] of Object.entries(raw.taskDefaults)) {
      const sel = decodeSelection(v);
      if (sel) (td as Record<string, ModelSelection>)[k] = sel;
    }
    s.taskDefaults = td;
  }
  const nodePath = str(raw.nodePath);
  if (nodePath !== undefined) s.nodePath = nodePath;
  // v2: absent (or mistyped) stays absent, so encode does not invent keys.
  if (Array.isArray(raw.sourceTaxonomy)) {
    s.sourceTaxonomy = raw.sourceTaxonomy.map(decodeSourceGroup).filter((g): g is SourceGroup => g !== undefined);
  }
  const askPreferences = decodeAskPreferences(raw.askPreferences);
  if (askPreferences) s.askPreferences = askPreferences;
  if (isObject(raw.recovery)) {
    const r = raw.recovery;
    const rec: Partial<RecoveryPreferences> = {};
    if (typeof r.automatic === 'boolean') rec.automatic = r.automatic;
    if (typeof r.maxAttempts === 'number' && Number.isFinite(r.maxAttempts)) rec.maxAttempts = Math.min(5, Math.max(1, Math.round(r.maxAttempts)));
    if (typeof r.maxCostUSD === 'number' && Number.isFinite(r.maxCostUSD)) rec.maxCostUSD = Math.min(20, Math.max(0, r.maxCostUSD));
    s.recovery = rec;
  }
  const labeling = decodeLabeling(raw.labeling);
  if (labeling) s.labeling = labeling;
  const shortcuts = decodeShortcuts(raw.shortcuts);
  if (shortcuts) s.shortcuts = shortcuts;
  const runnerOptions = decodeRunnerOptions(raw.runnerOptions);
  if (runnerOptions) s.runnerOptions = runnerOptions;
  const actionPrefs = decodeActionPreferences(raw.actionPreferences);
  if (actionPrefs) s.actionPreferences = actionPrefs;
  // v5: minutes between queue checks; 0 = Off. Absent or mistyped stays absent (= the default, 5).
  const scan = num(raw.queueScanMinutes);
  if (scan !== undefined && Number.isFinite(scan)) s.queueScanMinutes = Math.min(Math.max(0, Math.trunc(scan)), 24 * 60);
  // v10 (full reads): the batch size in tokens (absent or null = Automatic), clamped to 10K–300K.
  const tokens = num(raw.batchSourceTokens);
  if (tokens !== undefined && Number.isFinite(tokens) && tokens > 0) s.batchSourceTokens = Math.min(300_000, Math.max(10_000, Math.round(tokens)));
  // v10: detail level per source type; unknown values dropped.
  if (raw.detailLevel && typeof raw.detailLevel === 'object' && !Array.isArray(raw.detailLevel)) {
    const levels: NonNullable<Settings['detailLevel']> = {};
    for (const [k, v] of Object.entries(raw.detailLevel as Record<string, unknown>)) {
      if ((k === 'meeting' || k === 'conversation' || k === 'research' || k === 'other') && (v === 'highlights' || v === 'detailed' || v === 'nearComplete')) levels[k] = v;
    }
    if (Object.keys(levels).length > 0) s.detailLevel = levels;
  }
  return s;
}

/** Encode over the last-loaded raw object so unknown keys survive; nil optionals are omitted (Swift). */
export function encodeSettings(s: Settings, raw: JSONObject = {}): JSONObject {
  const out: JSONObject = { ...raw };
  for (const key of KNOWN_KEYS) delete out[key];
  out.vaults = s.vaults.map((v) => ({ path: v.path, queueDirectory: v.queueDirectory }));
  if (s.activeVaultPath != null) out.activeVaultPath = s.activeVaultPath;
  out.batchIntervalMinutes = s.batchIntervalMinutes;
  out.settleSeconds = s.settleSeconds;
  out.model = s.model;
  out.claudePath = s.claudePath;
  out.pythonPath = s.pythonPath;
  out.productRoot = s.productRoot;
  out.extraAllowedTools = [...s.extraAllowedTools];
  out.autoProcessEnabled = s.autoProcessEnabled;
  out.enabledRunners = [...s.enabledRunners];
  const td: JSONObject = {};
  for (const [k, sel] of Object.entries(s.taskDefaults)) {
    if (!sel) continue;
    td[k] = sel.effort != null ? { runnerID: sel.runnerID, model: sel.model, effort: sel.effort } : { runnerID: sel.runnerID, model: sel.model };
  }
  out.taskDefaults = td;
  if (s.nodePath != null) out.nodePath = s.nodePath;
  if (s.sourceTaxonomy != null) {
    out.sourceTaxonomy = s.sourceTaxonomy.map((g) => ({
      id: g.id,
      label: g.label,
      sources: g.sources.map((src) => ({ id: src.id, label: src.label })),
    }));
  }
  if (s.askPreferences != null) out.askPreferences = { ...s.askPreferences };
  if (s.recovery != null) out.recovery = { ...s.recovery };
  if (s.labeling != null) out.labeling = { ...s.labeling };
  if (s.shortcuts != null) out.shortcuts = { ...s.shortcuts };
  if (s.runnerOptions != null) {
    const ro: JSONObject = {};
    for (const [id, options] of Object.entries(s.runnerOptions)) ro[id] = { ...options };
    out.runnerOptions = ro;
  }
  // Decoded with its unknown keys kept, so a plain deep copy round-trips.
  if (s.actionPreferences != null) out.actionPreferences = JSON.parse(JSON.stringify(s.actionPreferences)) as JSONObject;
  if (s.queueScanMinutes != null) out.queueScanMinutes = s.queueScanMinutes;
  if (s.batchSourceTokens != null) out.batchSourceTokens = s.batchSourceTokens;
  if (s.detailLevel != null && Object.keys(s.detailLevel).length > 0) out.detailLevel = { ...s.detailLevel };
  return out;
}

export class SettingsStore {
  private raw: JSONObject = {};

  constructor(readonly file: string) {}

  /** Path of the copy kept by the last load, when settings.json couldn't be read. */
  preserved?: string;

  load(): Settings {
    const raw = readJSON(this.file);
    if (!isObject(raw)) this.preserved = preserveUnreadable(this.file) ?? this.preserved;
    this.raw = isObject(raw) ? raw : {};
    return decodeSettings(raw);
  }

  save(s: Settings): void {
    const encoded = encodeSettings(s, this.raw);
    writeFileAtomic(this.file, encodeJSON(encoded));
    this.raw = encoded;
  }
}

// ───────────── derived values (Swift `WorkerSettings` computed properties) ─────────────

/** Used when Settings has no explicit choice for the task (Swift `AITask.fallbackModel`). */
export function fallbackModel(task: AITask): string {
  return task === 'labelSuggest' ? 'haiku' : 'sonnet';
}

/** Before per-task settings existed, `model` was the one model for the agentic tasks. */
export function defaultSelection(s: Settings, task: AITask): ModelSelection {
  // Text from images: fast and cheap for reading screenshots (Swift `SettingsEdits.fallbackSelection`).
  if (task === 'imageText') return { runnerID: DEFAULT_RUNNER_ID, model: 'haiku', effort: 'low' };
  // Finding actions: Sonnet at medium effort (lead decision 2026-10-02).
  if (task === 'actionFind') return { runnerID: DEFAULT_RUNNER_ID, model: 'sonnet', effort: 'medium' };
  // Recovery (review-queue.md, owner 2026-10-05: "we default use the opus"): Opus at medium effort.
  if (task === 'recovery') return { runnerID: DEFAULT_RUNNER_ID, model: 'opus', effort: 'medium' };
  const legacy = task === 'ingest' || task === 'ask' ? s.model : fallbackModel(task);
  return { runnerID: DEFAULT_RUNNER_ID, model: legacy, effort: null };
}

export function selectionFor(s: Settings, task: AITask): ModelSelection {
  return s.taskDefaults[task] ?? defaultSelection(s, task);
}

/** v2 preferences with the contract defaults filled in (settings.json keeps only what the user set). */
export function labelingPreferences(s: Settings): LabelingPreferences {
  return { ...DEFAULT_LABELING_PREFERENCES, ...(s.labeling ?? {}) };
}

export function recoveryPreferences(s: Settings): RecoveryPreferences {
  return { ...DEFAULT_RECOVERY_PREFERENCES, ...(s.recovery ?? {}) };
}

export function askPreferences(s: Settings): AskPreferences {
  return { ...DEFAULT_ASK_PREFERENCES, ...(s.askPreferences ?? {}) };
}

export function sourceTaxonomy(s: Settings): SourceGroup[] {
  return s.sourceTaxonomy ?? DEFAULT_SOURCE_TAXONOMY;
}

export function activeVault(s: Settings): VaultProfile | undefined {
  return s.vaults.find((v) => v.path === s.activeVaultPath) ?? s.vaults[0];
}

export function coreScriptPath(s: Settings): string {
  return path.join(s.productRoot, 'scripts', 'claude-obsidian.py');
}

export function defaultQueueDirectory(vaultPath: string): string {
  return path.join(os.homedir(), 'Documents', 'Distill Queue', path.basename(vaultPath));
}

export function upsertVault(s: Settings, profile: VaultProfile): void {
  const i = s.vaults.findIndex((v) => v.path === profile.path);
  if (i >= 0) s.vaults[i] = profile;
  else s.vaults.push(profile);
}
