/**
 * Atlassian Cloud (Jira + Confluence on one site) with the user's email and
 * an API token. The email and token live in the SecretStore (macOS Keychain)
 * as ("atlassian", "email") and ("atlassian", "token"); the site URL, display
 * name and account id are not secret and live in <state>/connections.json.
 * Nothing here runs unless the user presses Create / Refresh / Connect.
 */
import fs from 'node:fs';
import { CoreError, type ActionError, type ActionItem, type ConnectionInfo } from '../contracts.js';
import type { FetchLike } from '../runners/model-api.js';
import type { SecretStore } from '../runners/secrets.js';
import { encodeJSON, isObject, isoDate, preserveUnreadable, readJSON, str, writeFileAtomic, type JSONObject } from '../store/json.js';
import { markdownToADF, markdownToStorage } from './markdown.js';
import { registerHandler, type HandlerContext, type HandlerResult } from './registry.js';

export const ATLASSIAN = 'atlassian';
export const API_TOKEN_URL = 'https://id.atlassian.com/manage-profile/security/api-tokens';

/** A handler failure the user can act on; the draft stays as it was. */
export class ActionHandlerError extends Error {
  constructor(readonly error: ActionError) {
    super(error.message);
    this.name = 'ActionHandlerError';
  }
}

const fail = (code: ActionError['code'], message: string, field?: string | null): never => {
  throw new ActionHandlerError({ code, message, ...(field ? { field } : {}) });
};

export interface AtlassianRecord {
  site: string;
  /** Display name from /myself (not secret). */
  account?: string | null;
  accountId?: string | null;
  connectedAt?: string | null;
  /** Set when a call came back 401. */
  expiredAt?: string | null;
}

/** <state>/connections.json: non-secret connection details; unknown keys survive. */
export class ConnectionFile {
  private raw: JSONObject = {};
  constructor(readonly file: string) {
    const parsed = readJSON(file);
    if (parsed === undefined && fs.existsSync(file)) preserveUnreadable(file);
    this.raw = isObject(parsed) ? parsed : {};
  }

  atlassian(): AtlassianRecord | undefined {
    const v = this.raw[ATLASSIAN];
    if (!isObject(v)) return undefined;
    const site = str(v.site);
    if (!site) return undefined;
    return {
      site,
      account: str(v.account) ?? null,
      accountId: str(v.accountId) ?? null,
      connectedAt: str(v.connectedAt) ?? null,
      expiredAt: str(v.expiredAt) ?? null,
    };
  }

  setAtlassian(rec: AtlassianRecord | undefined): void {
    if (rec) {
      const out: JSONObject = { ...(isObject(this.raw[ATLASSIAN]) ? (this.raw[ATLASSIAN] as JSONObject) : {}) };
      for (const [k, v] of Object.entries(rec)) {
        if (v == null) delete out[k];
        else out[k] = v;
      }
      this.raw[ATLASSIAN] = out;
    } else {
      delete this.raw[ATLASSIAN];
    }
    writeFileAtomic(this.file, encodeJSON(this.raw), 0o600);
  }
}

