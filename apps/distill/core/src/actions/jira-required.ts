/**
 * Fields a Jira project requires (actions.md, "Jira required fields"). Pure: a field's control from
 * its schema, how a value is stored on an item, the create payload for it, the check before Create,
 * and the value a note names. The UI shows a field's display name, never its id.
 *
 * A value lives in the item's fields under `jira.<fieldId>`:
 *   option, text, textarea, number (as text), date (YYYY-MM-DD): the text itself
 *   options: a JSON array of names        cascading: a JSON array [parent, child]
 *   user: a JSON object {accountId, name}
 * `jira.<fieldId>:from` = "note" marks a value prefilled from the note.
 */
import type { JiraField, JiraFieldKind, JiraOption, JiraRequiredDefault } from '../contracts.js';
import { isObject, str, type JSONObject } from '../store/json.js';
import { markdownToADF } from './markdown.js';

/** Fields the ticket already fills (or Jira fills): never asked as "required". */
export const STANDARD_JIRA_FIELDS = new Set([
  'project', 'issuetype', 'summary', 'description', 'priority', 'assignee', 'labels', 'reporter', 'attachment', 'issuelinks', 'parent',
]);

export const fieldKey = (id: string) => `jira.${id}`;
export const fromKey = (id: string) => `jira.${id}:from`;
/** "PROJECT|Type": the key of a project + type's saved values. */
export const defaultsKey = (project: string, type: string) => `${project.trim().toUpperCase()}|${type.trim()}`;

const OPTION_ITEMS = new Set(['option', 'component', 'version']);

export function fieldKind(schema: JiraField['schema']): JiraFieldKind {
  if (!schema) return 'unsupported';
  const custom = schema.custom ?? '';
  switch (schema.type) {
    case 'option':
    case 'component':
    case 'version':
      return 'option';
    case 'array':
      return OPTION_ITEMS.has(schema.items ?? '') ? 'options' : 'unsupported';
    case 'string':
      return /textarea/.test(custom) ? 'textarea' : 'text';
    case 'number':
      return 'number';
    case 'date':
      return 'date';
    case 'user':
      return 'user';
    case 'option-with-child':
      return 'cascading';
    default:
      return 'unsupported';
  }
}

/** Jira's allowedValues → options with ids (and children for a cascading field). */
export function optionsOf(allowed: unknown): JiraOption[] | undefined {
  if (!Array.isArray(allowed)) return undefined;
  const out: JiraOption[] = [];
  for (const v of allowed) {
    if (!isObject(v)) continue;
    const id = str(v.id) ?? (typeof v.id === 'number' ? String(v.id) : undefined);
    const name = str(v.value) ?? str(v.name);
    if (!id || !name) continue;
    const o: JiraOption = { id, name };
    if (Array.isArray(v.children)) {
      o.children = v.children.filter(isObject).flatMap((c) => {
        const cid = str(c.id) ?? (typeof c.id === 'number' ? String(c.id) : undefined);
        const cname = str(c.value) ?? str(c.name);
        return cid && cname ? [{ id: cid, name: cname }] : [];
      });
    }
    out.push(o);
  }
  return out;
}

/** A createmeta field → JiraField (name, required, schema, kind, options). */
export function readField(f: JSONObject): JiraField {
  const schema = isObject(f.schema)
    ? { type: str(f.schema.type) ?? '', items: str(f.schema.items) ?? null, custom: str(f.schema.custom) ?? null, system: str(f.schema.system) ?? null }
    : null;
  const out: JiraField = { id: str(f.fieldId) ?? str(f.key) ?? '', name: str(f.name) ?? '', required: f.required === true };
  const allowed = Array.isArray(f.allowedValues)
    ? f.allowedValues.filter(isObject).map((v) => str(v.name) ?? str(v.value) ?? '').filter(Boolean)
    : undefined;
  if (allowed) out.allowed = allowed;
  if (schema) out.schema = schema;
  out.kind = fieldKind(schema);
  const options = optionsOf(f.allowedValues);
  if (options && options.length > 0) out.options = options;
  if (f.hasDefaultValue === true) out.hasDefault = true;
  return out;
}

/** The fields Distill asks about besides its own: required ones (with no Jira default) first, then the rest. */
export function extraFields(fields: JiraField[]): JiraField[] {
  const extra = fields.filter((f) => f.id && !STANDARD_JIRA_FIELDS.has(f.id));
  return [...extra.filter((f) => f.required && !f.hasDefault), ...extra.filter((f) => !(f.required && !f.hasDefault))];
}

/** Asked on every ticket: required, and Jira has no default for it. */
export const asked = (f: JiraField) => f.required && !f.hasDefault && !STANDARD_JIRA_FIELDS.has(f.id);

function parseJSON(raw: string): unknown {
  try {
    return JSON.parse(raw);
  } catch {
    return undefined;
  }
}

const same = (a: string, b: string) => a.trim().toLowerCase() === b.trim().toLowerCase();

