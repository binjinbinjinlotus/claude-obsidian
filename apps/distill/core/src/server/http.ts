import { createHash, timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import type {
  ActionPatch,
  ActionQuery,
  ActionSource,
  ActionStatus,
  AddNoteRequest,
  AskRequest,
  ConnectRequest,
  CoreEvent,
  DistillCore,
  ExtractImageTextRequest,
  Job,
  LabelMatch,
  ModelSelection,
  NewActionInput,
  NoteImage,
  PermissionDenial,
  Settings,
} from '../contracts.js';
import { ACTION_STATUSES } from '../actions/store.js';
import type { EngineExtras } from '../engine/index.js';
import { suggestedRule } from '../runners/permissions.js';

/** The core the server exposes: the contract plus the proposed extras (501 when a core lacks them). */
export type ServerCore = DistillCore & Partial<EngineExtras>;

/** A permission denial as the API returns it: with the exact rule that would allow it (null = none). */
export type ApiPermissionDenial = PermissionDenial & { suggestedRule: string | null };

/** A job as the API returns it (also in `job` events): denials carry `suggestedRule`. */
export function apiJob(job: Job): Job {
  if (!job.approval) return job;
  const denials: ApiPermissionDenial[] = job.approval.denials.map((d) => ({ ...d, suggestedRule: suggestedRule(d) ?? null }));
  return { ...job, approval: { ...job.approval, denials } };
}

function apiEvent(event: CoreEvent): CoreEvent {
  return event.type === 'job' ? { ...event, job: apiJob(event.job) } : event;
}

export interface ServerOptions {
  core: ServerCore;
  host?: string; // must stay 127.0.0.1
  port?: number; // 0 = pick a free port
  token: string;
  /** Max request body in bytes (default 1 MiB). */
  maxBodyBytes?: number;
  /** SSE keep-alive comment interval in ms (default 15000). */
  keepAliveMs?: number;
}

export interface RunningServer {
  port: number;
  close(): Promise<void>;
}

/** Every error response is `{error: {code, message}}`. */
export class HttpError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

const LOCAL_HOSTNAMES = new Set(['127.0.0.1', 'localhost', '[::1]']);
const DEFAULT_MAX_BODY = 1024 * 1024;

function hostnameOf(hostHeader: string): string {
  // "[::1]:8080" -> "[::1]", "localhost:1" -> "localhost"
  if (hostHeader.startsWith('[')) {
    const end = hostHeader.indexOf(']');
    return end === -1 ? hostHeader : hostHeader.slice(0, end + 1);
  }
  const colon = hostHeader.indexOf(':');
  return (colon === -1 ? hostHeader : hostHeader.slice(0, colon)).toLowerCase();
}

function isLocalHost(hostHeader: string | undefined): boolean {
  return !!hostHeader && LOCAL_HOSTNAMES.has(hostnameOf(hostHeader.trim()));
}

function isLocalOrigin(origin: string | undefined): boolean {
  if (origin === undefined) return true;
  try {
    const url = new URL(origin);
    if (url.protocol !== 'http:' && url.protocol !== 'https:') return false;
    return LOCAL_HOSTNAMES.has(url.hostname.toLowerCase());
  } catch {
    return false; // includes the literal "null" origin
  }
}

function digest(value: string): Buffer {
  return createHash('sha256').update(value).digest();
}

function tokenMatches(header: string | undefined, expected: Buffer): boolean {
  if (!header) return false;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  if (!match?.[1]) return false;
  return timingSafeEqual(digest(match[1]), expected); // equal-length digests: no length leak, no throw
}

function sendJSON(res: http.ServerResponse, status: number, body: unknown, extraHeaders: Record<string, string> = {}): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    'X-Content-Type-Options': 'nosniff',
    ...extraHeaders,
  });
  res.end(payload);
}

function sendError(res: http.ServerResponse, status: number, code: string, message: string, headers: Record<string, string> = {}): void {
  if (res.headersSent) {
    res.destroy();
    return;
  }
  sendJSON(res, status, { error: { code, message } }, headers);
}

async function readBody(req: http.IncomingMessage, limit: number): Promise<unknown> {
  const declared = Number(req.headers['content-length'] ?? '0');
  if (Number.isFinite(declared) && declared > limit) {
    throw new HttpError(413, 'payload_too_large', `request body exceeds ${limit} bytes`);
  }
  const chunks: Buffer[] = [];
  let size = 0;
  // Event-based (not for-await) so an oversized chunked body is discarded, not
  // torn down mid-request: the 413 still reaches the client, then the socket closes.
  await new Promise<void>((resolve, reject) => {
    const onData = (chunk: Buffer) => {
      size += chunk.length;
      if (size > limit) {
        req.off('data', onData);
        req.off('end', onEnd);
        req.resume(); // discard the rest
        chunks.length = 0;
        reject(new HttpError(413, 'payload_too_large', `request body exceeds ${limit} bytes`));
        return;
      }
      chunks.push(chunk);
    };
    const onEnd = () => resolve();
    req.on('data', onData);
    req.on('end', onEnd);
    req.once('error', reject);
  });
  if (size === 0) return undefined;
  const type = (req.headers['content-type'] ?? '').split(';')[0]?.trim().toLowerCase();
  if (type !== 'application/json') {
    throw new HttpError(415, 'unsupported_media_type', 'request body must be application/json');
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw new HttpError(400, 'invalid_json', 'request body is not valid JSON');
  }
}