/** "acme", "acme.atlassian.net", "https://acme.atlassian.net/wiki/" → "https://acme.atlassian.net". */
export function normalizeSite(input: string): string {
  let s = input.trim();
  if (!s) throw new CoreError('invalid_request', 'Enter your Atlassian site, e.g. acme.atlassian.net.');
  if (!/^[a-z]+:\/\//i.test(s)) s = /^[a-z0-9-]+$/i.test(s) ? `https://${s}.atlassian.net` : `https://${s}`;
  let url: URL;
  try {
    url = new URL(s);
  } catch {
    throw new CoreError('invalid_request', `"${input}" isn't a site address.`);
  }
  if (url.protocol !== 'https:') throw new CoreError('invalid_request', 'The Atlassian site must use https.');
  return `https://${url.host}`;
}

interface HttpOutcome {
  status: number;
  json: unknown;
}

export interface AtlassianDeps {
  fetch: FetchLike;
  secrets: SecretStore;
  file: ConnectionFile;
  now: () => Date;
  /** Called when the connection's state changed (connected, expired, disconnected). */
  onChange?: () => void;
}

export class AtlassianClient {
  constructor(private readonly deps: AtlassianDeps) {}

  record(): AtlassianRecord | undefined {
    return this.deps.file.atlassian();
  }

  /** Stored-state only: never reaches the network. */
  info(usedBy: string[]): ConnectionInfo {
    const rec = this.record();
    const base = { id: ATLASSIAN, label: 'Atlassian (Jira and Confluence)', usedBy };
    let hasSecret = false;
    try {
      hasSecret = this.deps.secrets.hasSync(ATLASSIAN, 'token');
    } catch {
      hasSecret = false;
    }
    if (!rec || !hasSecret) {
      return { ...base, status: 'not_connected', site: rec?.site ?? null, account: null, message: null };
    }
    if (rec.expiredAt) {
      return { ...base, status: 'expired', site: rec.site, account: rec.account ?? null, message: `Sign-in expired ${rec.expiredAt}` };
    }
    return { ...base, status: 'connected', site: rec.site, account: rec.account ?? null, message: null };
  }

  isConnected(): boolean {
    return this.info([]).status === 'connected';
  }

  /** Verify with GET /rest/api/3/myself, then store the email and token in the Keychain. */
  async connect(siteInput: string | undefined, email: string | undefined, token: string | undefined): Promise<AtlassianRecord> {
    const site = normalizeSite(siteInput ?? this.record()?.site ?? '');
    if (!email?.trim()) throw new CoreError('invalid_request', 'Enter the email you use for Atlassian.');
    if (!token?.trim()) throw new CoreError('invalid_request', 'Paste the API token you created.');
    const auth = basic(email.trim(), token.trim());
    let res: HttpOutcome;
    try {
      res = await this.http(site, auth, 'GET', '/rest/api/3/myself');
    } catch {
      throw new CoreError('invalid_state', `Couldn't reach ${hostOf(site)}. Check the site and your connection.`);
    }
    if (res.status === 401 || res.status === 403) {
      throw new CoreError('invalid_request', `${hostOf(site)} didn't accept that email and API token.`);
    }
    if (res.status === 404) throw new CoreError('invalid_request', `${hostOf(site)} isn't an Atlassian Cloud site.`);
    if (res.status < 200 || res.status >= 300) throw new CoreError('invalid_state', `${hostOf(site)} answered ${res.status}.`);
    const me = isObject(res.json) ? res.json : {};
    await this.deps.secrets.set(ATLASSIAN, 'email', email.trim());
    await this.deps.secrets.set(ATLASSIAN, 'token', token.trim());
    const rec: AtlassianRecord = {
      site,
      account: str(me.displayName) ?? null,
      accountId: str(me.accountId) ?? null,
      connectedAt: isoDate(this.deps.now()),
      expiredAt: null,
    };
    this.deps.file.setAtlassian(rec);
    this.deps.onChange?.();
    return rec;
  }

  async disconnect(): Promise<void> {
    await this.deps.secrets.set(ATLASSIAN, 'email', null);
    await this.deps.secrets.set(ATLASSIAN, 'token', null);
    this.deps.file.setAtlassian(undefined);
    this.deps.onChange?.();
  }

  /** One authenticated call for a handler. Maps failures to ActionError codes. */
  async call(method: string, path: string, body?: unknown): Promise<HttpOutcome & { site: string; rec: AtlassianRecord }> {
    const rec = this.record();
    if (!rec) fail('not_connected', 'Jira and Confluence aren’t connected. Paste an Atlassian API token in Settings → Connections, then retry; your draft is safe.');
    const site = rec!.site;
    let email: string | undefined;
    let token: string | undefined;
    try {
      email = await this.deps.secrets.get(ATLASSIAN, 'email');
      token = await this.deps.secrets.get(ATLASSIAN, 'token');
    } catch {
      email = undefined;
    }
    if (!email || !token) fail('not_connected', `${hostOf(site)} isn’t connected. Paste an Atlassian API token in Settings → Connections, then retry; your draft is safe.`);
    let res: HttpOutcome;
    try {
      res = await this.http(site, basic(email!, token!), method, path, body);
    } catch {
      return fail('unreachable', `Couldn’t reach ${hostOf(site)}. You might be offline. Nothing was created; the draft is safe.`);
    }
    if (res.status === 401) {
      this.deps.file.setAtlassian({ ...rec!, expiredAt: isoDate(this.deps.now()) });
      this.deps.onChange?.();
      fail('auth_expired', `${hostOf(site)} stopped accepting the API token.`);
    }
    if (res.status === 403) {
      fail('not_connected', `Your Atlassian account can’t do this on ${hostOf(site)}. Check its permissions, then retry.`);
    }
    if (rec!.expiredAt && res.status >= 200 && res.status < 300) {
      this.deps.file.setAtlassian({ ...rec!, expiredAt: null });
      this.deps.onChange?.();
    }
    return { ...res, site, rec: rec! };
  }

  private async http(site: string, auth: string, method: string, path: string, body?: unknown): Promise<HttpOutcome> {
    const init: RequestInit = {
      method,
      headers: {
        Authorization: auth,
        Accept: 'application/json',
        ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
      },
      signal: AbortSignal.timeout(30_000),
    };
    if (body !== undefined) init.body = JSON.stringify(body);
    const res = await this.deps.fetch(`${site}${path}`, init);
    const text = await res.text();
    let json: unknown;
    try {
      json = text ? JSON.parse(text) : undefined;
    } catch {
      json = undefined;
    }
    return { status: res.status, json };
  }
}

function basic(email: string, token: string): string {
  return `Basic ${Buffer.from(`${email}:${token}`, 'utf8').toString('base64')}`;
}

function hostOf(site: string): string {
  try {
    return new URL(site).host;
  } catch {
    return site;
  }
}

// ───────────── Jira ─────────────

/** Jira's field ids → ours, for "refused" errors. */
const JIRA_FIELD_MAP: Record<string, string> = {
  issuetype: 'issueType',
  project: 'project',
  priority: 'priority',
  assignee: 'assignee',
  summary: 'title',
  description: 'body',
};

/** First readable reason in a Jira/Confluence error body, and the field it names. */
export function refusal(json: unknown, fieldMap: Record<string, string> = JIRA_FIELD_MAP): { message: string; field: string | null } {
  if (!isObject(json)) return { message: 'it refused the request', field: null };
  if (isObject(json.errors)) {
    const entries = Object.entries(json.errors).filter(([, v]) => typeof v === 'string');
    if (entries.length > 0) {
      const [key, msg] = entries[0]!;
      return { message: msg as string, field: fieldMap[key] ?? key };
    }
  }
  if (Array.isArray(json.errorMessages) && typeof json.errorMessages[0] === 'string') return { message: json.errorMessages[0], field: null };
  // Confluence v2: {errors: [{title, detail}]}
  if (Array.isArray(json.errors) && isObject(json.errors[0])) {
    const e = json.errors[0];
    return { message: str(e.detail) ?? str(e.title) ?? 'it refused the request', field: null };
  }
  if (typeof json.message === 'string') return { message: json.message, field: null };
  return { message: 'it refused the request', field: null };
}

function clientOf(ctx: HandlerContext): AtlassianClient {
  const c = ctx.services.atlassian;
  if (!c) fail('not_connected', 'Jira and Confluence aren’t connected.');
  return c!;
}

const isYou = (v: string, rec: AtlassianRecord) => {
  const n = v.trim().toLowerCase();
  return ['you', 'me', 'myself'].includes(n) || n.startsWith('you (') || (!!rec.account && n === rec.account.toLowerCase());
};

async function jiraAssignee(client: AtlassianClient, value: string | null | undefined): Promise<string | undefined> {
  if (!value?.trim()) return undefined;
  const rec = client.record();
  if (rec && isYou(value, rec)) return rec.accountId ?? undefined;
  // One exact match only; otherwise the ticket is left unassigned.
  const res = await client.call('GET', `/rest/api/3/user/search?query=${encodeURIComponent(value.trim())}`);
  if (res.status !== 200 || !Array.isArray(res.json)) return undefined;
  const users = res.json.filter((u): u is JSONObject => isObject(u) && typeof u.accountId === 'string');
  return users.length === 1 ? (users[0]!.accountId as string) : undefined;
}

export function jiraLabels(labels: string[] | undefined): string[] {
  return (labels ?? []).map((l) => l.trim().replace(/^#/, '').replace(/\s+/g, '-')).filter(Boolean);
}

async function jiraCreate(ctx: HandlerContext): Promise<HandlerResult> {
  const client = clientOf(ctx);
  const { item } = ctx;
  const f = item.fields;
  const project = f.project?.trim();
  if (!project) fail('refused', 'Choose a Jira project first.', 'project');
  const fields: JSONObject = {
    project: { key: project!.split(/\s/)[0] },
    summary: item.title.trim().slice(0, 254),
    issuetype: { name: f.issueType?.trim() || 'Task' },
    description: markdownToADF(item.body ?? ''),
  };
  if (f.priority?.trim()) fields.priority = { name: f.priority.trim() };
  const labels = jiraLabels(item.labels);
  if (labels.length > 0) fields.labels = labels;
  const assignee = await jiraAssignee(client, f.assignee);
  if (assignee) fields.assignee = { accountId: assignee };
  const res = await client.call('POST', '/rest/api/3/issue', { fields });
  if (res.status === 400) {
    const r = refusal(res.json);
    fail('refused', `Jira didn’t create the ticket: ${r.message}`, r.field);
  }
  if (res.status === 404) fail('refused', `Jira didn’t create the ticket: project ${project} wasn’t found.`, 'project');
  if (res.status < 200 || res.status >= 300 || !isObject(res.json) || typeof res.json.key !== 'string') {
    fail('other', `Jira answered ${res.status}; the ticket may not exist. Check Jira before you retry.`);
  }
  const key = (res.json as JSONObject).key as string;
  const external: NonNullable<ActionItem['external']> = { key, url: `${res.site}/browse/${key}`, status: null, checkedAt: null };
  // Best effort: the new ticket's status.
  try {
    const st = await jiraStatus(client, key);
    if (st) Object.assign(external, { status: st.name, checkedAt: isoDate(ctx.now) });
  } catch {
    /* refresh later */
  }
  return { status: 'created', external, event: 'created', detail: key };
}

async function jiraStatus(client: AtlassianClient, key: string): Promise<{ name: string; done: boolean } | undefined> {
  const res = await client.call('GET', `/rest/api/3/issue/${encodeURIComponent(key)}?fields=status`);
  if (res.status === 404) fail('other', `${key} no longer exists in Jira (or you can’t see it).`);
  if (res.status !== 200 || !isObject(res.json) || !isObject(res.json.fields) || !isObject(res.json.fields.status)) return undefined;
  const status = res.json.fields.status;
  const category = isObject(status.statusCategory) ? str(status.statusCategory.key) : undefined;
  return { name: str(status.name) ?? 'Unknown', done: category === 'done' };
}

async function jiraRefresh(ctx: HandlerContext): Promise<HandlerResult> {
  const key = ctx.item.external?.key;
  if (!key) fail('other', 'This ticket hasn’t been created in Jira yet.');
  const st = await jiraStatus(clientOf(ctx), key!);
  if (!st) fail('other', `Jira didn’t say what ${key} is doing; try again.`);
  const external = { ...(ctx.item.external ?? {}), status: st!.name, checkedAt: isoDate(ctx.now) };
  if (st!.done) return { status: 'done', external, event: 'done', detail: `in Jira (${st!.name})` };
  return { external, event: 'status', detail: st!.name };
}

// ───────────── Confluence ─────────────

const CONFLUENCE_FIELD_MAP: Record<string, string> = { spaceId: 'space', parentId: 'parent', title: 'title', body: 'body' };

async function confluenceSpaceID(client: AtlassianClient, space: string): Promise<string> {
  const key = space.trim().split(/\s/)[0]!;
  if (/^\d+$/.test(key)) return key;
  const res = await client.call('GET', `/wiki/api/v2/spaces?keys=${encodeURIComponent(key)}&limit=1`);
  const results = isObject(res.json) && Array.isArray(res.json.results) ? res.json.results : [];
  const first = results.find(isObject);
  const id = first ? (typeof first.id === 'number' ? String(first.id) : str(first.id)) : undefined;
  if (res.status !== 200 || !id) return fail('refused', `Confluence didn’t create the page: there is no space with key ${key}.`, 'space');
  return id;
}

async function confluenceParentID(client: AtlassianClient, spaceID: string, parent: string): Promise<string> {
  const p = parent.trim();
  if (/^\d+$/.test(p)) return p;
  const res = await client.call('GET', `/wiki/api/v2/pages?space-id=${encodeURIComponent(spaceID)}&title=${encodeURIComponent(p)}&limit=1`);
  const results = isObject(res.json) && Array.isArray(res.json.results) ? res.json.results : [];
  const first = results.find(isObject);
  const id = first ? (typeof first.id === 'number' ? String(first.id) : str(first.id)) : undefined;
  if (res.status !== 200 || !id) return fail('refused', `Confluence didn’t create the page: no page named “${p}” in that space.`, 'parent');
  return id;
}

function confluenceStatusLabel(status: string | undefined): string {
  if (status === 'current') return 'Published';
  if (status === 'draft') return 'Draft';
  if (status === 'trashed') return 'In trash';
  return status ?? 'Unknown';
}

async function confluenceCreate(ctx: HandlerContext): Promise<HandlerResult> {
  const client = clientOf(ctx);
  const { item } = ctx;
  const space = item.fields.space?.trim();
  if (!space) fail('refused', 'Choose a Confluence space first.', 'space');
  const spaceId = await confluenceSpaceID(client, space!);
  const body: JSONObject = {
    spaceId,
    status: 'current',
    title: item.title.trim(),
    body: { representation: 'storage', value: markdownToStorage(item.body ?? '') },
  };
  if (item.fields.parent?.trim()) body.parentId = await confluenceParentID(client, spaceId, item.fields.parent);
  const res = await client.call('POST', '/wiki/api/v2/pages', body);
  if (res.status === 400 || res.status === 409) {
    const r = refusal(res.json, CONFLUENCE_FIELD_MAP);
    fail('refused', `Confluence didn’t create the page: ${r.message}`, r.field ?? (/title/i.test(r.message) ? 'title' : null));
  }
  if (res.status < 200 || res.status >= 300 || !isObject(res.json) || res.json.id === undefined) {
    fail('other', `Confluence answered ${res.status}; the page may not exist. Check Confluence before you retry.`);
  }
  const page = res.json as JSONObject;
  const id = String(page.id);
  const links = isObject(page._links) ? page._links : {};
  const webui = str(links.webui);
  const url = webui ? `${str(links.base) ?? `${res.site}/wiki`}${webui}` : `${res.site}/wiki/pages/viewpage.action?pageId=${id}`;
  return {
    status: 'created',
    external: { key: id, url, status: confluenceStatusLabel(str(page.status)), checkedAt: isoDate(ctx.now) },
    event: 'created',
    detail: item.title,
  };
}

async function confluenceRefresh(ctx: HandlerContext): Promise<HandlerResult> {
  const id = ctx.item.external?.key;
  if (!id) fail('other', 'This page hasn’t been created in Confluence yet.');
  const res = await clientOf(ctx).call('GET', `/wiki/api/v2/pages/${encodeURIComponent(id!)}`);
  if (res.status === 404) fail('other', 'This page no longer exists in Confluence (or you can’t see it).');
  if (res.status !== 200 || !isObject(res.json)) fail('other', `Confluence answered ${res.status}; try again.`);
  const label = confluenceStatusLabel(str((res.json as JSONObject).status));
  return { external: { ...(ctx.item.external ?? {}), status: label, checkedAt: isoDate(ctx.now) }, event: 'status', detail: label };
}

registerHandler('jira', 'create', jiraCreate);
registerHandler('jira', 'refresh', jiraRefresh);
registerHandler('confluence', 'create', confluenceCreate);
registerHandler('confluence', 'refresh', confluenceRefresh);
