/**
 * What the connected Jira account allows (actions.md, "Jira pickers"): the projects it can create
 * issues in, each project's issue types, and the fields on a type's create screen (with the
 * priority scheme's allowed values). Cached per account and site for an hour; `refresh` reloads.
 * Secrets stay with the AtlassianClient (Keychain); tests pass a fake fetch.
 */
import { CoreError, type JiraField, type JiraFields, type JiraIssueTypes, type JiraProjects, type JiraUsers } from '../contracts.js';
import { extraFields, readField } from './jira-required.js';
import { isObject, isoDate, str, type JSONObject } from '../store/json.js';
import { ActionHandlerError, type AtlassianClient } from './atlassian.js';

export const JIRA_META_TTL_MS = 60 * 60 * 1000;
/** Paged lists stop here (50 per page): an account with more projects than this is unusual. */
const MAX_PAGES = 40;

interface Entry<T> {
  at: number;
  value: T;
}

export class JiraMeta {
  private readonly cache = new Map<string, Entry<unknown>>();

  constructor(private readonly client: AtlassianClient, private readonly now: () => Date) {}

  /** Projects the account can create issues in, by key. */
  async projects(o: { refresh?: boolean } = {}): Promise<JiraProjects> {
    return this.cached('projects', o.refresh, async (base) => {
      const values = await this.paged('/rest/api/3/project/search?action=create&orderBy=key', ['values']);
      const projects = values
        .filter(isObject)
        .map((p) => ({ key: str(p.key) ?? '', name: str(p.name) ?? '', ...(str(p.id) ? { id: str(p.id)! } : {}) }))
        .filter((p) => p.key)
        .sort((a, b) => a.key.localeCompare(b.key));
      return { ...base, projects };
    });
  }

  /** A project's issue types (createmeta). */
  async issueTypes(project: string, o: { refresh?: boolean } = {}): Promise<JiraIssueTypes> {
    const key = project.trim().toUpperCase();
    return this.cached(`types:${key}`, o.refresh, async (base) => {
      const values = await this.paged(`/rest/api/3/issue/createmeta/${encodeURIComponent(key)}/issuetypes`, ['issueTypes', 'values']);
      const types = values
        .filter(isObject)
        .filter((t) => t.subtask !== true)
        .map((t) => ({ id: str(t.id) ?? '', name: str(t.name) ?? '' }))
        .filter((t) => t.id && t.name);
      return { ...base, project: key, types };
    });
  }

  /** The create screen of a project's issue type: its fields, and the allowed priorities (null: no Priority field). */
  async fields(project: string, typeId: string, o: { refresh?: boolean } = {}): Promise<JiraFields> {
    const key = project.trim().toUpperCase();
    return this.cached(`fields:${key}:${typeId}`, o.refresh, async (base) => {
      const values = await this.paged(`/rest/api/3/issue/createmeta/${encodeURIComponent(key)}/issuetypes/${encodeURIComponent(typeId)}`, ['fields', 'values']);
      // actions.md, Jira required fields: each field's name, required, schema and allowed values (with ids).
      const fields: JiraField[] = values.filter(isObject).map(readField);
      const priority = fields.find((f) => f.id === 'priority');
      return { ...base, project: key, typeId, fields, priorities: priority ? (priority.allowed ?? []) : null, extra: extraFields(fields) };
    });
  }

  /** People Jira can assign in a project, matching `query` (not cached: a search). */
  async users(project: string, query: string): Promise<JiraUsers> {
    const key = project.trim().toUpperCase();
    const q = query.trim();
    if (!q) return { users: [] };
    await this.projects(); // the connection check, with its plain words
    const body = await this.getAny(`/rest/api/3/user/assignable/search?project=${encodeURIComponent(key)}&query=${encodeURIComponent(q)}&maxResults=20`);
    const list = Array.isArray(body) ? body : [];
    return {
      users: list.filter(isObject).flatMap((u) => {
        const id = str(u.accountId);
        return id && u.active !== false ? [{ accountId: id, name: str(u.displayName) ?? id }] : [];
      }),
    };
  }

  private async cached<T>(what: string, refresh: boolean | undefined, load: (base: { site: string; account: string | null; fetchedAt: string }) => Promise<T>): Promise<T> {
    const rec = this.client.record();
    if (!rec || !this.client.isConnected()) throw new CoreError('invalid_state', 'Jira isn’t connected. Set up the Atlassian connection in Settings → Connections.', { jira: 'not_connected' });
    const cacheKey = `${rec.site}|${rec.accountId ?? rec.account ?? ''}|${what}`;
    const hit = this.cache.get(cacheKey) as Entry<T> | undefined;
    const t = this.now().getTime();
    if (hit && !refresh && t - hit.at < JIRA_META_TTL_MS) return hit.value;
    const value = await load({ site: rec.site, account: rec.account ?? null, fetchedAt: isoDate(this.now()) });
    this.cache.set(cacheKey, { at: t, value });
    return value;
  }

