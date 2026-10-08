/**
 * Action buttons: buttons on an action type that run an automation's command (action-buttons.md).
 * Pure helpers here (reading buttons from settings, the template values of an item, the approvals
 * file); running and the item's results live in the actions service.
 */
import fs from 'node:fs';
import path from 'node:path';
import type { ActionButton, ActionItem, ActionPreferences, ActionStatus } from '../contracts.js';
import type { TemplateValues } from '../collectors/commands.js';
import { writeFileAtomic } from '../store/json.js';

const STATUSES: ActionStatus[] = ['pending', 'open', 'drafting', 'ready', 'creating', 'created', 'done', 'sent', 'removed', 'dismissed'];

/** A type's buttons from Settings, read leniently: a button this build can't read is skipped. */
export function buttonsFor(prefs: ActionPreferences, typeId: string): ActionButton[] {
  const raw = (prefs.types[typeId] as { buttons?: unknown } | undefined)?.buttons;
  if (!Array.isArray(raw)) return [];
  const out: ActionButton[] = [];
  raw.forEach((b, i) => {
    const n = normalizeButton(b, i === 0 ? 'primary' : 'more');
    if (n) out.push(n);
  });
  return out;
}

export function normalizeButton(raw: unknown, defaultSlot: ActionButton['slot'] = 'primary'): ActionButton | undefined {
  if (!raw || typeof raw !== 'object') return undefined;
  const b = raw as Record<string, unknown>;
  const str = (v: unknown) => (typeof v === 'string' ? v : '');
  const id = str(b.id);
  const scriptId = str(b.scriptId);
  const commandId = str(b.commandId);
  if (!id || !scriptId || !commandId) return undefined;
  const bindings: Record<string, string> = {};
  if (b.bindings && typeof b.bindings === 'object') {
    for (const [k, v] of Object.entries(b.bindings as Record<string, unknown>)) if (typeof v === 'string') bindings[k] = v;
  }
  const slot = b.slot === 'send' || b.slot === 'primary' || b.slot === 'more' ? b.slot : defaultSlot;
  const onSuccess = b.onSuccess === 'markSent' || b.onSuccess === 'complete' ? b.onSuccess : 'none';
  const when = Array.isArray(b.when) ? b.when.filter((s): s is ActionStatus => STATUSES.includes(s as ActionStatus)) : undefined;
  return {
    id,
    label: str(b.label).trim() || 'Run',
    icon: typeof b.icon === 'string' && b.icon ? b.icon : null,
    enabled: b.enabled !== false,
    scriptId,
    commandId,
    bindings,
    confirm: b.confirm !== false,
    onSuccess,
    storeResult: b.storeResult !== false,
    when: when && when.length > 0 ? when : ['open', 'ready'],
    slot,
  };
}

/** What `{placeholders}` mean for an item. Every key is known (an empty one is ""), so a typo is an error. */
export function templateValues(
  item: ActionItem,
  o: { fieldKeys: string[]; noteTitle?: string | null; notePath?: string | null; vaultPath?: string | null; now: Date },
): TemplateValues {
  const src = item.source;
  const quote = src.kind === 'manual' ? '' : (src.quote ?? '');
  const raw = src.kind !== 'manual' ? src.raw : undefined;
  const wiki = src.kind !== 'manual' ? src.wiki : undefined;
  const v: TemplateValues = {
    title: item.title,
    body: item.body ?? '',
    summary: item.summary ?? '',
    why: item.why ?? '',
    labels: (item.labels ?? []).join(', '),
    quote,
    excerpt: raw?.excerpt ?? quote,
    note_title: o.noteTitle ?? '',
    note_path: o.notePath ?? '',
    'source.raw': raw?.path ?? '',
    'source.wiki': wiki?.[0]?.path ?? '',
    'external.key': item.external?.key ?? '',
    'external.url': item.external?.url ?? '',
    'item.id': item.id,
    type: item.type,
    today: o.now.toISOString().slice(0, 10),
    now: o.now.toISOString(),
    vault: item.vaultPath ?? o.vaultPath ?? '',
  };
  for (const k of new Set([...o.fieldKeys, ...Object.keys(item.fields)])) v[`fields.${k}`] = item.fields[k] ?? '';
  // The prompt aliases, so Insert field offers one list.
  const f = item.fields;
  Object.assign(v, {
    recipient: f.to ?? '',
    project: f.project ?? '',
    issue_type: f.issueType ?? '',
    priority: f.priority ?? '',
    assignee: f.assignee ?? '',
    space: f.space ?? '',
    parent: f.parent ?? '',
  });
  return v;
}

/** The sample a button is previewed on in Settings when the type has no item yet. */
export function sampleItem(typeId: string, fieldKeys: string[]): ActionItem {
  const fields: Record<string, string> = {};
  for (const k of fieldKeys) fields[k] = k === 'to' ? '#general' : k === 'project' ? 'PX' : k === 'due' ? '2026-10-10' : `sample ${k}`;
  return {
    id: 'act-sample',
    type: typeId,
    status: 'open',
    title: 'Sample: book the tasting room for Saturday',
    body: 'Hi team, I booked the tasting room for Saturday at 3 PM.',
    summary: 'A sample item, so the preview shows real values.',
    fields,
    why: 'You said you would book it.',
    source: { kind: 'manual' },
    createdAt: '2026-10-05T12:00:00Z',
    updatedAt: '2026-10-05T12:00:00Z',
    events: [],
  };
}

/** Approved button commands: `<state>/actions/button-approvals.json`, {buttonId: {hash, at}}. Core state, not settings. */
export class ButtonApprovals {
  private map: Record<string, { hash: string; at: string }> = {};
  private loaded = false;
  constructor(private readonly file: string) {}

  private load(): void {
    if (this.loaded) return;
    this.loaded = true;
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8')) as unknown;
      if (raw && typeof raw === 'object') {
        for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
          const e = v as { hash?: unknown; at?: unknown };
          if (typeof e?.hash === 'string') this.map[k] = { hash: e.hash, at: typeof e.at === 'string' ? e.at : '' };
        }
      }
    } catch {
      // none yet
    }
  }

  approved(buttonId: string, hash: string): boolean {
    this.load();
    return this.map[buttonId]?.hash === hash;
  }

  approve(buttonId: string, hash: string, at: Date): void {
    this.load();
    this.map[buttonId] = { hash, at: at.toISOString() };
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    writeFileAtomic(this.file, JSON.stringify(this.map, null, 2));
  }
}
