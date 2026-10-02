import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  DEFAULT_ASK_PREFERENCES,
  DEFAULT_LABELING_PREFERENCES,
  DEFAULT_SOURCE_TAXONOMY,
  type AITask,
  type AskPreferences,
  type LabelingPreferences,
  type LabelMatch,
  type ModelSelection,
  type Settings,
  type SourceDefinition,
  type SourceGroup,
  type VaultProfile,
} from '../contracts.js';
import { bool, encodeJSON, isObject, num, readJSON, str, strArray, writeFileAtomic, type JSONObject } from './json.js';

export const DEFAULT_RUNNER_ID = 'claude-code';
export const AI_TASKS: AITask[] = ['ingest', 'ask', 'labelSuggest', 'imageText'];

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
  'labeling',
  'shortcuts',
  'runnerOptions',
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
  const labeling = decodeLabeling(raw.labeling);
  if (labeling) s.labeling = labeling;
  const shortcuts = decodeShortcuts(raw.shortcuts);
  if (shortcuts) s.shortcuts = shortcuts;
  const runnerOptions = decodeRunnerOptions(raw.runnerOptions);
  if (runnerOptions) s.runnerOptions = runnerOptions;
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
  if (s.labeling != null) out.labeling = { ...s.labeling };
  if (s.shortcuts != null) out.shortcuts = { ...s.shortcuts };
  if (s.runnerOptions != null) {
    const ro: JSONObject = {};
    for (const [id, options] of Object.entries(s.runnerOptions)) ro[id] = { ...options };
    out.runnerOptions = ro;
  }
  return out;
}

export class SettingsStore {
  private raw: JSONObject = {};

  constructor(readonly file: string) {}

  load(): Settings {
    const raw = readJSON(this.file);
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
