/**
 * Automations: a script's commands, run from action buttons (action-buttons.md).
 *
 * The safety contract, each rule tested in commands.test.ts:
 * 1. One template is one argv element: values are never split, joined or re-quoted.
 * 2. A single pass: a value is never scanned again ("{title}" inside a body stays text).
 * 3. An unknown placeholder is an error, never left as typed.
 * 4. A required argument that ends up empty is an error; an optional flag with an empty value is
 *    dropped with its flag; a switch is on only for true / yes / 1 / on.
 * 5. A pattern that doesn't match is an error with its hint.
 * 6. NUL is refused (argv can't carry it); an element over 100 KB is refused.
 * The process is spawned with an argv array, never through a shell.
 */
import { createHash } from 'node:crypto';
import { CoreError, type ActionButton, type ScriptCommand, type ScriptCommandArg, type ScriptResultParse } from '../contracts.js';

export const MAX_ARG_BYTES = 100 * 1024;
export const DEFAULT_COMMAND_TIMEOUT_SECONDS = 60;
export const MAX_COMMAND_TIMEOUT_SECONDS = 3600;

/** Values a template may use: "title", "fields.to", … → the text (null/undefined = known but empty). */
export type TemplateValues = Record<string, string | null | undefined>;

export class TemplateError extends Error {}

/** Fill one template in a single pass. `{{` and `}}` are literal braces. */
export function renderArg(template: string, values: TemplateValues): string {
  let out = '';
  let i = 0;
  while (i < template.length) {
    const c = template[i]!;
    if (c === '{' && template[i + 1] === '{') {
      out += '{';
      i += 2;
      continue;
    }
    if (c === '}' && template[i + 1] === '}') {
      out += '}';
      i += 2;
      continue;
    }
    if (c === '{') {
      const end = template.indexOf('}', i + 1);
      if (end < 0) throw new TemplateError(`“${template.slice(i)}”: a { without a closing }`);
      const name = template.slice(i + 1, end).trim();
      if (!Object.prototype.hasOwnProperty.call(values, name)) throw new TemplateError(`{${name}} isn’t a field you can use here`);
      out += values[name] ?? '';
      i = end + 1;
      continue;
    }
    out += c;
    i += 1;
  }
  return out;
}

/** The placeholders a template uses (for the editor's checks). */
export function placeholdersIn(template: string): string[] {
  const out: string[] = [];
  const re = /\{\{|\}\}|\{([^{}]*)\}/g;
  for (const m of template.matchAll(re)) if (m[1] !== undefined) out.push(m[1].trim());
  return out;
}

const ON = new Set(['true', 'yes', '1', 'on']);

export interface BuiltArgv {
  /** After the script path. */
  args: string[];
  problems: string[];
}

/** The arguments a command gets from a button's bindings. Problems refuse the run. */
export function buildArgv(command: ScriptCommand, bindings: Record<string, string>, values: TemplateValues): BuiltArgv {
  const problems: string[] = [];
  const head: string[] = [];
  const positionals: string[] = [];
  const endOptions = command.endOptions !== false;
  for (const arg of command.args) {
    if (arg.kind === 'word') {
      if (arg.value) head.push(arg.value);
      continue;
    }
    const template = bindings[arg.name] ?? '';
    let value: string;
    try {
      value = renderArg(template, values);
    } catch (err) {
      problems.push(`${arg.name}: ${(err as Error).message}`);
      continue;
    }
    if (value.includes('\u0000')) {
      problems.push(`${arg.name}: contains a NUL character, which a command line can't carry`);
      continue;
    }
    if (Buffer.byteLength(value, 'utf8') > MAX_ARG_BYTES) {
      problems.push(`${arg.name}: too long for a command line; read DISTILL_ACTION_JSON instead`);
      continue;
    }
    if (arg.kind === 'switch') {
      if (ON.has(value.trim().toLowerCase()) && arg.flag) head.push(arg.flag);
      continue;
    }
    const required = arg.required ?? arg.kind === 'positional';
    if (value === '') {
      if (required) problems.push(`${arg.name}: needs a value`);
      continue;
    }
    if (arg.pattern) {
      let ok = false;
      try {
        ok = new RegExp(arg.pattern).test(value);
      } catch {
        problems.push(`${arg.name}: the pattern isn't a valid regular expression`);
        continue;
      }
      if (!ok) {
        const shown = value.length > 60 ? `${value.slice(0, 57)}…` : value;
        problems.push(`${arg.name}: “${shown}” isn’t ${arg.hint ?? `in the form ${arg.pattern}`}`);
        continue;
      }
    }
    if (arg.kind === 'flag') {
      if (!arg.flag) {
        problems.push(`${arg.name}: no flag name`);
        continue;
      }
      head.push(arg.flag, value);
    } else {
      positionals.push(value);
    }
  }
  const args = positionals.length > 0 && endOptions ? [...head, '--', ...positionals] : [...head, ...positionals];
  return { args, problems };
}

/** What a run printed, read the way the command says. */
export function parseResult(stdout: string, parse: ScriptResultParse | undefined): { key?: string; url?: string; status?: string; message?: string } {
  const out: { key?: string; url?: string; status?: string; message?: string } = {};
  const lines = stdout.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (parse?.json) {
    for (let i = lines.length - 1; i >= 0; i--) {
      try {
        const v = JSON.parse(lines[i]!) as unknown;
        if (v && typeof v === 'object' && !Array.isArray(v)) {
          const o = v as Record<string, unknown>;
          for (const k of ['key', 'url', 'status', 'message'] as const) if (typeof o[k] === 'string' && o[k]) out[k] = o[k] as string;
          break;
        }
      } catch {
        // not JSON: keep looking upwards
      }
    }
  }
  const group = (pattern: string | undefined, name: string): string | undefined => {
    if (!pattern) return undefined;
    try {
      const m = new RegExp(pattern).exec(stdout);
      return m ? (m.groups?.[name] ?? m[1] ?? undefined) : undefined;
    } catch {
      return undefined;
    }
  };
  const key = out.key ?? group(parse?.keyPattern, 'key');
  const url = out.url ?? group(parse?.urlPattern, 'url');
  if (key) out.key = key;
  if (url) out.url = url;
  if (!out.message && lines.length > 0) out.message = lines[lines.length - 1]!.slice(0, 200);
  return out;
}

