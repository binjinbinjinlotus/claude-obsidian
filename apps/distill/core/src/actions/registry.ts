/**
 * Action types and handlers are data. Adding a type is one more entry in
 * BUILTIN_TYPES (or a registerActionType call); adding a handler is one
 * registerHandler call. Nothing here changes the contract: clients render
 * every type from ActionTypeInfo.
 *
 * Spec: apps/distill/docs/specs/actions.md
 */
import type {
  ActionFieldSpec,
  ActionHandlerInfo,
  ActionItem,
  ActionPreferences,
  ActionTypeInfo,
  ActionTypePreferences,
  ModelSelection,
  Settings,
} from '../contracts.js';

export const TODO_TYPE = 'todo';

export interface HandlerSpec {
  id: string;
  label: string;
  /** Reserved for later: listed but never available ("Later"). */
  reserved?: boolean;
  /** Needs the type's connection to be connected. */
  needsConnection?: boolean;
}

export interface ActionTypeDef {
  id: string;
  label: string;
  pluralLabel: string;
  /** What the find prompt matches to this type. */
  recognizes: string;
  /** Listed but disabled (coming later). */
  reserved?: boolean;
  fields: ActionFieldSpec[];
  handlers: HandlerSpec[];
  connectionID?: string;
  defaults: { enabled: boolean; draftWhen: 'onFind' | 'onRequest'; improveAfterEdit: boolean };
  /** Built-in prompts (null = the type has no draft / improve pass). */
  draftPrompt: string | null;
  improvePrompt: string | null;
  placeholders: string[];
}

/** Placeholders every prompt may use; type-specific ones are added per type. */
export const COMMON_PLACEHOLDERS = ['{title}', '{body}', '{why}', '{excerpt}', '{note_title}', '{note_path}', '{labels}', '{today}'];

const PRIORITIES = ['Highest', 'High', 'Medium', 'Low', 'Lowest'];

// ───────────── default prompts ─────────────
// Written as skill-style instructions: what to produce, from what, and the rules.
// The item's context (fields, quoted lines, why, source note text) is always
// appended after the prompt, so a user-edited prompt never loses it.

const SLACK_DRAFT = `Write a short Slack message to {recipient} that does what the note asks.

- Use only facts from {excerpt} and {note_title}. Don't invent times, names, links or numbers; if something the message needs is missing, leave a clear [placeholder].
- Friendly and direct, under 80 words, written as the user (first person).
- Use Slack formatting: *bold*, bullet lists, @mentions for people named in the note.
- No greeting line beyond a name, no sign-off.
- The title is a one-line purpose, e.g. "Tell Mei the room is booked".
- Return only the message as the body.`;

const SLACK_IMPROVE = `The user edited this Slack message. Fix grammar, spelling and punctuation only.

- Keep their words, tone, length and formatting (Slack *bold*, bullets, @mentions).
- Don't add or remove content, and don't change names, times or numbers.
- Return only the message as the body.`;

const JIRA_DRAFT = `Draft a Jira ticket for project {project} from {excerpt}.

- Summary (the title): one line under 80 characters that starts with a verb, e.g. "Cap payment client retries at 3 with backoff".
- Description in Markdown with these sections:
  ## Why — one or two sentences on the problem and its impact.
  ## What to do — a short bullet list of concrete steps.
  ## Done when — bullet list of checkable acceptance criteria.
- Mention any incident, ticket or PR number the note names (e.g. INC-212, PX-481), exactly as written.
- Use only facts from the note; never invent numbers, owners or dates. If something is unknown, say so in one bullet.
- Fields: keep {issue_type}, {priority} and {assignee} when set; otherwise suggest issueType (Task, Bug or Story) and priority (Highest, High, Medium, Low, Lowest) from the note, and an assignee only when the note names one.`;

const JIRA_IMPROVE = `The user edited this Jira ticket. Tighten the wording and fill obvious gaps.

- Keep their facts, sections and any field they set; never change project, issue type, priority or assignee.
- Make the summary one line that starts with a verb.
- Keep the Why / What to do / Done when structure; add a missing "Done when" only from what the ticket already says.
- Don't invent numbers, names or dates. Return the improved description as the body.`;

