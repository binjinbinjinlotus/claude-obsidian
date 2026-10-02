import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

/**
 * ISO-8601 without fractional seconds, e.g. `2026-10-01T15:42:00Z`.
 * Swift's `JSONDecoder.dateDecodingStrategy = .iso8601` rejects milliseconds,
 * so everything the core persists uses this form.
 */
export function isoDate(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

/** Parse an ISO-8601 date (with or without fractional seconds); invalid → undefined. */
export function parseDate(value: unknown): Date | undefined {
  if (typeof value !== 'string') return undefined;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? undefined : d;
}

/** Normalize a stored date string to the Swift-compatible form, or fall back. */
export function normalizeDate(value: unknown, fallback: Date): string {
  return isoDate(parseDate(value) ?? fallback);
}

export type JSONObject = Record<string, unknown>;

export function isObject(v: unknown): v is JSONObject {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Read and parse a JSON file; missing or unreadable → undefined. */
export function readJSON(file: string): unknown {
  let text: string;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch {
    return undefined;
  }
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

/** Recursively sort object keys (Swift writes `.sortedKeys`). */
function sortKeys(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (isObject(value)) {
    const out: JSONObject = {};
    for (const key of Object.keys(value).sort()) {
      const v = value[key];
      if (v !== undefined) out[key] = sortKeys(v);
    }
    return out;
  }
  return value;
}

export function encodeJSON(value: unknown): string {
  return JSON.stringify(sortKeys(value), null, 2) + '\n';
}

/** Atomic write: temp file in the same directory, fsync, then rename. */
export function writeFileAtomic(file: string, data: string | Uint8Array, mode?: number): void {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.${randomUUID()}.tmp`);
  const fd = fs.openSync(tmp, 'w', mode ?? 0o644);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally {
    fs.closeSync(fd);
  }
  try {
    fs.renameSync(tmp, file);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

export function writeJSONAtomic(file: string, value: unknown): void {
  writeFileAtomic(file, encodeJSON(value));
}

export function str(v: unknown): string | undefined {
  return typeof v === 'string' ? v : undefined;
}

export function num(v: unknown): number | undefined {
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined;
}

export function bool(v: unknown): boolean | undefined {
  return typeof v === 'boolean' ? v : undefined;
}

export function strArray(v: unknown): string[] | undefined {
  return Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : undefined;
}
