/**
 * Settings keys in the words Settings shows (the Mac app's Settings window), for the activity log:
 * "Changed settings: Ask history (Keep history off)" instead of "askPreferences.keepHistory".
 *
 * This table is the one place the core names settings. Section titles and most labels are the
 * Mac's own strings (`clients/macos/Sources/Distill/SettingsCatalog.swift` and the Settings views);
 * activity.test.ts checks they still appear there. Keys not in the table fall back to the raw key.
 */
import { DEFAULT_QUEUE_SCAN_MINUTES, type AITask, type Settings } from '../contracts.js';
import { actionPreferences, askPreferences, labelingPreferences, selectionFor } from '../store/settings.js';
import { isSecretKey } from './redact.js';

/** Settings → section titles, as the Settings sidebar shows them (SettingsSection.title). */
export const SETTINGS_SECTIONS = {
  vaults: 'Vaults',
  batching: 'Batching',
  sources: 'Sources',
  labels: 'Labels',
  askHistory: 'Ask history',
  shortcuts: 'Keyboard shortcuts',
  runners: 'AI runners',
  advanced: 'Advanced',
  models: 'Models for tasks',
  actions: 'Actions',
  todo: 'To-do defaults',
} as const;

type Section = (typeof SETTINGS_SECTIONS)[keyof typeof SETTINGS_SECTIONS];

export interface SettingLabel {
  section: Section;
  /** The setting's name in Settings. */
  label: string;
  /** A value in words ("On", "15 minutes", "Any label"). Absent: shown as it is. */
  word?: (v: unknown) => string;
  /** The short phrase for the summary's parentheses; default "Label on/off" for switches, "Label: value" otherwise. */
  phrase?: (v: unknown) => string;
  /** Never show values (prompts, options that may hold URLs, lists): "changed". */
  hidden?: boolean;
}

// ───────────── value words ─────────────

const RUNNERS: Record<string, string> = {
  'claude-code': 'Claude Code',
  codex: 'Codex',
  openrouter: 'OpenRouter',
  openai: 'OpenAI API',
  'ai-sdk': 'Vercel AI SDK',
};

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const onOff = (v: unknown) => (v ? 'On' : 'Off');

/** 15 → "15 minutes", 90 → "1 hour 30 minutes", 1440 → "1 day". */
export function minutesWords(v: unknown): string {
  const total = Math.max(0, Math.trunc(Number(v) || 0));
  const d = Math.floor(total / 1440);
  const h = Math.floor((total % 1440) / 60);
  const m = total % 60;
  const parts = [d ? plural(d, 'day') : '', h ? plural(h, 'hour') : '', m ? plural(m, 'minute') : ''].filter(Boolean);
  return parts.length ? parts.join(' ') : '0 minutes';
}

/** 600 → "10 minutes", 90 → "1 minute 30 seconds". */
function secondsWords(v: unknown): string {
  const total = Math.max(0, Math.trunc(Number(v) || 0));
  const m = Math.floor(total / 60);
  const s = total % 60;
  const parts = [m ? plural(m, 'minute') : '', s ? plural(s, 'second') : ''].filter(Boolean);
  return parts.length ? parts.join(' ') : '0 seconds';
}

/** The queue check, as Settings' menu says it (QueueScanInterval.label). */
function queueScanWords(v: unknown): string {
  const n = v === null || v === undefined ? DEFAULT_QUEUE_SCAN_MINUTES : Math.trunc(Number(v));
  if (!(n > 0)) return 'Off';
  if (n === 1) return 'Every minute';
  if (n === 60) return 'Every hour';
  if (n % 60 === 0) return `Every ${n / 60} hours`;
  return `Every ${n} min`;
}

