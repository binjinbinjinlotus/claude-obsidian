/**
 * Shared pieces for the plain model-API runners (OpenAI, OpenRouter, AI SDK):
 * image loading, JSON-schema handling for strict structured output, and HTTP
 * error mapping. No runtime dependencies: Node's built-in fetch only.
 */
import fs from 'node:fs';
import path from 'node:path';
import type { RunRequest, Settings } from '../contracts.js';
import { cancelledError, RunnerError } from './process.js';

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

const IMAGE_TYPES: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
};

/** Largest image we inline (base64 grows it by a third; providers cap request size). */
export const MAX_IMAGE_BYTES = 15 * 1024 * 1024;

export interface LoadedImage {
  path: string;
  mediaType: string;
  base64: string;
  dataURL: string;
}

export function loadImage(file: string): LoadedImage {
  const mediaType = IMAGE_TYPES[path.extname(file).toLowerCase()];
  if (!mediaType) {
    throw new RunnerError(`Unsupported image type ${path.extname(file) || '(none)'} for ${file}; use PNG, JPEG, GIF or WebP.`, 'unsupported');
  }
  let data: Buffer;
  try {
    data = fs.readFileSync(file);
  } catch (err) {
    throw new RunnerError(`Could not read image ${file}: ${(err as Error).message}`, 'launchFailed');
  }
  if (data.length > MAX_IMAGE_BYTES) throw new RunnerError(`Image too large (${data.length} bytes): ${file}`, 'unsupported');
  const base64 = data.toString('base64');
  return { path: file, mediaType, base64, dataURL: `data:${mediaType};base64,${base64}` };
}

export function loadImages(request: RunRequest): LoadedImage[] {
  return (request.images ?? []).map(loadImage);
}

// ───────────── JSON schema ─────────────

type Schema = Record<string, unknown>;

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

export function parseSchema(text: string): Schema {
  let s: unknown;
  try {
    s = JSON.parse(text);
  } catch (err) {
    throw new RunnerError(`outputSchema is not valid JSON: ${(err as Error).message}`, 'unsupported');
  }
  if (!isObj(s)) throw new RunnerError('outputSchema must be a JSON object', 'unsupported');
  return s;
}

/** Strict structured output (OpenAI, many OpenRouter models) needs every object to list its properties. */
export function canBeStrict(s: unknown): boolean {
  if (!isObj(s)) return true;
  if (s.type === 'object' || isObj(s.properties)) {
    if (!isObj(s.properties)) return false;
    if (s.additionalProperties !== undefined && s.additionalProperties !== false) return false;
    if (!Object.values(s.properties).every(canBeStrict)) return false;
  }
  if (s.items !== undefined && !canBeStrict(s.items)) return false;
  for (const k of ['anyOf', 'oneOf', 'allOf'] as const) {
    const list = s[k];
    if (Array.isArray(list) && !list.every(canBeStrict)) return false;
  }
  return true;
}

function nullable(p: unknown): unknown {
  if (!isObj(p)) return p;
  if (typeof p.type === 'string') {
    const out: Schema = { ...p, type: [p.type, 'null'] };
    if (Array.isArray(p.enum)) out.enum = [...p.enum, null];
    return out;
  }
  return { anyOf: [p, { type: 'null' }] };
}

/**
 * Rewrite a schema for strict mode: every object gets `additionalProperties:
 * false` and lists all its properties as required; properties that were
 * optional become nullable. `stripOptionalNulls` undoes this on the result.
 */
export function strictify(s: unknown): unknown {
  if (!isObj(s)) return s;
  const out: Schema = { ...s };
  if (isObj(s.properties)) {
    const required = new Set(Array.isArray(s.required) ? (s.required as string[]) : []);
    const props: Schema = {};
    for (const [k, v] of Object.entries(s.properties)) {
      const inner = strictify(v);
      props[k] = required.has(k) ? inner : nullable(inner);
    }
    out.properties = props;
    out.required = Object.keys(props);
    out.additionalProperties = false;
  }
  if (s.items !== undefined) out.items = strictify(s.items);
  for (const k of ['anyOf', 'oneOf', 'allOf'] as const) {
    const list = s[k];
    if (Array.isArray(list)) out[k] = list.map(strictify);
  }
  return out;
}