/** True when a stored value says nothing (empty text, an empty list). */
export function isEmptyValue(raw: string | null | undefined): boolean {
  if (raw == null || raw.trim() === '') return true;
  const t = raw.trim();
  if (t === '[]' || t === '{}') return true;
  return false;
}

export type PayloadResult = { value: unknown } | { problem: string };

/** The value Jira's create request takes for this field, by its schema. */
export function payloadValue(f: JiraField, raw: string): PayloadResult {
  const kind = f.kind ?? fieldKind(f.schema);
  const opt = (name: string) => (f.options ?? []).find((o) => same(o.name, name));
  const notAllowed = (v: string): PayloadResult => ({ problem: `${v} isn’t a choice for ${f.name}. Pick one.` });
  switch (kind) {
    case 'option': {
      const o = opt(raw);
      return o ? { value: { id: o.id } } : notAllowed(raw);
    }
    case 'options': {
      const v = parseJSON(raw);
      const names = Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : raw.split(',').map((x) => x.trim()).filter(Boolean);
      const out: { id: string }[] = [];
      for (const n of names) {
        const o = opt(n);
        if (!o) return notAllowed(n);
        out.push({ id: o.id });
      }
      return { value: out };
    }
    case 'text':
      return { value: raw.trim() };
    case 'textarea':
      // REST v3 takes a multi-line text field as a document.
      return { value: markdownToADF(raw) };
    case 'number': {
      const n = Number(raw.trim());
      return Number.isFinite(n) ? { value: n } : { problem: `${f.name} needs a number.` };
    }
    case 'date':
      return /^\d{4}-\d{2}-\d{2}$/.test(raw.trim()) ? { value: raw.trim() } : { problem: `${f.name} needs a date.` };
    case 'user': {
      const v = parseJSON(raw);
      const id = isObject(v) ? str(v.accountId) : undefined;
      return id ? { value: { accountId: id } } : { problem: `Pick ${f.name} from the people Jira knows.` };
    }
    case 'cascading': {
      const v = parseJSON(raw);
      const [parent, child] = Array.isArray(v) ? v.map(String) : raw.split('›').map((x) => x.trim());
      const p = parent ? opt(parent) : undefined;
      if (!p) return notAllowed(parent ?? raw);
      if (!child) return { value: { id: p.id } };
      const c = (p.children ?? []).find((x) => same(x.name, child));
      return c ? { value: { id: p.id, child: { id: c.id } } } : notAllowed(child);
    }
    default:
      return { problem: `${f.name} can only be filled in Jira` };
  }
}

/** The value a field has on this item: its own, else the project + type's saved one. */
export function valueFor(f: JiraField, fields: Record<string, string | null>, defaults: Record<string, JiraRequiredDefault> | undefined): string | undefined {
  const own = fields[fieldKey(f.id)];
  if (!isEmptyValue(own)) return own!;
  const d = defaults?.[f.id]?.value;
  return isEmptyValue(d) ? undefined : d;
}

export interface RequiredCheck {
  /** Field id → payload value, for every extra field with a value. */
  payload: Record<string, unknown>;
  problem?: { field: string; message: string };
}

/**
 * Before Create: every asked field needs a value (an unsupported one can't be filled here), and
 * every value maps to Jira's shape. Optional fields go along only when they have a value.
 */
export function checkRequired(fields: JiraField[], values: Record<string, string | null>, defaults: Record<string, JiraRequiredDefault> | undefined): RequiredCheck {
  const payload: Record<string, unknown> = {};
  for (const f of extraFields(fields)) {
    const kind = f.kind ?? fieldKind(f.schema);
    const raw = valueFor(f, values, defaults);
    if (asked(f) && kind === 'unsupported') return { payload, problem: { field: fieldKey(f.id), message: `${f.name} can only be filled in Jira` } };
    if (raw === undefined) {
      if (asked(f)) return { payload, problem: { field: fieldKey(f.id), message: `Fill in ${f.name} first` } };
      continue;
    }
    if (kind === 'unsupported') continue;
    const r = payloadValue(f, raw);
    if ('problem' in r) return { payload, problem: { field: fieldKey(f.id), message: r.problem } };
    payload[f.id] = r.value;
  }
  return { payload };
}

/** Whole words, ignoring case: "API" in "the API layer", not in "rapid". */
function names(text: string, value: string): boolean {
  const v = value.trim();
  if (!v) return false;
  const esc = v.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(^|[^\\p{L}\\p{N}])${esc}($|[^\\p{L}\\p{N}])`, 'iu').test(text);
}

/** A value the note names exactly (ignoring case): one option, or every option it names; undefined when none (or two for one choice). */
export function fromNote(f: JiraField, text: string): string | undefined {
  const kind = f.kind ?? fieldKind(f.schema);
  const opts = f.options ?? [];
  if (kind === 'option') {
    const hits = opts.filter((o) => names(text, o.name));
    return hits.length === 1 ? hits[0]!.name : undefined;
  }
  if (kind === 'options') {
    const hits = opts.filter((o) => names(text, o.name)).map((o) => o.name);
    return hits.length > 0 ? JSON.stringify(hits) : undefined;
  }
  return undefined;
}
