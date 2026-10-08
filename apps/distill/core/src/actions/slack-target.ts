/**
 * Where a Slack message goes (action-buttons.md, "Where to send"): the To row's kind (channel,
 * person, thread), the remembered names (name → @handle per vault) and the check a button makes
 * before it runs, so a plain name never reaches a script.
 *
 * The Mac app mirrors `resolveSlackTarget` (DistillKit SlackTarget.swift); both suites read the
 * same cases from slack-target.cases.json.
 */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { CoreError, type SlackPerson, type SlackTarget } from '../contracts.js';
import { isObject, preserveUnreadable, readJSON, str, writeJSONAtomic } from '../store/json.js';

/** What slack_cli.py accepts as a target (its resolve_channel): #channel, @handle, or an ID (C…, G…, D…, U…, W…). */
export const SLACK_TARGET_RULE = /^(#\S+|@\S+|[CGDUW][A-Z0-9]{2,})$/;
const CHANNEL_ID = /^[CG][A-Z0-9]{2,}$/;
const PERSON_ID = /^[DUW][A-Z0-9]{2,}$/;
const TS = /^\d{10}\.\d{6}$/;
/** slack.com or <workspace>.slack.com, nothing else. */
const SLACK_HOST = /^(?:[A-Za-z0-9-]+\.)*slack\.com$/;

/** "  Aditya   Pradhan " → "aditya pradhan". Only an exact match resolves ("Mei" is not "Mei Tanaka"). */
export function normalName(name: string): string {
  return name.trim().replace(/\s+/g, ' ').toLowerCase();
}

/**
 * A Slack message link or "channel ts" → the channel and the ts to reply under. A link's
 * `thread_ts` wins (the link points at a reply; the thread is its parent).
 */
export function parseThread(text: string): { channel?: string; ts: string } | undefined {
  const s = text.trim();
  if (!s) return undefined;
  // The host is slack.com or <workspace>.slack.com exactly: "evilslack.com" and "slack.com@x" are not Slack.
  const link = /^https?:\/\/(?:[A-Za-z0-9-]+\.)*slack\.com\/archives\/([CGD][A-Z0-9]{2,})\/p(\d{10})(\d{6})(?:[?#](\S*))?$/.exec(s);
  if (link) {
    const parent = /(?:^|&)thread_ts=(\d{10}\.\d{6})(?:&|$)/.exec(link[4] ?? '');
    return { channel: link[1]!, ts: parent ? parent[1]! : `${link[2]}.${link[3]}` };
  }
  if (TS.test(s)) return { ts: s };
  const pair = /^(#\S+|[CGD][A-Z0-9]{2,})\s+(\d{10}\.\d{6})$/.exec(s);
  if (pair) return { channel: pair[1]!, ts: pair[2]! };
  return undefined;
}

/**
 * Resolve the To row of a Slack message. `to` is what the item says (a name, #channel, @handle or
 * an ID); `thread` is its thread field; `lookup` finds a remembered name in the item's vault.
 */
export function resolveSlackTarget(to: string | null | undefined, thread: string | null | undefined, lookup: (name: string) => string | undefined): SlackTarget {
  const written = (to ?? '').trim();
  const threadText = (thread ?? '').trim();
  const parsed = threadText ? parseThread(threadText) : undefined;
  const base = toTarget(written, lookup);
  if (threadText && !parsed) {
    const host = /^https?:\/\/([^/?#\s]*)/i.exec(threadText)?.[1];
    const problem = host !== undefined && !SLACK_HOST.test(host)
      ? `“${threadText}” isn’t a link on slack.com, so Distill won’t reply to it.`
      : `“${threadText}” isn’t a Slack message link, so Distill can’t tell which thread to reply in.`;
    return { ...base, kind: 'thread', target: null, problem };
  }
  if (parsed) {
    // The link names the channel; the To row is then only who it's about.
    if (parsed.channel) return { kind: 'thread', written, target: parsed.channel, threadTs: parsed.ts, ...(base.name ? { name: base.name } : {}) };
    if (base.problem) return { ...base, kind: 'thread', threadTs: parsed.ts };
    return { ...base, kind: 'thread', threadTs: parsed.ts };
  }
  return base;
}

function toTarget(written: string, lookup: (name: string) => string | undefined): SlackTarget {
  if (!written) return { kind: 'person', written, target: null, problem: 'Choose who gets it first.' };
  if (written.includes(',')) {
    return { kind: 'person', written, target: null, problem: 'A button sends to one person or one channel. Pick one.' };
  }
  const channel = written.startsWith('#') || CHANNEL_ID.test(written);
  if (channel || written.startsWith('@') || PERSON_ID.test(written)) {
    // "@Mei Tanaka" is a display name with an @, not a handle: it never reaches a script.
    if (!SLACK_TARGET_RULE.test(written)) {
      return { kind: channel ? 'channel' : 'person', written, target: null, problem: `“${written}” isn’t an @handle, a #channel or a Slack ID. Write the @handle or #channel without spaces in the To row.` };
    }
    return { kind: channel ? 'channel' : 'person', written, target: written };
  }
  const found = lookup(normalName(written));
  if (found) return { kind: SLACK_CHANNELISH.test(found) ? 'channel' : 'person', written, target: found, name: written };
  return { kind: 'person', written, target: null, ask: `Who is ${written} in Slack?`, problem: `Distill doesn’t know who ${written} is in Slack yet. Add their @handle or ID in the To row.` };
}

const SLACK_CHANNELISH = /^(#|[CG][A-Z0-9])/;

/**
 * What the owner typed for a name: "aditya.p" → "@aditya.p" (handles are lower case; IDs upper
 * case). Anything that still isn't #channel, @handle or an ID is refused in plain words.
 */
export function normalizeSlackTarget(typed: string): string {
  let t = typed.trim();
  if (/^[a-z0-9][a-z0-9._-]*$/.test(t)) t = `@${t}`;
  if (!SLACK_TARGET_RULE.test(t)) throw new CoreError('invalid_request', `“${typed.trim()}” isn’t an @handle, a #channel or a Slack ID (U…, C…).`);
  return t;
}

/** The key of a vault in the people file (the collectors ledger's vault id). */
export function vaultKey(vaultPath: string): string {
  return createHash('sha256').update(path.resolve(vaultPath)).digest('hex').slice(0, 16);
}

/**
 * Remembered names: `<state>/actions/slack-people.json`,
 * `{ version: 1, vaults: { <vault id>: { vaultPath, people: { <normal name>: { name, target, savedAt } } } } }`.
 * Core state, not the vault (user-data.md). Lenient: an entry this build can't read is kept as it
 * was; a file that doesn't parse is set aside before the first save.
 */
export class SlackPeople {
  private raw: Record<string, unknown> = {};
  private loaded = false;
  constructor(private readonly file: string) {}

  private load(): void {
    if (this.loaded) return;
    this.loaded = true;
    if (!fs.existsSync(this.file)) return;
    const data = readJSON(this.file);
    if (!isObject(data) || !isObject(data.vaults)) {
      preserveUnreadable(this.file);
      return;
    }
    this.raw = data;
  }

  private vaults(): Record<string, unknown> {
    this.load();
    if (!isObject(this.raw.vaults)) this.raw.vaults = {};
    return this.raw.vaults as Record<string, unknown>;
  }

  private bucket(vaultPath: string, create: boolean): Record<string, unknown> | undefined {
    const vaults = this.vaults();
    const key = vaultKey(vaultPath);
    let v = vaults[key];
    if (!isObject(v) || !isObject(v.people)) {
      if (!create) return undefined;
      v = { vaultPath: path.resolve(vaultPath), people: {} };
      vaults[key] = v;
    }
    return (v as { people: Record<string, unknown> }).people;
  }

  list(vaultPath?: string | null): SlackPerson[] {
    const out: SlackPerson[] = [];
    for (const v of Object.values(this.vaults())) {
      if (!isObject(v) || !isObject(v.people)) continue;
      const vp = str(v.vaultPath);
      if (!vp || (vaultPath && path.resolve(vaultPath) !== path.resolve(vp))) continue;
      for (const p of Object.values(v.people)) {
        if (!isObject(p)) continue;
        const name = str(p.name);
        const target = str(p.target);
        if (name && target) out.push({ vaultPath: vp, name, target, savedAt: str(p.savedAt) ?? '' });
      }
    }
    return out.sort((a, b) => a.name.localeCompare(b.name));
  }

  lookup(vaultPath: string | null | undefined, name: string): string | undefined {
    if (!vaultPath) return undefined;
    const p = this.bucket(vaultPath, false)?.[normalName(name)];
    return isObject(p) ? str(p.target) : undefined;
  }

  remember(vaultPath: string, name: string, target: string, at: Date): SlackPerson {
    const people = this.bucket(vaultPath, true)!;
    const person: SlackPerson = { vaultPath: path.resolve(vaultPath), name: name.trim().replace(/\s+/g, ' '), target, savedAt: at.toISOString() };
    people[normalName(name)] = { name: person.name, target, savedAt: person.savedAt };
    this.save();
    return person;
  }

  forget(vaultPath: string, name: string): boolean {
    const people = this.bucket(vaultPath, false);
    const key = normalName(name);
    if (!people || !(key in people)) return false;
    delete people[key];
    this.save();
    return true;
  }

  private save(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    writeJSONAtomic(this.file, { ...this.raw, version: 1 });
  }
}