// ───────────────────────────── validation ─────────────────────────────

function bad(message: string): HttpError {
  return new HttpError(400, 'invalid_request', message);
}

function asObject(body: unknown, allowEmpty = true): Record<string, unknown> {
  if (body === undefined && allowEmpty) return {};
  if (typeof body !== 'object' || body === null || Array.isArray(body)) throw bad('request body must be a JSON object');
  return body as Record<string, unknown>;
}

function optString(obj: Record<string, unknown>, key: string): string | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'string') throw bad(`"${key}" must be a string`);
  return v;
}

function reqString(obj: Record<string, unknown>, key: string, allowEmpty = false): string {
  const v = optString(obj, key);
  if (v === undefined || (!allowEmpty && v.trim() === '')) throw bad(`"${key}" is required`);
  return v;
}

function optStringArray(obj: Record<string, unknown>, key: string): string[] | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v) || !v.every((x) => typeof x === 'string')) throw bad(`"${key}" must be an array of strings`);
  return v as string[];
}

function optEnum<T extends string>(obj: Record<string, unknown>, key: string, allowed: readonly T[]): T | undefined {
  const v = optString(obj, key);
  if (v === undefined) return undefined;
  if (!(allowed as readonly string[]).includes(v)) throw bad(`"${key}" must be one of ${allowed.map((a) => `"${a}"`).join(', ')}`);
  return v as T;
}

function optBoolean(obj: Record<string, unknown>, key: string): boolean | undefined {
  const v = obj[key];
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'boolean') throw bad(`"${key}" must be a boolean`);
  return v;
}

/** Label names: non-empty strings, a leading "#" dropped, trimmed, de-duplicated (order kept). */
function labelList(obj: Record<string, unknown>, key: string, required: boolean): string[] | undefined {
  const raw = optStringArray(obj, key);
  if (raw === undefined) {
    if (required) throw bad(`"${key}" must be an array of strings`);
    return undefined;
  }
  const out: string[] = [];
  for (const item of raw) {
    const name = item.trim().replace(/^#/, '').trim();
    if (!name) throw bad(`"${key}" must not contain empty labels`);
    if (/\s/.test(name)) throw bad(`label "${name}" must not contain spaces`);
    if (!out.includes(name)) out.push(name);
  }
  return out;
}

function parseSelection(v: unknown): ModelSelection | undefined {
  if (v === undefined || v === null) return undefined;
  const o = asObject(v, false);
  const effort = o.effort === null ? null : optString(o, 'effort');
  return { runnerID: reqString(o, 'runnerID'), model: reqString(o, 'model'), ...(effort !== undefined ? { effort } : {}) };
}

function parseAsk(body: unknown): AskRequest {
  const o = asObject(body, false);
  const req: AskRequest = { question: reqString(o, 'question') };
  const conversationID = optString(o, 'conversationID');
  const selection = parseSelection(o.selection);
  const labels = optStringArray(o, 'labels');
  const sources = optStringArray(o, 'sources');
  const vaultPath = optString(o, 'vaultPath');
  if (conversationID) req.conversationID = conversationID;
  if (selection) req.selection = selection;
  if (labels) req.labels = labels;
  if (sources) req.sources = sources;
  if (vaultPath) req.vaultPath = vaultPath;
  const labelMatch = optEnum<LabelMatch>(o, 'labelMatch', ['any', 'all']);
  const includeUnconfirmed = optBoolean(o, 'includeUnconfirmed');
  if (labelMatch) req.labelMatch = labelMatch;
  if (includeUnconfirmed !== undefined) req.includeUnconfirmed = includeUnconfirmed;
  return req;
}

function parseNote(body: unknown): AddNoteRequest {
  const o = asObject(body, false);
  const req: AddNoteRequest = { title: reqString(o, 'title'), text: reqString(o, 'text', true) };
  if (o.images !== undefined && o.images !== null) {
    if (!Array.isArray(o.images)) throw bad('"images" must be an array');
    req.images = o.images.map((img): NoteImage => {
      const io = asObject(img, false);
      const mode = optString(io, 'mode') ?? 'keep';
      if (mode !== 'keep' && mode !== 'extract') throw bad('image "mode" must be "keep" or "extract"');
      return { path: reqString(io, 'path'), mode };
    });
  }
  if (req.text.trim() === '' && !req.images?.length) throw bad('a note needs "text" or at least one image');
  const source = optString(o, 'source');
  const sourceRef = optString(o, 'sourceRef');
  const vaultPath = optString(o, 'vaultPath');
  if (source) req.source = source;
  if (sourceRef) req.sourceRef = sourceRef;
  if (vaultPath) req.vaultPath = vaultPath;
  const labels = labelList(o, 'labels', false);
  const suggest = optEnum(o, 'suggest', ['wait', 'background', 'none'] as const);
  const origin = optEnum(o, 'origin', ['app', 'cli'] as const);
  if (labels) req.labels = labels;
  if (suggest) req.suggest = suggest;
  if (origin) req.origin = origin;
  return req;
}

function parsePaths(o: Record<string, unknown>): string[] {
  const paths = optStringArray(o, 'paths');
  if (!paths || paths.length === 0 || paths.some((p) => p.trim() === '')) throw bad('"paths" must be a non-empty array of non-empty strings');
  return paths;
}

function parseConfirmItems(o: Record<string, unknown>): { path: string; labels: string[] }[] {
  const items = o.items;
  if (!Array.isArray(items) || items.length === 0) throw bad('"items" must be a non-empty array of {path, labels}');
  return items.map((item) => {
    const io = asObject(item, false);
    return { path: reqString(io, 'path'), labels: labelList(io, 'labels', true)! };
  });
}

// ───────────────────────────── actions ─────────────────────────────

function parseFields(v: unknown, key = 'fields'): Record<string, string | null> | undefined {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== 'object' || Array.isArray(v)) throw bad(`"${key}" must be an object of strings`);
  const out: Record<string, string | null> = {};
  for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
    if (x !== null && typeof x !== 'string') throw bad(`"${key}.${k}" must be a string or null`);
    out[k] = x;
  }
  return out;
}