  /** GET a paged Jira list; the items are under the first of `keys` the body has. */
  private async paged(path: string, keys: string[]): Promise<unknown[]> {
    const out: unknown[] = [];
    let startAt = 0;
    for (let page = 0; page < MAX_PAGES; page++) {
      const sep = path.includes('?') ? '&' : '?';
      const body = await this.get(`${path}${sep}startAt=${startAt}&maxResults=50`);
      const list = keys.map((k) => body[k]).find(Array.isArray) as unknown[] | undefined;
      if (!list || list.length === 0) break;
      out.push(...list);
      startAt += list.length;
      const total = typeof body.total === 'number' ? body.total : undefined;
      if (body.isLast === true || (total !== undefined && startAt >= total) || (body.isLast === undefined && total === undefined)) break;
    }
    return out;
  }

  private async get(path: string): Promise<JSONObject> {
    const json = await this.getAny(path);
    if (!isObject(json)) throw new CoreError('invalid_state', 'Jira answered with something other than a list of choices.', { jira: 'error' });
    return json;
  }

  private async getAny(path: string): Promise<unknown> {
    let res: Awaited<ReturnType<AtlassianClient['call']>>;
    try {
      res = await this.client.call('GET', path);
    } catch (err) {
      if (err instanceof ActionHandlerError) {
        const kind = err.error.code === 'unreachable' ? 'unreachable' : err.error.code === 'auth_expired' ? 'auth_expired' : 'not_connected';
        throw new CoreError('invalid_state', err.error.message, { jira: kind });
      }
      throw err;
    }
    if (res.status < 200 || res.status >= 300 || res.json === undefined || res.json === null) {
      throw new CoreError('invalid_state', `Jira answered ${res.status} for the list of choices.`, { jira: 'error', status: res.status });
    }
    return res.json;
  }
}

/** A CoreError from JiraMeta that means "couldn't ask Jira" (so nothing is blocked: Jira checks on create). */
export function jiraUnreachable(err: unknown): boolean {
  return err instanceof CoreError && typeof err.details?.jira === 'string';
}

/** "TLS · Telus Platform" or "tls" → "TLS". */
export function projectKey(value: string): string {
  return value.trim().split(/[\s·]/)[0]!.toUpperCase();
}

/** The same name, ignoring case and extra spaces, in a list; the list's spelling. */
export function sameName(value: string, names: string[]): string | undefined {
  const n = value.trim().replace(/\s+/g, ' ').toLowerCase();
  return names.find((x) => x.trim().replace(/\s+/g, ' ').toLowerCase() === n);
}

export interface JiraCheck {
  /** Jira's spelling for each value that matched (case-insensitive). */
  project?: string;
  issueType?: string;
  /** The type's id and its create screen's fields (actions.md, Jira required fields). */
  typeId?: string;
  fields?: JiraField[];
  /** Jira's project id (the create page link). */
  projectId?: string;
  priority?: string;
  /** The type's create screen has no Priority: leave it out of the request. */
  dropPriority?: boolean;
  /** A value outside what the account allows: the field and the plain words. */
  problem?: { field: 'project' | 'issueType' | 'priority'; message: string };
  /** Jira couldn't be asked: nothing was checked. */
  unchecked?: boolean;
}

/**
 * Check a draft's Project, Type and Priority against the account before Create. A value outside
 * the lists is a problem in plain words; if Jira can't be reached nothing is blocked.
 */
export async function checkJiraDraft(meta: JiraMeta, f: { project?: string | null; issueType?: string | null; priority?: string | null }): Promise<JiraCheck> {
  const out: JiraCheck = {};
  const project = f.project?.trim();
  if (!project) return out;
  try {
    const key = projectKey(project);
    const projects = (await meta.projects()).projects;
    const p = projects.find((x) => x.key === key) ?? projects.find((x) => sameName(project, [x.name]));
    if (!p) return { problem: { field: 'project', message: `${project} isn’t a Jira project you can create tickets in. Pick one.` } };
    out.project = p.key;
    if (p.id) out.projectId = p.id;
    const typeName = f.issueType?.trim() || 'Task';
    const types = (await meta.issueTypes(p.key)).types;
    const type = types.find((t) => sameName(typeName, [t.name]));
    if (!type) return { ...out, problem: { field: 'issueType', message: `${typeName} isn’t an issue type in ${p.key}. Pick one.` } };
    out.issueType = type.name;
    out.typeId = type.id;
    const screen = await meta.fields(p.key, type.id);
    out.fields = screen.fields;
    const priority = f.priority?.trim();
    if (priority) {
      const scheme = screen.priorities;
      if (scheme === null) out.dropPriority = true;
      else {
        const match = sameName(priority, scheme);
        if (!match) return { ...out, problem: { field: 'priority', message: `${priority} isn’t a priority in ${p.key}. Pick one.` } };
        out.priority = match;
      }
    }
    return out;
  } catch (err) {
    if (jiraUnreachable(err)) return { ...out, unchecked: true };
    throw err;
  }
}
