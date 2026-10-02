import { createHash, timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import type { AddNoteRequest, AskRequest, CoreEvent, DistillCore, ModelSelection, NoteImage, Settings } from '../contracts.js';

export interface ServerOptions {
  core: DistillCore;
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
  return req;
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
    not_implemented: 501,
  };
  if (code && byCode[code] !== undefined) return { status: byCode[code]!, code, message };
  // A plain Error (no code/status) from a route whose core call throws for precondition failures.
  if (untyped && code === undefined && err instanceof Error) return { ...untyped, message };
  return { status: 500, code: 'internal_error', message };
}

// ───────────────────────────── routing ─────────────────────────────

type Handler = (ctx: { req: http.IncomingMessage; res: http.ServerResponse; params: string[]; body: () => Promise<unknown> }) => Promise<unknown>;

interface Route {
  method: string;
  pattern: RegExp;
  handler: Handler;
  stream?: boolean;
  /** Status for a plain Error thrown by the core on this route (precondition failures). Default: 500. */
  untyped?: { status: number; code: string };
}

const JOB_ACTIONS = ['approve', 'reply', 'allow', 'reject', 'cancel'] as const;

function buildRoutes(core: DistillCore, opts: { keepAliveMs: number; trackStream: (end: () => void) => () => void }): Route[] {
  const requireJob = (id: string) => {
    const job = core.getJob(id);
    if (!job) throw new HttpError(404, 'job_not_found', `no job with id "${id}"`);
    return job;
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
      method: 'POST',
      pattern: /^\/v1\/queue\/process$/,
      handler: async ({ body }) => {
        const o = asObject(await body());
        if (o.force !== undefined && typeof o.force !== 'boolean') throw bad('"force" must be a boolean');
        return { job: (await core.processQueue({ force: o.force === true })) ?? null };
      },
    },
    { method: 'POST', pattern: /^\/v1\/notes$/, untyped: { status: 400, code: 'invalid_request' }, handler: async ({ body }) => core.addNote(parseNote(await body())) },
    { method: 'GET', pattern: /^\/v1\/jobs$/, handler: async () => ({ jobs: core.listJobs() }) },
    { method: 'GET', pattern: /^\/v1\/jobs\/([^/]+)$/, handler: async ({ params }) => requireJob(params[0]!) },
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
        return { job: core.getJob(id) ?? null };
      },
    },
    { method: 'POST', pattern: /^\/v1\/ask$/, handler: async ({ body }) => core.ask(parseAsk(await body())) },
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
          res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
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
      const result = await hit.r.handler({ req, res, params, body: () => readBody(req, maxBody) });
      if (hit.r.stream) return;
      const status = req.method === 'POST' && pathname === '/v1/notes' ? 201 : 200;
      sendJSON(res, status, result ?? null);
    } catch (err) {
      if (err instanceof HttpError) {
        const close = err.status === 413;
        sendError(res, err.status, err.code, err.message, close ? { Connection: 'close' } : {});
        if (close) res.once("finish", () => req.destroy());
        return;
      }
      const mapped = coreErrorStatus(err, matchedRoute?.untyped);
      sendError(res, mapped.status, mapped.code, mapped.message);
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