function parseActionSource(v: unknown): ActionSource | undefined {
  if (v === undefined || v === null) return undefined;
  const o = asObject(v, false);
  const kind = optEnum(o, 'kind', ['note', 'ask', 'manual'] as const);
  if (kind === 'manual' || kind === undefined) {
    const by = optEnum(o, 'by', ['user', 'agent'] as const);
    return by === 'agent' ? { kind: 'manual', by: 'agent' } : { kind: 'manual' };
  }
  if (kind === 'ask') {
    const src: ActionSource = { kind: 'ask', conversationID: reqString(o, 'conversationID') };
    const question = optString(o, 'question');
    const quote = optString(o, 'quote');
    const citedPaths = optStringArray(o, 'citedPaths');
    if (question) src.question = question;
    if (quote) src.quote = quote;
    if (citedPaths) src.citedPaths = citedPaths;
    if (typeof o.turnIndex === 'number' && Number.isInteger(o.turnIndex) && o.turnIndex >= 0) src.turnIndex = o.turnIndex;
    if (o.gap === true) src.gap = true;
    return src;
  }
  const src: ActionSource = { kind: 'note' };
  for (const k of ['jobID', 'notePath', 'pageTitle', 'quote'] as const) {
    const x = optString(o, k);
    if (x) src[k] = x;
  }
  return src;
}

function parseNewAction(body: unknown): NewActionInput {
  const o = asObject(body, false);
  const input: NewActionInput = { type: optString(o, 'type') ?? 'todo', title: reqString(o, 'title') };
  if (o.body !== undefined) {
    if (o.body !== null && typeof o.body !== 'string') throw bad('"body" must be a string or null');
    input.body = o.body as string | null;
  }
  const fields = parseFields(o.fields);
  if (fields) input.fields = fields;
  const why = optString(o, 'why');
  if (why) input.why = why;
  const source = parseActionSource(o.source);
  if (source) input.source = source;
  const vaultPath = optString(o, 'vaultPath');
  if (vaultPath) input.vaultPath = vaultPath;
  const labels = optStringArray(o, 'labels');
  if (labels) input.labels = labels;
  return input;
}

function parsePatch(body: unknown): ActionPatch {
  const o = asObject(body, false);
  const patch: ActionPatch = {};
  const title = optString(o, 'title');
  if (title !== undefined) patch.title = title;
  if (o.body !== undefined) {
    if (o.body !== null && typeof o.body !== 'string') throw bad('"body" must be a string or null');
    patch.body = o.body as string | null;
  }
  const fields = parseFields(o.fields);
  if (fields) patch.fields = fields;
  const type = optString(o, 'type');
  if (type) patch.type = type;
  const labels = optStringArray(o, 'labels');
  if (labels) patch.labels = labels;
  return patch;
}

function parseIDs(o: Record<string, unknown>): string[] {
  const ids = optStringArray(o, 'ids');
  if (!ids || ids.length === 0 || ids.some((id) => id.trim() === '')) throw bad('"ids" must be a non-empty array of action ids');
  return ids;
}