/** Remove `null` values the strict rewrite introduced for originally optional properties. */
export function stripOptionalNulls(value: unknown, original: unknown): unknown {
  if (!isObj(original)) return value;
  if (Array.isArray(value)) return original.items === undefined ? value : value.map((v) => stripOptionalNulls(v, original.items));
  if (!isObj(value) || !isObj(original.properties)) return value;
  const required = new Set(Array.isArray(original.required) ? (original.required as string[]) : []);
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(value)) {
    if (v === null && !required.has(k) && k in original.properties) continue;
    out[k] = stripOptionalNulls(v, original.properties[k]);
  }
  return out;
}

export interface PreparedSchema {
  original: Schema;
  /** What is sent to the provider. */
  wire: unknown;
  strict: boolean;
}

export function prepareSchema(text: string): PreparedSchema {
  const original = parseSchema(text);
  const strict = canBeStrict(original);
  return { original, wire: strict ? strictify(original) : original, strict };
}

/** Parse the model's JSON answer and undo the strict rewrite. */
export function parseStructured(text: string, schema: PreparedSchema): unknown {
  let value: unknown;
  try {
    value = JSON.parse(stripFence(text));
  } catch {
    throw new RunnerError(`Model did not return JSON: ${text.slice(0, 500)}`, 'malformedOutput');
  }
  return schema.strict ? stripOptionalNulls(value, schema.original) : value;
}

/** Some models wrap JSON in a ```json fence even in JSON mode. */
function stripFence(text: string): string {
  const m = /^\s*```(?:json)?\s*\n([\s\S]*?)\n?```\s*$/.exec(text);
  return m ? m[1]! : text;
}

// ───────────── HTTP ─────────────

export function runnerOption(settings: Settings, runnerID: string, key: string): string | undefined {
  const v = settings.runnerOptions?.[runnerID]?.[key];
  return typeof v === 'string' && v.trim().length > 0 ? v.trim() : undefined;
}

export function joinURL(base: string, suffix: string): string {
  return `${base.replace(/\/+$/, '')}/${suffix.replace(/^\/+/, '')}`;
}

function errorMessage(body: unknown): string | undefined {
  if (!isObj(body)) return undefined;
  const e = body.error;
  if (typeof e === 'string') return e;
  if (isObj(e) && typeof e.message === 'string') return e.message;
  if (typeof body.message === 'string') return body.message;
  return undefined;
}

/** POST JSON; map transport, abort and HTTP failures to RunnerError. Returns the parsed body and raw text. */
export async function postJSON(
  fetchImpl: FetchLike,
  url: string,
  headers: Record<string, string>,
  body: unknown,
  providerName: string,
  signal?: AbortSignal,
): Promise<{ json: Record<string, unknown>; raw: string }> {
  if (signal?.aborted) throw cancelledError();
  let res: Response;
  try {
    res = await fetchImpl(url, {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...headers },
      body: JSON.stringify(body),
      ...(signal ? { signal } : {}),
    });
  } catch (err) {
    if (signal?.aborted || (err as Error).name === 'AbortError') throw cancelledError();
    throw new RunnerError(`${providerName}: could not reach ${new URL(url).host}: ${(err as Error).message}`, 'apiError');
  }
  let raw: string;
  try {
    raw = await res.text();
  } catch (err) {
    if (signal?.aborted) throw cancelledError();
    throw new RunnerError(`${providerName}: reading the response failed: ${(err as Error).message}`, 'apiError');
  }
  let json: unknown;
  try {
    json = raw.length > 0 ? JSON.parse(raw) : {};
  } catch {
    json = undefined;
  }
  if (!res.ok) {
    const detail = errorMessage(json) ?? raw.slice(0, 500);
    const hint =
      res.status === 401 || res.status === 403
        ? 'the API key was rejected'
        : res.status === 429
          ? 'rate limited or out of credits'
          : res.status >= 500
            ? 'the provider had a server error'
            : 'the request was refused';
    throw new RunnerError(`${providerName} ${res.status}: ${hint}: ${detail}`, 'apiError');
  }
  if (!isObj(json)) throw new RunnerError(`${providerName}: unreadable response: ${raw.slice(0, 500)}`, 'malformedOutput');
  return { json, raw };
}

export function sessionIDOf(request: RunRequest): string {
  return 'start' in request.session ? request.session.start : request.session.resume;
}