const days = (v: unknown) => plural(Math.trunc(Number(v) || 0), 'day');
const actionHistory = (v: unknown) => {
  const n = Math.trunc(Number(v) || 0);
  return n <= 0 ? 'Forever' : n === 365 ? '1 year' : days(n);
};
const runner = (id: unknown) => RUNNERS[String(id)] ?? String(id);
const selection = (v: unknown) => {
  if (!v || typeof v !== 'object') return 'Default';
  const s = v as { runnerID?: string; model?: string; effort?: string | null };
  return [runner(s.runnerID), s.model, s.effort].filter(Boolean).join(' · ');
};
const runners = (v: unknown) => (Array.isArray(v) && v.length ? v.map(runner).join(', ') : 'None');
const count = (one: string, many?: string) => (v: unknown) => plural(Array.isArray(v) ? v.length : 0, one, many);
const shortcut = (v: unknown) => (v ? String(v) : 'Off');
const lastPart = (v: unknown) => (v ? String(v).replace(/\/+$/, '').split('/').pop() || String(v) : 'None');
const pathWords = (v: unknown) => (v ? String(v) : 'Default');
const choice = (words: Record<string, string>) => (v: unknown) => words[String(v)] ?? String(v);

// ───────────── the table ─────────────

const S = SETTINGS_SECTIONS;
const switchFor = (section: Section, label: string): SettingLabel => ({ section, label, word: onOff });
const sourceName = { notes: 'Notes', ask: 'Ask answers' } as const;

/**
 * Dotted paths (one `*` stands for any key at that level). The most specific entry wins; a path
 * whose entry is an object (taskDefaults.ingest) covers everything under it.
 */
export const SETTING_LABELS: Record<string, SettingLabel> = {
  // General → Vaults
  vaults: { section: S.vaults, label: 'Vaults', word: count('vault') },
  activeVaultPath: { section: S.vaults, label: 'Active vault', word: lastPart },
  // General → Batching
  autoProcessEnabled: switchFor(S.batching, 'Automatic batching'),
  batchIntervalMinutes: { section: S.batching, label: 'Batch every', word: minutesWords, phrase: (v) => `Batch every ${minutesWords(v)}` },
  settleSeconds: { section: S.batching, label: 'Wait before picking up a file', word: secondsWords, phrase: (v) => `Wait ${secondsWords(v)}` },
  queueScanMinutes: { section: S.batching, label: 'Check the queue folder for changes', word: queueScanWords, phrase: (v) => `Queue check ${queueScanWords(v).toLowerCase()}` },
  // General → Sources
  sourceTaxonomy: { section: S.sources, label: 'Sources', hidden: true },
  // General → Labels (the Ask defaults for labels live here)
  'askPreferences.labelMatch': {
    section: S.labels,
    label: 'When Ask is limited to several labels, use notes with',
    word: choice({ any: 'Any label', all: 'All labels' }),
    phrase: (v) => `Use notes with ${choice({ any: 'any label', all: 'all labels' })(v)}`,
  },
  'askPreferences.includeUnconfirmed': switchFor(S.labels, 'Include unconfirmed labels'),
  'labeling.autoLabelQueueFolder': switchFor(S.labels, 'Queue folder: label automatically'),
  'labeling.cliFallbackToAI': switchFor(S.labels, 'CLI: use AI labels if none are sent back'),
  // General → Ask history (the canvas's "settings changed" card: "Keep history On → Off", "Days")
  'askPreferences.keepHistory': switchFor(S.askHistory, 'Keep history'),
  'askPreferences.historyDays': { section: S.askHistory, label: 'Days', word: days, phrase: (v) => `Keep chats ${days(v)}` },
  // General → Keyboard shortcuts
  'shortcuts.ask': { section: S.shortcuts, label: 'Ask a question', word: shortcut },
  'shortcuts.addNote': { section: S.shortcuts, label: 'Add a note', word: shortcut },
  // AI → AI runners, and Advanced at the end of it
  enabledRunners: { section: S.runners, label: 'Runners turned on', word: runners },
  'runnerOptions.*': { section: S.runners, label: 'Runner options', hidden: true },
  model: { section: S.advanced, label: 'Specific model' },
  claudePath: { section: S.advanced, label: 'claude CLI', word: pathWords },
  pythonPath: { section: S.advanced, label: 'python3', word: pathWords },
  nodePath: { section: S.advanced, label: 'node', word: pathWords },
  productRoot: { section: S.advanced, label: 'Product root', word: pathWords },
  extraAllowedTools: { section: S.advanced, label: 'Extra allowed tools', word: count('rule') },
  // AI → Models for tasks
  'taskDefaults.ingest': { section: S.models, label: 'Adding notes', word: selection },
  'taskDefaults.ask': { section: S.models, label: 'Ask a question', word: selection },
  'taskDefaults.labelSuggest': { section: S.models, label: 'Label suggestions', word: selection },
  'taskDefaults.imageText': { section: S.models, label: 'Text from images', word: selection },
  'taskDefaults.actionFind': { section: S.models, label: 'Finding actions', word: selection },
  'taskDefaults.actionDraft': { section: S.models, label: 'Action drafts', word: selection },
  'taskDefaults.actionImprove': { section: S.models, label: 'Improving drafts', word: selection },
  'taskDefaults.recovery': { section: S.models, label: 'Recovery', word: selection },
  // Actions and connections → Actions
  ...Object.fromEntries(
    (['notes', 'ask'] as const).flatMap((src) => [
      [`actionPreferences.sources.${src}.detectTodos`, switchFor(S.actions, `${sourceName[src]}: detect to-dos`)],
      [`actionPreferences.sources.${src}.detectTypes`, switchFor(S.actions, `${sourceName[src]}: detect action types`)],
      [`actionPreferences.sources.${src}.confirm`, switchFor(S.actions, `${sourceName[src]}: ask me to confirm before adding`)],
    ]),
  ),
  'actionPreferences.types.*': { section: S.actions, label: 'Action type settings', hidden: true },
  'actionPreferences.findSelection': { section: S.actions, label: 'Model for finding actions', word: selection },
  'actionPreferences.findPrompt': { section: S.actions, label: 'Prompt for finding actions', hidden: true },
  // Actions and connections → To-do defaults
  'actionPreferences.todo.defaultGroup': { section: S.todo, label: 'Group by', word: choice({ due: 'Due date', note: 'Note', none: 'None' }) },
  'actionPreferences.todo.defaultSort': {
    section: S.todo,
    label: 'Sort',
    word: choice({ due: 'Due date, soonest first', created: 'Date added, newest first', priority: 'Priority, highest first', note: 'Note' }),
  },
  'actionPreferences.todo.remindOverdue': switchFor(S.todo, 'Remind me of overdue to-dos'),
  'actionPreferences.historyDays': { section: S.todo, label: 'Keep action history', word: actionHistory },
};