function parseActionQuery(query: URLSearchParams): ActionQuery {
  const q: ActionQuery = {};
  const type = query.get('type');
  if (type) q.type = type;
  const status = query.get('status');
  if (status) {
    const list = status
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    for (const s of list) if (!(ACTION_STATUSES as string[]).includes(s)) throw bad(`unknown status "${s}"`);
    q.status = list as ActionStatus[];
  }
  const history = query.get('history');
  if (history !== null) q.history = history === '1' || history === 'true';
  const vault = query.get('vault');
  if (vault && vault.trim()) q.vaultPath = vault;
  const text = query.get('q');
  if (text && text.trim()) q.text = text;
  return q;
}

/** Abort the signal when the client closes the request (Cancel). */
async function abortOnClose<T>(res: http.ServerResponse, run: (signal: AbortSignal) => Promise<T>): Promise<T> {
  const controller = new AbortController();
  const onClose = () => {
    if (!res.writableFinished) controller.abort();
  };
  res.on('close', onClose);
  try {
    return await run(controller.signal);
  } finally {
    res.off('close', onClose);
  }
}

/** Replace every occurrence of a secret in an error message. */
function redact(message: string, secret: string | null | undefined): string {
  return secret ? message.split(secret).join('[redacted]') : message;
}

/** Map an error thrown by the core to an HTTP status. Core errors may carry `status` and/or `code`. */
function coreErrorStatus(err: unknown, untyped?: { status: number; code: string }): { status: number; code: string; message: string } {
  const e = err as { status?: unknown; statusCode?: unknown; code?: unknown; message?: unknown };
  const message = typeof e?.message === 'string' && e.message ? e.message : 'internal error';
  const declared = typeof e?.status === 'number' ? e.status : typeof e?.statusCode === 'number' ? e.statusCode : undefined;
  const code = typeof e?.code === 'string' ? e.code : undefined;
  if (declared !== undefined && declared >= 400 && declared < 600) return { status: declared, code: code ?? 'error', message };
  const byCode: Record<string, number> = {
    not_found: 404,
    invalid_request: 400,
    invalid: 400,
    conflict: 409,
    busy: 409,
    invalid_state: 409,
    no_vault: 409,
    not_implemented: 501,
  };
  if (code && byCode[code] !== undefined) return { status: byCode[code]!, code, message };
  // A plain Error (no code/status) from a route whose core call throws for precondition failures.
  if (untyped && code === undefined && err instanceof Error) return { ...untyped, message };
  return { status: 500, code: 'internal_error', message };
}

// ───────────────────────────── routing ─────────────────────────────

type Handler = (ctx: {
  req: http.IncomingMessage;
  res: http.ServerResponse;
  params: string[];
  query: URLSearchParams;
  body: () => Promise<unknown>;
  /** Push request secrets here; they are removed from any error message for this request. */
  secrets: string[];
}) => Promise<unknown>;

interface Route {
  method: string;
  pattern: RegExp;
  handler: Handler;
  stream?: boolean;
  /** Status for a plain Error thrown by the core on this route (precondition failures). Default: 500. */
  untyped?: { status: number; code: string };
  /** Response status on success (default 200). */
  status?: number;
}

const JOB_ACTIONS = ['approve', 'reply', 'allow', 'reject', 'cancel'] as const;