const CONFLUENCE_DRAFT = `Draft a Confluence page for the space {space} (under {parent} when set) from {excerpt}.

- Title: a clear page title, e.g. "Incident review: INC-212 auth retry storm".
- Body in Markdown, with sections that fit the content. For an incident or review use:
  ## Summary — what happened and the impact, in two or three sentences.
  ## Timeline — bullets with times, only those the note gives.
  ## What we change — bullets, linking ticket keys the note names.
  For other write-ups use ## Summary, ## Details and ## Next steps.
- Use only facts from the note and its context; mark anything missing as "TBD" instead of guessing.
- Plain, readable sentences. No front matter.`;

const CONFLUENCE_IMPROVE = `The user edited this Confluence page. Make it read cleanly.

- Keep their structure, headings and facts; fix grammar, tighten long sentences, make bullets parallel.
- Don't add sections or facts that aren't there. Never change space or parent.
- Return the improved page as the body.`;

const EMAIL_DRAFT = `Write a short email to {recipient} that does what the note asks.

- Subject: one line. Body: plain, polite, under 150 words, using only facts from {excerpt}.
- Return the subject as the title and the email text as the body.`;

const EMAIL_IMPROVE = `The user edited this email. Fix grammar and spelling only; keep their words and tone.`;

export const BUILTIN_TYPES: ActionTypeDef[] = [
  {
    id: TODO_TYPE,
    label: 'To-do',
    pluralLabel: 'To-dos',
    recognizes: 'Anything the user must do that no other type can do for them (book, buy, read, decide, follow up in person).',
    fields: [
      { key: 'due', label: 'Due', kind: 'date' },
      { key: 'priority', label: 'Priority', kind: 'choice', choices: ['High', 'Medium', 'Low'] },
      { key: 'person', label: 'People', kind: 'person' },
    ],
    handlers: [{ id: 'complete', label: 'Complete' }],
    defaults: { enabled: true, draftWhen: 'onFind', improveAfterEdit: false },
    draftPrompt: null,
    improvePrompt: null,
    placeholders: [],
  },
  {
    id: 'slack',
    label: 'Slack message',
    pluralLabel: 'Slack messages',
    recognizes:
      'A message someone (a person or a channel) should get from the user. For to: a person’s name as written, or a channel as #name (keep the #). For thread: the Slack message link (https://….slack.com/archives/…) when the documents give one for the conversation to reply in; otherwise leave it out.',
    fields: [
      { key: 'to', label: 'To', kind: 'person', required: true },
      { key: 'thread', label: 'Thread', kind: 'text' },
    ],
    handlers: [
      { id: 'copy', label: 'Copy' },
      { id: 'markSent', label: 'Mark as sent' },
      { id: 'complete', label: 'Complete' },
      { id: 'send', label: 'Send in Slack', reserved: true },
    ],
    defaults: { enabled: true, draftWhen: 'onFind', improveAfterEdit: true },
    draftPrompt: SLACK_DRAFT,
    improvePrompt: SLACK_IMPROVE,
    placeholders: [...COMMON_PLACEHOLDERS, '{recipient}'],
  },
  {
    id: 'jira',
    label: 'Jira ticket',
    pluralLabel: 'Jira tickets',
    recognizes: 'Work to track in a Jira project: a bug, task or story, especially when the note says it needs a ticket.',
    fields: [
      { key: 'project', label: 'Project', kind: 'text', required: true },
      { key: 'issueType', label: 'Type', kind: 'choice', choices: ['Task', 'Bug', 'Story'], required: true },
      { key: 'priority', label: 'Priority', kind: 'choice', choices: PRIORITIES },
      { key: 'assignee', label: 'Assignee', kind: 'person' },
    ],
    handlers: [
      { id: 'create', label: 'Create in Jira', needsConnection: true },
      { id: 'refresh', label: 'Refresh', needsConnection: true },
      { id: 'complete', label: 'Complete' },
    ],
    connectionID: 'atlassian',
    defaults: { enabled: true, draftWhen: 'onFind', improveAfterEdit: true },
    draftPrompt: JIRA_DRAFT,
    improvePrompt: JIRA_IMPROVE,
    placeholders: [...COMMON_PLACEHOLDERS, '{project}', '{issue_type}', '{priority}', '{assignee}'],
  },
  {
    id: 'confluence',
    label: 'Confluence page',
    pluralLabel: 'Confluence pages',
    recognizes: 'A write-up that belongs in Confluence: an incident review, runbook, decision record or meeting summary.',
    fields: [
      { key: 'space', label: 'Space', kind: 'text', required: true },
      { key: 'parent', label: 'Parent page', kind: 'text' },
    ],
    handlers: [
      { id: 'create', label: 'Create in Confluence', needsConnection: true },
      { id: 'refresh', label: 'Refresh', needsConnection: true },
      { id: 'complete', label: 'Complete' },
    ],
    connectionID: 'atlassian',
    defaults: { enabled: true, draftWhen: 'onFind', improveAfterEdit: true },
    draftPrompt: CONFLUENCE_DRAFT,
    improvePrompt: CONFLUENCE_IMPROVE,
    placeholders: [...COMMON_PLACEHOLDERS, '{space}', '{parent}'],
  },
  {
    id: 'email',
    label: 'Email',
    pluralLabel: 'Emails',
    recognizes: 'An email someone should get.',
    reserved: true,
    fields: [
      { key: 'to', label: 'To', kind: 'person', required: true },
      { key: 'subject', label: 'Subject', kind: 'text' },
    ],
    handlers: [
      { id: 'copy', label: 'Copy', reserved: true },
      { id: 'openMail', label: 'Open in Mail', reserved: true },
    ],
    defaults: { enabled: false, draftWhen: 'onFind', improveAfterEdit: true },
    draftPrompt: EMAIL_DRAFT,
    improvePrompt: EMAIL_IMPROVE,
    placeholders: [...COMMON_PLACEHOLDERS, '{recipient}'],
  },
];