// ───────────── describing a change ─────────────

const isPlain = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Settings with the contract defaults filled in, so "— → false" reads "On → Off". */
function withDefaults(s: Settings): Record<string, unknown> {
  return {
    ...(s as unknown as Record<string, unknown>),
    queueScanMinutes: s.queueScanMinutes ?? DEFAULT_QUEUE_SCAN_MINUTES,
    askPreferences: askPreferences(s),
    labeling: labelingPreferences(s),
    shortcuts: { ask: null, addNote: null, ...(s.shortcuts ?? {}) },
    actionPreferences: actionPreferences(s),
    taskDefaults: Object.fromEntries(AI_TASKS.map((task) => [task, selectionFor(s, task)])),
  };
}

const AI_TASKS: AITask[] = ['ingest', 'ask', 'labelSuggest', 'imageText', 'actionFind', 'actionDraft', 'actionImprove', 'recovery'];

/** Leaf paths (objects walked; arrays and primitives are leaves). */
function leaves(v: unknown, prefix: string, out: Map<string, unknown>, depth = 0): void {
  if (isPlain(v) && depth < 5) {
    for (const [k, x] of Object.entries(v)) leaves(x, prefix ? `${prefix}.${k}` : k, out, depth + 1);
  } else if (prefix) out.set(prefix, v);
}

/** The table entry covering a leaf path: the longest matching prefix, `*` matching one key. */
export function settingLabelFor(leaf: string): { key: string; entry: SettingLabel } | undefined {
  const parts = leaf.split('.');
  for (let n = parts.length; n > 0; n--) {
    const prefix = parts.slice(0, n);
    const exact = prefix.join('.');
    if (SETTING_LABELS[exact]) return { key: exact, entry: SETTING_LABELS[exact] };
    const wild = [...prefix.slice(0, -1), '*'].join('.');
    if (SETTING_LABELS[wild]) return { key: exact, entry: SETTING_LABELS[wild] };
  }
  return undefined;
}