function buildRoutes(core: ServerCore, opts: { keepAliveMs: number; trackStream: (end: () => void) => () => void }): Route[] {
  const requireJob = (id: string) => {
    const job = core.getJob(id);
    if (!job) throw new HttpError(404, 'job_not_found', `no job with id "${id}"`);
    return job;
  };
  const extra = <K extends keyof EngineExtras>(name: K): NonNullable<EngineExtras[K]> => {
    const fn = core[name];
    if (typeof fn !== 'function') throw new HttpError(501, 'not_implemented', `${name}: not implemented by this core`);
    return fn.bind(core) as NonNullable<EngineExtras[K]>;
  };
  const vaultParam = (query: URLSearchParams) => {
    const v = query.get('vault');
    return v && v.trim() ? v : undefined;
  };

  const routes: Route[] = [
    { method: 'GET', pattern: /^\/v1\/status$/, handler: () => core.status() },
    { method: 'GET', pattern: /^\/v1\/settings$/, handler: async () => core.getSettings() },
    {
      method: 'PUT',
      pattern: /^\/v1\/settings$/,
      handler: async ({ body }) => core.updateSettings(asObject(await body(), false) as Partial<Settings>),
    },
    { method: 'GET', pattern: /^\/v1\/queue$/, handler: async () => ({ entries: core.listQueue() }) },
    {
      method: 'POST',
      pattern: /^\/v1\/queue\/files$/,
      untyped: { status: 400, code: 'invalid_request' },
      handler: async ({ body }) => {
        const paths = optStringArray(asObject(await body(), false), 'paths');
        if (!paths || paths.length === 0) throw bad('"paths" must be a non-empty array of strings');
        return { entries: await core.addQueueFiles(paths) };
      },
    },
    {
      method: 'DELETE',
      pattern: /^\/v1\/queue\/entries$/,
      untyped: { status: 400, code: 'invalid_request' },
      handler: async ({ body }) => {
        const removeQueueEntry = extra('removeQueueEntry');
        const file = reqString(asObject(await body(), false), 'path');
        return { entries: await removeQueueEntry(file) };
      },
    },
    {
      method: 'POST',
      pattern: /^\/v1\/queue\/process$/,
      handler: async ({ body }) => {
        const o = asObject(await body());
        if (o.force !== undefined && typeof o.force !== 'boolean') throw bad('"force" must be a boolean');
        const job = await core.processQueue({ force: o.force === true });
        return { job: job ? apiJob(job) : null };
      },
    },
    {
      method: 'POST',
      pattern: /^\/v1\/notes$/,
      status: 201,
      untyped: { status: 400, code: 'invalid_request' },
      handler: async ({ body }) => core.addNote(parseNote(await body())),
    },
    {
      method: 'POST',
      pattern: /^\/v1\/images\/extract$/,
      untyped: { status: 400, code: 'invalid_request' },
      handler: async ({ res, body }) => {
        const o = asObject(await body(), false);
        const req: ExtractImageTextRequest = { imagePath: reqString(o, 'imagePath') };
        const vaultPath = optString(o, 'vaultPath');
        if (vaultPath) req.vaultPath = vaultPath;
        // The client closing the request (Cancel) stops the runner.
        const controller = new AbortController();
        const onClose = () => {
          if (!res.writableFinished) controller.abort();
        };
        res.on('close', onClose);
        try {
          return await core.extractImageText(req, { signal: controller.signal });
        } finally {
          res.off('close', onClose);
        }
      },
    },
    {
      method: 'POST',
      pattern: /^\/v1\/notes\/([^/]+)\/labels$/,
      untyped: { status: 409, code: 'invalid_state' },
      handler: async ({ params, body }) => core.labelNote(params[0]!, labelList(asObject(await body(), false), 'labels', true)!),
    },
    { method: 'GET', pattern: /^\/v1\/labels$/, handler: async ({ query }) => ({ labels: await core.listLabels(vaultParam(query)) }) },
    {
      method: 'GET',
      pattern: /^\/v1\/pages$/,
      handler: async ({ query }) => {
        const raw = query.get('limit');
        let limit: number | undefined;
        if (raw !== null && raw.trim() !== '') {
          limit = Number(raw);
          if (!Number.isInteger(limit) || limit < 1) throw new HttpError(400, 'invalid_request', 'limit must be a positive integer');
        }
        const vaultPath = vaultParam(query);
        return { pages: await core.searchPages(query.get('q') ?? '', { ...(vaultPath ? { vaultPath } : {}), ...(limit ? { limit } : {}) }) };
      },
    },
    { method: 'GET', pattern: /^\/v1\/labels\/review$/, handler: async ({ query }) => core.labelReview(vaultParam(query)) },
    {
      method: 'POST',
      pattern: /^\/v1\/labels\/suggest$/,
      untyped: { status: 400, code: 'invalid_request' },
      handler: async ({ body }) => {
        const o = asObject(await body(), false);
        const paths = parsePaths(o);
        const vaultPath = optString(o, 'vaultPath');
        const selection = parseSelection(o.selection);
        const opts: { vaultPath?: string; selection?: ModelSelection } = {};
        if (vaultPath) opts.vaultPath = vaultPath;
        if (selection) opts.selection = selection;
        return { job: apiJob(await core.suggestLabelsForPages(paths, opts)) };
      },
    },
    {
      method: 'POST',
      pattern: /^\/v1\/labels\/confirm$/,
      untyped: { status: 400, code: 'invalid_request' },
      handler: async ({ body }) => {
        const o = asObject(await body(), false);
        const items = parseConfirmItems(o);
        const vaultPath = optString(o, 'vaultPath');
        return { job: apiJob(await (vaultPath ? core.confirmLabels(items, vaultPath) : core.confirmLabels(items))) };
      },
    },
    { method: 'GET', pattern: /^\/v1\/conversations$/, handler: async () => ({ conversations: await core.listConversations() }) },
    {
      method: 'GET',
      pattern: /^\/v1\/conversations\/([^/]+)$/,
      handler: async ({ params }) => {
        const conversation = await core.getConversation(params[0]!);
        if (!conversation) throw new HttpError(404, 'conversation_not_found', `no conversation with id "${params[0]}"`);
        return conversation;
      },
    },
    {
      method: 'DELETE',
      pattern: /^\/v1\/conversations\/([^/]+)$/,
      handler: async ({ params }) => {
        await core.deleteConversation(params[0]!);
        return { id: params[0]!, deleted: true };
      },
    },
    {
      method: 'POST',
      pattern: /^\/v1\/conversations\/([^/]+)\/pin$/,
      handler: async ({ params, body }) => {
        const pinned = optBoolean(asObject(await body(), false), 'pinned');
        if (pinned === undefined) throw bad('"pinned" must be a boolean');
        return core.setConversationPinned(params[0]!, pinned);
      },
    },
    { method: 'GET', pattern: /^\/v1\/runners$/, handler: async () => ({ runners: await core.listRunners() }) },
    {
      method: 'PUT',
      pattern: /^\/v1\/runners\/([^/]+)\/secrets\/([^/]+)$/,
      handler: async ({ params, body, secrets }) => {
        // Never echo, log or include the value in an error message.
        const o = asObject(await body(), false);
        if (!('value' in o)) throw bad('"value" is required (a string, or null to clear)');
        const value = o.value;
        if (value !== null && (typeof value !== 'string' || value.trim() === '')) {
          throw bad('"value" must be a non-empty string, or null to clear');
        }
        if (typeof value === 'string') secrets.push(value);
        await core.setRunnerSecret(params[0]!, params[1]!, value);
        return { runnerID: params[0]!, name: params[1]!, isSet: value !== null };
      },
    },
    { method: 'GET', pattern: /^\/v1\/jobs$/, handler: async () => ({ jobs: core.listJobs().map(apiJob) }) },
    { method: 'GET', pattern: /^\/v1\/jobs\/([^/]+)$/, handler: async ({ params }) => apiJob(requireJob(params[0]!)) },
    {
      method: 'DELETE',
      pattern: /^\/v1\/jobs\/([^/]+)$/,
      untyped: { status: 409, code: 'invalid_state' },
      handler: async ({ params }) => {
        const deleteJob = extra('deleteJob');
        requireJob(params[0]!);
        await deleteJob(params[0]!);
        return { id: params[0]!, deleted: true };
      },
    },
    {
      method: 'GET',
      pattern: /^\/v1\/jobs\/([^/]+)\/resume$/,
      handler: async ({ params }) => {
        const jobResumeCommand = extra('jobResumeCommand');
        requireJob(params[0]!);
        const argv = await jobResumeCommand(params[0]!);
        if (!argv || argv.length === 0) throw new HttpError(404, 'no_resume_command', `job "${params[0]}" has no session to resume`);
        return { argv };
      },
    },
    {
      method: 'POST',
      pattern: new RegExp(`^/v1/jobs/([^/]+)/(${JOB_ACTIONS.join('|')})$`),
      untyped: { status: 409, code: 'invalid_state' },
      handler: async ({ params, body }) => {
        const id = params[0]!;
        const action = params[1] as (typeof JOB_ACTIONS)[number];
        requireJob(id);
        const o = asObject(await body());
        switch (action) {
          case 'approve':
            await core.approve(id);
            break;
          case 'reply':
            await core.reply(id, reqString(o, 'text'));
            break;
          case 'allow': {
            const rules = optStringArray(o, 'rules');
            if (!rules || rules.length === 0) throw bad('"rules" must be a non-empty array of strings');
            await core.allow(id, rules);
            break;
          }
          case 'reject':
            await core.reject(id);
            break;
          case 'cancel':
            await core.cancel(id);
            break;
        }
        const job = core.getJob(id);
        return { job: job ? apiJob(job) : null };
      },
    },
    {
      method: 'POST',
      pattern: /^\/v1\/jobs\/([^/]+)\/actions\/find$/,
      untyped: { status: 409, code: 'invalid_state' },
      handler: async ({ params }) => {
        const findJobActions = extra('findJobActions');
        requireJob(params[0]!);
        return { job: apiJob(await findJobActions(params[0]!)) };
      },
    },
    { method: 'POST', pattern: /^\/v1\/ask$/, handler: async ({ body }) => core.ask(parseAsk(await body())) },
    {
      method: 'POST',
      pattern: /^\/v1\/conversations\/([^/]+)\/cancel$/,
      handler: async ({ params }) => {
        await core.cancelAsk(params[0]!);
        return { id: params[0]!, cancelled: true };
      },
    },
    { method: 'GET', pattern: /^\/v1\/progress$/, handler: async () => ({ progress: await core.listProgress() }) },

    // ── v3: actions (docs/specs/actions.md → API) ──
    { method: 'GET', pattern: /^\/v1\/action-types$/, handler: async () => ({ types: await core.listActionTypes() }) },
    { method: 'GET', pattern: /^\/v1\/actions$/, handler: async ({ query }) => ({ actions: await core.listActions(parseActionQuery(query)) }) },
    { method: 'POST', pattern: /^\/v1\/actions$/, status: 201, handler: async ({ body }) => core.createAction(parseNewAction(await body())) },
    {
      method: 'POST',
      pattern: /^\/v1\/actions\/confirm$/,
      handler: async ({ body }) => ({ actions: await core.confirmActions(parseIDs(asObject(await body(), false))) }),
    },
    {
      method: 'POST',
      pattern: /^\/v1\/actions\/dismiss$/,
      handler: async ({ body }) => {
        const ids = parseIDs(asObject(await body(), false));
        await core.dismissActions(ids);
        return { ids, dismissed: true };
      },
    },
    {
      method: 'GET',
      pattern: /^\/v1\/actions\/([^/]+)$/,
      handler: async ({ params }) => {
        const item = await core.getAction(params[0]!);
        if (!item) throw new HttpError(404, 'action_not_found', `no action with id "${params[0]}"`);
        return item;
      },
    },
    { method: 'PATCH', pattern: /^\/v1\/actions\/([^/]+)$/, handler: async ({ params, body }) => core.updateAction(params[0]!, parsePatch(await body())) },
    {
      method: 'DELETE',
      pattern: /^\/v1\/actions\/([^/]+)$/,
      handler: async ({ params }) => {
        await core.deleteActionForever(params[0]!);
        return { id: params[0]!, deleted: true };
      },
    },
    {
      method: 'POST',
      pattern: /^\/v1\/actions\/([^/]+)\/draft$/,
      handler: async ({ params, res }) => abortOnClose(res, (signal) => core.draftAction(params[0]!, { signal })),
    },
    {
      method: 'POST',
      pattern: /^\/v1\/actions\/([^/]+)\/improve$/,
      handler: async ({ params, res }) => abortOnClose(res, (signal) => core.improveAction(params[0]!, { signal })),
    },
    { method: 'POST', pattern: /^\/v1\/actions\/([^/]+)\/undo-improve$/, handler: async ({ params }) => core.undoImprove(params[0]!) },
    {
      method: 'POST',
      pattern: /^\/v1\/actions\/([^/]+)\/perform$/,
      handler: async ({ params, body }) => core.performAction(params[0]!, reqString(asObject(await body(), false), 'handler')),
    },
    {
      method: 'POST',
      pattern: /^\/v1\/actions\/([^/]+)\/send$/,
      handler: async ({ params, body }) => core.sendActionTo(params[0]!, reqString(asObject(await body(), false), 'type')),
    },
    { method: 'POST', pattern: /^\/v1\/actions\/([^/]+)\/remove$/, handler: async ({ params }) => core.removeAction(params[0]!) },
    { method: 'POST', pattern: /^\/v1\/actions\/([^/]+)\/restore$/, handler: async ({ params }) => core.restoreAction(params[0]!) },
    {
      method: 'POST',
      pattern: /^\/v1\/conversations\/([^/]+)\/actions\/detect$/,
      handler: async ({ params, body }) => {
        const turnIndex = asObject(await body()).turnIndex;
        if (turnIndex !== undefined && turnIndex !== null && (typeof turnIndex !== 'number' || !Number.isInteger(turnIndex) || turnIndex < 0)) {
          throw bad('"turnIndex" must be a non-negative integer');
        }
        const actions = typeof turnIndex === 'number' ? await core.detectAskActions(params[0]!, turnIndex) : await core.detectAskActions(params[0]!);
        return { actions };
      },
    },

    // ── v3: connections ──
    { method: 'GET', pattern: /^\/v1\/connections$/, handler: async () => ({ connections: await core.listConnections() }) },
    {
      method: 'POST',
      pattern: /^\/v1\/connections\/([^/]+)\/connect$/,
      handler: async ({ params, body, secrets }) => {
        // The token and email are never echoed or logged; they are scrubbed from error messages.
        const o = asObject(await body(), false);
        const req: ConnectRequest = {};
        const site = optString(o, 'site');
        const email = optString(o, 'email');
        const token = optString(o, 'token');
        if (token) secrets.push(token);
        if (email) secrets.push(email);
        if (site) req.site = site;
        if (email) req.email = email;
        if (token) req.token = token;
        return core.connect(params[0]!, req);
      },
    },
    {
      method: 'GET',
      pattern: /^\/v1\/connections\/([^/]+)\/sign-in-url$/,
      handler: async ({ params, query }) => {
        const site = query.get('site');
        return site ? core.signInURL(params[0]!, site) : core.signInURL(params[0]!);
      },
    },
    { method: 'POST', pattern: /^\/v1\/connections\/([^/]+)\/disconnect$/, handler: async ({ params }) => core.disconnect(params[0]!) },
    {
      method: 'GET',
      pattern: /^\/v1\/events$/,
      stream: true,
      handler: async ({ req, res }) => {
        res.writeHead(200, {
          'Content-Type': 'text/event-stream; charset=utf-8',
          'Cache-Control': 'no-store',
          Connection: 'keep-alive',
          'X-Accel-Buffering': 'no',
        });
        res.write('retry: 2000\n: connected\n\n');
        const send = (event: CoreEvent) => {
          res.write(`event: ${event.type}\ndata: ${JSON.stringify(apiEvent(event))}\n\n`);
        };
        const unsubscribe = core.subscribe(send);
        const timer = setInterval(() => res.write(': keep-alive\n\n'), opts.keepAliveMs);
        timer.unref();
        let done = false;
        const cleanup = () => {
          if (done) return;
          done = true;
          clearInterval(timer);
          unsubscribe();
          untrack();
        };
        const untrack = opts.trackStream(() => {
          cleanup();
          res.end();
        });
        req.on('close', cleanup);
        res.on('close', cleanup);
        return undefined;
      },
    },
  ];
  return routes;
}

