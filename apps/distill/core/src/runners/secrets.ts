import { spawnSync } from 'node:child_process';
import fs from 'node:fs';

/**
 * Where runner secrets (API keys) live. They never go into settings.json.
 * Keys are addressed as (runnerID, name), e.g. ("openrouter", "apiKey").
 */
export interface SecretStore {
  get(runnerID: string, name: string): Promise<string | undefined>;
  /** null deletes. */
  set(runnerID: string, name: string, value: string | null): Promise<void>;
  /** Synchronous presence check for `problems()`; may be cached briefly. */
  hasSync(runnerID: string, name: string): boolean;
}

/** Environment variables honored when the store has no value (headless use, CI). */
export const SECRET_ENV_FALLBACKS: Record<string, string> = {
  'openrouter.apiKey': 'OPENROUTER_API_KEY',
  'openai.apiKey': 'OPENAI_API_KEY',
};

export const KEYCHAIN_SERVICE = 'com.claude-obsidian.distill';

const SAFE_PART = /^[A-Za-z0-9._-]+$/;

function account(runnerID: string, name: string): string {
  if (!SAFE_PART.test(runnerID) || !SAFE_PART.test(name)) {
    throw new Error(`Invalid secret address ${runnerID}.${name}`);
  }
  return `${runnerID}.${name}`;
}

export class MemorySecretStore implements SecretStore {
  readonly values = new Map<string, string>();

  async get(runnerID: string, name: string): Promise<string | undefined> {
    return this.values.get(account(runnerID, name));
  }

  async set(runnerID: string, name: string, value: string | null): Promise<void> {
    const key = account(runnerID, name);
    if (value === null) this.values.delete(key);
    else this.values.set(key, value);
  }

  hasSync(runnerID: string, name: string): boolean {
    return this.values.has(account(runnerID, name));
  }
}

export interface SecurityOutput {
  status: number;
  stdout: string;
  stderr: string;
}

/** Runs /usr/bin/security with argv (never a shell) and optional stdin. Injectable for tests. */
export type SecurityLauncher = (args: string[], stdin?: string) => SecurityOutput;

const SECURITY = '/usr/bin/security';

export const runSecurity: SecurityLauncher = (args, stdin) => {
  const r = spawnSync(SECURITY, args, { input: stdin ?? '', encoding: 'utf8', timeout: 15_000 });
  return { status: r.status ?? 1, stdout: r.stdout ?? '', stderr: r.stderr ?? '' };
};

/** `security` exit status for "item not found". */
const NOT_FOUND = 44;

/**
 * Decode the `password:` line that `find-generic-password -g` prints on
 * stderr. `-w` is not used: it prints non-ASCII values as bare hex, which is
 * indistinguishable from a hex-looking key. `-g` prints
 * `password: 0x<HEX>  "<escaped>"` whenever the value needs escaping (exact
 * bytes in the hex), otherwise `password: "<value>"`.
 */
export function parsePasswordLine(stderr: string): string | undefined {
  for (const line of stderr.split('\n')) {
    const hex = /^password: 0x([0-9A-Fa-f]*)(?:\s|$)/.exec(line);
    if (hex) return Buffer.from(hex[1]!, 'hex').toString('utf8');
    const plain = /^password: "(.*)"$/.exec(line);
    if (plain) return plain[1]!;
    if (line === 'password: ') return '';
  }
  return undefined;
}

/**
 * macOS Keychain (login keychain) through `/usr/bin/security`.
 *
 * - Write: the value never appears on argv (where `ps` could see it). We run
 *   `security -i` and send `add-generic-password -U -s <service> -a <account> -X <hex>`
 *   on stdin; hex needs no quoting inside security's command parser.
 * - Read: `find-generic-password -s <service> -a <account> -g` (see parsePasswordLine).
 * - Delete: `delete-generic-password -s <service> -a <account>`.
 *
 * Items are created by `security` itself, so later reads through `security`
 * do not prompt.
 */