/** Approval of a button's exact command: changes with the script version, the command, or the mapping. */
export function approvalHash(scriptConsentHash: string, command: ScriptCommand, button: Pick<ActionButton, 'bindings' | 'scriptId' | 'commandId'>): string {
  const sorted = Object.fromEntries(Object.entries(button.bindings).sort(([a], [b]) => a.localeCompare(b)));
  return createHash('sha256')
    .update(JSON.stringify([scriptConsentHash, command, sorted, button.scriptId, button.commandId]))
    .digest('hex');
}

/** For reading only: an argv as one shell-quoted line. */
export function displayArgv(argv: string[]): string {
  return argv.map((a) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(a) ? a : `'${a.replace(/'/g, `'\\''`)}'`)).join(' ');
}

/** Masks secrets in output and argv: URL credentials, Bearer tokens, Slack tokens. */
export function maskSecrets(s: string): string {
  return s
    .replace(/(https?:\/\/)[^\s/:@]+:[^\s/@]+@/g, '$1***@')
    .replace(/(Bearer\s+)[A-Za-z0-9._~+/=-]+/gi, '$1***')
    .replace(/xox[a-z]-[A-Za-z0-9-]+/g, 'xox*-***');
}

export function commandTimeout(command: ScriptCommand): number {
  const t = command.timeoutSeconds ?? DEFAULT_COMMAND_TIMEOUT_SECONDS;
  return Math.min(MAX_COMMAND_TIMEOUT_SECONDS, Math.max(1, Math.round(t)));
}

/** Commands as the owner declared them: checked before they are saved (action-buttons.md). */
export function validCommands(input: unknown): ScriptCommand[] {
  if (!Array.isArray(input)) throw new CoreError('invalid_request', 'commands must be a list.');
  const ids = new Set<string>();
  return input.map((raw, i) => {
    const c = (raw ?? {}) as Record<string, unknown>;
    const id = typeof c.id === 'string' ? c.id.trim() : '';
    if (!/^[a-z0-9][a-z0-9_-]{0,39}$/i.test(id)) throw new CoreError('invalid_request', `Command ${i + 1}: the id must be a short slug ("send").`);
    if (ids.has(id)) throw new CoreError('invalid_request', `Command ${id} is listed twice.`);
    ids.add(id);
    const label = typeof c.label === 'string' && c.label.trim() ? c.label.trim() : id;
    const argsIn = Array.isArray(c.args) ? c.args : [];
    const names = new Set<string>();
    const args = argsIn.map((a0, j) => {
      const a = (a0 ?? {}) as Record<string, unknown>;
      const kind = a.kind;
      if (kind !== 'word' && kind !== 'flag' && kind !== 'switch' && kind !== 'positional') throw new CoreError('invalid_request', `${id}, argument ${j + 1}: kind is word, flag, switch or positional.`);
      const name = typeof a.name === 'string' && a.name.trim() ? a.name.trim() : kind === 'word' ? `word${j + 1}` : '';
      if (!name) throw new CoreError('invalid_request', `${id}, argument ${j + 1}: needs a name.`);
      if (names.has(name)) throw new CoreError('invalid_request', `${id}: two arguments are named ${name}.`);
      names.add(name);
      const out: ScriptCommandArg = { name, kind };
      if (kind === 'word') {
        if (typeof a.value !== 'string' || !a.value) throw new CoreError('invalid_request', `${id}, ${name}: a word needs its text.`);
        out.value = a.value;
      }
      if (kind === 'flag' || kind === 'switch') {
        if (typeof a.flag !== 'string' || !/^-{1,2}[A-Za-z0-9][A-Za-z0-9_-]*$/.test(a.flag)) throw new CoreError('invalid_request', `${id}, ${name}: the flag looks like --thread.`);
        out.flag = a.flag;
      }
      if (typeof a.required === 'boolean') out.required = a.required;
      if (typeof a.pattern === 'string' && a.pattern) {
        try {
          new RegExp(a.pattern);
        } catch {
          throw new CoreError('invalid_request', `${id}, ${name}: the pattern isn't a valid regular expression.`);
        }
        out.pattern = a.pattern;
      }
      if (typeof a.hint === 'string' && a.hint) out.hint = a.hint;
      return out;
    });
    const cmd: ScriptCommand = { id, label, args };
    if (typeof c.description === 'string' && c.description) cmd.description = c.description;
    if (c.endOptions === false) cmd.endOptions = false;
    if (typeof c.timeoutSeconds === 'number') cmd.timeoutSeconds = Math.min(3600, Math.max(1, Math.round(c.timeoutSeconds)));
    if (c.result && typeof c.result === 'object') {
      const r = c.result as Record<string, unknown>;
      const result: ScriptResultParse = {};
      if (r.json === true) result.json = true;
      for (const k of ['keyPattern', 'urlPattern'] as const) {
        if (typeof r[k] === 'string' && r[k]) {
          try {
            new RegExp(r[k] as string);
          } catch {
            throw new CoreError('invalid_request', `${id}: ${k} isn't a valid regular expression.`);
          }
          result[k] = r[k] as string;
        }
      }
      if (Object.keys(result).length > 0) cmd.result = result;
    }
    return cmd;
  });
}

