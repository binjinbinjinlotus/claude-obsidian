import { AsyncLocalStorage } from 'node:async_hooks';
import type { ActivitySource } from '../contracts.js';

/**
 * Who started the work running now. The HTTP server enters a context per request
 * (from `X-Distill-Client` / User-Agent); the engine's and collectors' timers enter
 * `scheduler`. Work a request starts in the background (a batch, a run) inherits it.
 */
interface ActivityContext {
  source: ActivitySource;
  /** The core method being logged right now (the wrapper sets it; event listeners read it to avoid double entries). */
  method?: string;
}

const storage = new AsyncLocalStorage<ActivityContext>();

export function runWithSource<T>(source: ActivitySource, fn: () => T): T {
  return storage.run({ source }, fn);
}

/** Timer entry points: everything the callback does counts as Distill's own work. */
export function asScheduler<A extends unknown[], R>(fn: (...args: A) => R): (...args: A) => R {
  return (...args: A) => storage.run({ source: 'scheduler' }, () => fn(...args));
}

export function runInMethod<T>(method: string, fn: () => T): T {
  const current = storage.getStore();
  return storage.run({ source: current?.source ?? 'core', method }, fn);
}

/** `core` when no request or timer started this work (tests, dev scripts). */
export function currentSource(): ActivitySource {
  return storage.getStore()?.source ?? 'core';
}

export function currentMethod(): string | undefined {
  return storage.getStore()?.method;
}

export const CLIENT_HEADER = 'x-distill-client';
const CLIENT_VALUES: Record<string, ActivitySource> = { app: 'app', cli: 'cli', agent: 'agent', plugin: 'agent' };

/**
 * The source of an HTTP request: the `X-Distill-Client` header (app, cli, agent; plugin = agent),
 * else the Mac app's URLSession User-Agent ("Distill/<build> CFNetwork/… Darwin/…"), else `api`.
 */
export function sourceFromHeaders(headers: Record<string, string | string[] | undefined>): ActivitySource {
  const raw = headers[CLIENT_HEADER];
  const value = (Array.isArray(raw) ? raw[0] : raw)?.trim().toLowerCase();
  if (value && CLIENT_VALUES[value]) return CLIENT_VALUES[value]!;
  const ua = headers['user-agent'];
  const agent = Array.isArray(ua) ? ua[0] : ua;
  if (agent && /^Distill\/\S*\s.*CFNetwork\//.test(agent)) return 'app';
  return 'api';
}