export class KeychainSecretStore implements SecretStore {
  private readonly cache = new Map<string, { present: boolean; at: number }>();

  constructor(
    private readonly launch: SecurityLauncher = runSecurity,
    readonly service: string = KEYCHAIN_SERVICE,
    private readonly cacheMs = 30_000,
  ) {}

  async get(runnerID: string, name: string): Promise<string | undefined> {
    const acct = account(runnerID, name);
    const r = this.launch(['find-generic-password', '-s', this.service, '-a', acct, '-g']);
    if (r.status === NOT_FOUND) {
      this.cache.set(acct, { present: false, at: Date.now() });
      return undefined;
    }
    if (r.status !== 0) throw new Error(`Keychain read failed (${r.status}): ${r.stderr.trim()}`);
    const value = parsePasswordLine(r.stderr);
    if (value === undefined) throw new Error('Keychain read failed: unexpected `security -g` output');
    this.cache.set(acct, { present: value.length > 0, at: Date.now() });
    return value.length > 0 ? value : undefined;
  }

  async set(runnerID: string, name: string, value: string | null): Promise<void> {
    const acct = account(runnerID, name);
    this.cache.delete(acct);
    if (value === null) {
      const r = this.launch(['delete-generic-password', '-s', this.service, '-a', acct]);
      if (r.status !== 0 && r.status !== NOT_FOUND) {
        throw new Error(`Keychain delete failed (${r.status}): ${r.stderr.trim()}`);
      }
      return;
    }
    const hex = Buffer.from(value, 'utf8').toString('hex');
    const r = this.launch(['-i'], `add-generic-password -U -s ${this.service} -a ${acct} -X ${hex}\n`);
    // `security -i` exits 0 even when a command fails; failures show on stderr.
    if (r.status !== 0 || r.stderr.trim().length > 0) {
      throw new Error(`Keychain write failed (${r.status}): ${r.stderr.trim()}`);
    }
  }

  hasSync(runnerID: string, name: string): boolean {
    const acct = account(runnerID, name);
    const hit = this.cache.get(acct);
    if (hit && Date.now() - hit.at < this.cacheMs) return hit.present;
    // No -w: prints attributes only, so the value is never read here.
    const r = this.launch(['find-generic-password', '-s', this.service, '-a', acct]);
    const present = r.status === 0;
    this.cache.set(acct, { present, at: Date.now() });
    return present;
  }
}

/** For hosts without a Keychain (Linux, CI): nothing is stored, env fallbacks still apply. */
export class UnavailableSecretStore implements SecretStore {
  async get(): Promise<string | undefined> {
    return undefined;
  }
  async set(): Promise<void> {
    throw new Error('No secret store on this platform; set the environment variable instead.');
  }
  hasSync(): boolean {
    return false;
  }
}

let shared: SecretStore | undefined;

/** One store per process, shared by the runners and the admin API. */
export function defaultSecretStore(): SecretStore {
  if (!shared) {
    shared = process.platform === 'darwin' && fs.existsSync(SECURITY) ? new KeychainSecretStore() : new UnavailableSecretStore();
  }
  return shared;
}

/** Store first, then the environment fallback. */
export async function resolveSecret(
  store: SecretStore,
  runnerID: string,
  name: string,
  env: NodeJS.ProcessEnv = process.env,
): Promise<string | undefined> {
  let value: string | undefined;
  try {
    value = await store.get(runnerID, name);
  } catch {
    value = undefined;
  }
  if (value) return value;
  const envName = SECRET_ENV_FALLBACKS[`${runnerID}.${name}`];
  const fromEnv = envName ? env[envName] : undefined;
  return fromEnv ? fromEnv : undefined;
}

export function secretIsSet(store: SecretStore, runnerID: string, name: string, env: NodeJS.ProcessEnv = process.env): boolean {
  const envName = SECRET_ENV_FALLBACKS[`${runnerID}.${name}`];
  if (envName && env[envName]) return true;
  try {
    return store.hasSync(runnerID, name);
  } catch {
    return false;
  }
}