const types = new Map<string, ActionTypeDef>(BUILTIN_TYPES.map((t) => [t.id, t]));

/** Add (or replace) a type. Tests and future types use this; the built-ins are registered above. */
export function registerActionType(def: ActionTypeDef): void {
  types.set(def.id, def);
}

export function actionTypeDefs(): ActionTypeDef[] {
  return [...types.values()];
}

export function actionTypeDef(id: string): ActionTypeDef | undefined {
  return types.get(id);
}

// ───────────── effective (Settings merged over defaults) ─────────────

export interface EffectiveType {
  def: ActionTypeDef;
  enabled: boolean;
  draftWhen: 'onFind' | 'onRequest';
  improveAfterEdit: boolean;
  draftPrompt: string | null;
  improvePrompt: string | null;
  fieldDefaults: Record<string, string>;
  draftSelection?: ModelSelection;
  improveSelection?: ModelSelection;
}

export function effectiveType(def: ActionTypeDef, prefs: ActionPreferences): EffectiveType {
  const p: Partial<ActionTypePreferences> = prefs.types[def.id] ?? {};
  const out: EffectiveType = {
    def,
    // Reserved types stay off; to-do is always on (the catch-all).
    enabled: def.reserved ? false : def.id === TODO_TYPE ? true : (p.enabled ?? def.defaults.enabled),
    draftWhen: p.draftWhen ?? def.defaults.draftWhen,
    improveAfterEdit: def.improvePrompt === null ? false : (p.improveAfterEdit ?? def.defaults.improveAfterEdit),
    // null / absent = the built-in prompt (Reset to default).
    draftPrompt: p.draftPrompt != null && p.draftPrompt.trim() !== '' ? p.draftPrompt : def.draftPrompt,
    improvePrompt: p.improvePrompt != null && p.improvePrompt.trim() !== '' ? p.improvePrompt : def.improvePrompt,
    fieldDefaults: { ...(p.fieldDefaults ?? {}) },
  };
  if (p.draftSelection) out.draftSelection = p.draftSelection;
  if (p.improveSelection) out.improveSelection = p.improveSelection;
  return out;
}

export interface ConnectionState {
  connected(connectionID: string): boolean;
}