const at = (obj: Record<string, unknown>, dotted: string) =>
  dotted.split('.').reduce<unknown>((v, k) => (isPlain(v) ? v[k] : undefined), obj);

const raw = (v: unknown) => (v === undefined || v === null ? '—' : typeof v === 'string' ? v : JSON.stringify(v));
const short = (s: string) => (s.length > 60 ? `${s.slice(0, 59)}…` : s);

export interface SettingsDescription {
  /** "Ask history (Keep history off), Batching (Batch every 15 minutes)" */
  summary: string;
  /** One line per setting, in Settings' words: "Keep history: On → Off", "Runner options: changed". */
  lines: string[];
}

/** What changed between two settings, in the words Settings uses. Unknown keys keep their raw dotted key. */
export function describeSettingsChanges(before: Settings | undefined, after: Settings): SettingsDescription {
  if (!before) return { summary: '', lines: [] };
  const a = withDefaults(before);
  const b = withDefaults(after);
  const la = new Map<string, unknown>();
  const lb = new Map<string, unknown>();
  leaves(a, '', la);
  leaves(b, '', lb);
  const changed = [...new Set([...la.keys(), ...lb.keys()])].filter((k) => JSON.stringify(la.get(k)) !== JSON.stringify(lb.get(k))).sort();

  const lines: string[] = [];
  const phrases = new Map<string, string[]>(); // section (or raw key) → phrases
  const seen = new Set<string>();
  const addPhrase = (group: string, phrase: string | undefined) => {
    const list = phrases.get(group) ?? [];
    if (phrase && !list.includes(phrase)) list.push(phrase);
    phrases.set(group, list);
  };

  for (const leaf of changed) {
    const found = settingLabelFor(leaf);
    const secret = leaf.split('.').some((k) => isSecretKey(k));
    if (!found) {
      // Unknown: the raw key, values only for short primitives.
      const x = la.get(leaf);
      const y = lb.get(leaf);
      const primitive = (v: unknown) => v === null || v === undefined || ['string', 'number', 'boolean'].includes(typeof v);
      lines.push(!secret && primitive(x) && primitive(y) ? `${leaf}: ${short(raw(x))} → ${short(raw(y))}` : `${leaf}: changed`);
      addPhrase(leaf, undefined);
      continue;
    }
    const { key, entry } = found;
    if (seen.has(key)) continue;
    seen.add(key);
    const x = at(a, key);
    const y = at(b, key);
    if (entry.hidden || secret) {
      lines.push(`${entry.label}: changed`);
      addPhrase(entry.section, entry.label);
      continue;
    }
    const word = entry.word ?? ((v: unknown) => short(raw(v)));
    lines.push(`${entry.label}: ${short(word(x))} → ${short(word(y))}`);
    const phrase = entry.phrase
      ? entry.phrase(y)
      : typeof y === 'boolean'
        ? `${entry.label} ${y ? 'on' : 'off'}`
        : typeof y === 'number' || (typeof y === 'string' && y.length <= 24 && !y.includes('/'))
          ? `${entry.label}: ${word(y)}`
          : entry.label;
    addPhrase(entry.section, phrase);
  }

  const groups = [...phrases.entries()].map(([group, list]) => {
    if (list.length === 0) return group;
    const shown = list.length > 2 ? [...list.slice(0, 2), `${list.length - 2} more`] : list;
    return `${group} (${shown.join(', ')})`;
  });
  const summary = groups.length > 3 ? `${groups.slice(0, 3).join(', ')} and ${groups.length - 3} more` : groups.join(', ');
  return { summary, lines };
}

/** The sections a patch touches, for a failed change ("Couldn't change settings: Batching"). */
export function settingsPatchSections(patch: Record<string, unknown> | undefined): string {
  const out = new Map<string, true>();
  const paths = new Map<string, unknown>();
  leaves(patch ?? {}, '', paths);
  for (const leaf of paths.keys()) out.set(settingLabelFor(leaf)?.entry.section ?? leaf.split('.')[0]!, true);
  return [...out.keys()].join(', ');
}