/** Start the local Distill HTTP API. Binds 127.0.0.1 only; every request needs the bearer token. */
export async function startServer(opts: ServerOptions): Promise<RunningServer> {
  const host = opts.host ?? '127.0.0.1';
  if (host !== '127.0.0.1') throw new Error('the Distill server binds 127.0.0.1 only');
  if (!opts.token || opts.token.length < 16) throw new Error('a token of at least 16 characters is required');
  const expected = digest(opts.token);
  const maxBody = opts.maxBodyBytes ?? DEFAULT_MAX_BODY;
  const streams = new Set<() => void>();
  const routes = buildRoutes(opts.core, {
    keepAliveMs: opts.keepAliveMs ?? 15_000,
    trackStream: (end) => {
      streams.add(end);
      return () => streams.delete(end);
    },
  });

  const server = http.createServer(async (req, res) => {
    let matchedRoute: Route | undefined;
    const secrets: string[] = [];
    const clean = (message: string) => secrets.reduce((m, secret) => redact(m, secret), message);
    try {
      if (!isLocalHost(req.headers.host)) {
        return sendError(res, 403, 'forbidden_host', 'requests must use a local Host (127.0.0.1 or localhost)');
      }
      const origin = req.headers.origin;
      if (!isLocalOrigin(typeof origin === 'string' ? origin : undefined)) {
        return sendError(res, 403, 'forbidden_origin', 'cross-origin requests are not allowed');
      }
      if (!tokenMatches(req.headers.authorization, expected)) {
        return sendError(res, 401, 'unauthorized', 'missing or invalid bearer token', { 'WWW-Authenticate': 'Bearer' });
      }
      const url = new URL(req.url ?? '/', 'http://127.0.0.1');
      const pathname = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, '') : url.pathname;
      const matching = routes
        .map((r) => ({ r, m: r.pattern.exec(pathname) }))
        .filter((x): x is { r: Route; m: RegExpExecArray } => x.m !== null);
      if (matching.length === 0) return sendError(res, 404, 'not_found', `no route for ${pathname}`);
      const hit = matching.find((x) => x.r.method === req.method);
      if (!hit) {
        const allow = [...new Set(matching.map((x) => x.r.method))].join(', ');
        return sendError(res, 405, 'method_not_allowed', `${req.method} is not allowed on ${pathname}`, { Allow: allow });
      }
      matchedRoute = hit.r;
      let params: string[];
      try {
        params = hit.m.slice(1).map((p) => decodeURIComponent(p));
      } catch {
        throw bad('malformed path');
      }
      const result = await hit.r.handler({ req, res, params, query: url.searchParams, secrets, body: () => readBody(req, maxBody) });
      if (hit.r.stream) return;
      sendJSON(res, hit.r.status ?? 200, result ?? null);
    } catch (err) {
      if (err instanceof HttpError) {
        const close = err.status === 413;
        sendError(res, err.status, err.code, clean(err.message), close ? { Connection: 'close' } : {});
        if (close) res.once("finish", () => req.destroy());
        return;
      }
      const mapped = coreErrorStatus(err, matchedRoute?.untyped);
      sendError(res, mapped.status, mapped.code, clean(mapped.message));
    }
  });
  server.requestTimeout = 0; // SSE streams are long-lived; Ask can take minutes
  server.headersTimeout = 30_000;

  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(opts.port ?? 0, host, () => {
      server.off('error', reject);
      resolve();
    });
  });
  const address = server.address();
  const port = typeof address === 'object' && address ? address.port : 0;

  let closing: Promise<void> | null = null;
  return {
    port,
    close() {
      closing ??= new Promise<void>((resolve) => {
        for (const end of [...streams]) end();
        server.close(() => resolve());
        server.closeIdleConnections();
        setTimeout(() => server.closeAllConnections(), 1000).unref();
      });
      return closing;
    },
  };
}