export function typeInfo(def: ActionTypeDef, prefs: ActionPreferences, conn: ConnectionState): ActionTypeInfo {
  const eff = effectiveType(def, prefs);
  const connected = def.connectionID ? conn.connected(def.connectionID) : true;
  const handlers: ActionHandlerInfo[] = def.handlers.map((h) => {
    if (h.reserved) return { id: h.id, label: h.label, available: false, reason: 'Later' };
    if (h.needsConnection && !connected) return { id: h.id, label: h.label, available: false, reason: 'Not connected' };
    return { id: h.id, label: h.label, available: true };
  });
  const info: ActionTypeInfo = {
    id: def.id,
    label: def.label,
    pluralLabel: def.pluralLabel,
    enabled: eff.enabled,
    fields: def.fields.map((f) => ({ ...f, ...(f.choices ? { choices: [...f.choices] } : {}) })),
    handlers,
    connectionID: def.connectionID ?? null,
    draftWhen: eff.draftWhen,
    improveAfterEdit: eff.improveAfterEdit,
    defaultDraftPrompt: def.draftPrompt,
    defaultImprovePrompt: def.improvePrompt,
    placeholders: [...def.placeholders],
  };
  if (def.reserved) info.reserved = true;
  return info;
}

/** The type an item may live in: unknown, reserved or disabled types fall back to to-do. */
export function resolveTypeID(id: string | null | undefined, prefs: ActionPreferences): string {
  const def = id ? types.get(id) : undefined;
  if (!def) return TODO_TYPE;
  return effectiveType(def, prefs).enabled ? def.id : TODO_TYPE;
}

// ───────────── prompt placeholders ─────────────

export interface PromptContext {
  item: ActionItem;
  noteTitle?: string | null;
  notePath?: string | null;
  today: string;
}

export function placeholderValues(ctx: PromptContext): Record<string, string> {
  const { item } = ctx;
  const f = item.fields;
  const quote = item.source.kind === 'manual' ? '' : (item.source.quote ?? '');
  const v = (x: string | null | undefined, fallback = '(not set)') => (x != null && x.trim() !== '' ? x : fallback);
  return {
    '{title}': item.title,
    '{body}': v(item.body, '(empty)'),
    '{why}': v(item.why),
    '{excerpt}': quote ? `the quoted lines ("${quote}")` : 'the note',
    '{note_title}': v(ctx.noteTitle, 'the note'),
    '{note_path}': v(ctx.notePath),
    '{labels}': (item.labels ?? []).join(', ') || '(none)',
    '{today}': ctx.today,
    '{recipient}': v(f.to, 'the right person'),
    '{project}': v(f.project, 'the default project'),
    '{issue_type}': v(f.issueType),
    '{priority}': v(f.priority),
    '{assignee}': v(f.assignee),
    '{space}': v(f.space, 'the default space'),
    '{parent}': v(f.parent),
  };
}

/** Replace known placeholders; unknown `{words}` stay as typed. */
export function renderPrompt(template: string, values: Record<string, string>): string {
  return template.replace(/\{[a-z_]+\}/g, (m) => values[m] ?? m);
}

// ───────────── handlers ─────────────

export interface HandlerResult {
  status?: ActionItem['status'];
  external?: ActionItem['external'];
  event: string;
  detail?: string | null;
}

export interface HandlerContext {
  item: ActionItem;
  settings: Settings;
  now: Date;
  /** Atlassian (and later) connections; injected so tests never reach the network. */
  services: HandlerServices;
}

/** What handlers may use; implemented in actions/index.ts. */
export interface HandlerServices {
  atlassian?: import('./atlassian.js').AtlassianClient;
  /** What the Jira account allows (projects, types, priorities), for the check before Create. */
  jiraMeta?: import('./jira-meta.js').JiraMeta;
}

export type HandlerFn = (ctx: HandlerContext) => Promise<HandlerResult>;

const handlers = new Map<string, HandlerFn>();

/** typeID '*' = every type that lists the handler and has no type-specific function. */
export function registerHandler(typeID: string, handlerID: string, fn: HandlerFn): void {
  handlers.set(`${typeID}:${handlerID}`, fn);
}

export function handlerFn(typeID: string, handlerID: string): HandlerFn | undefined {
  return handlers.get(`${typeID}:${handlerID}`) ?? handlers.get(`*:${handlerID}`);
}

// Generic handlers. Copy only records the event: the client puts the text on the clipboard.
registerHandler('*', 'copy', async () => ({ event: 'copied' }));
registerHandler('*', 'markSent', async () => ({ status: 'sent', event: 'sent' }));
// Complete: the user has handled it, whatever the external status says. The event's detail is the
// status it left (open, ready, created or sent) so restoreAction puts it back exactly there.
registerHandler('*', 'complete', async (ctx) => ({ status: 'done', event: 'done', detail: ctx.item.status }));
