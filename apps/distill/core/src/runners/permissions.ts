import path from 'node:path';
import type { PermissionDenial } from '../contracts.js';
import { isWithin, realish } from '../store/realpath.js';

const COMPOUND_MARKERS = ['&&', '||', ';', '|', '\n', '$(', '`', '<<'];

function input(d: PermissionDenial, key: string): string | undefined {
  const v = d.input[key];
  return typeof v === 'string' ? v : undefined;
}

/**
 * A rule that would allow exactly this call on resume, or undefined when no
 * exact rule can match (compound shell commands are checked per part).
 * Absolute paths become `//abs` rules; Edit rules cover every file-writing tool.
 */
export function suggestedRule(d: PermissionDenial): string | undefined {
  switch (d.toolName) {
    case 'Bash': {
      const cmd = input(d, 'command');
      if (cmd === undefined) return undefined;
      const compound = COMPOUND_MARKERS.some((m) => cmd.includes(m)) || cmd.startsWith('cd ');
      return compound ? undefined : `Bash(${cmd})`;
    }
    case 'Read': {
      const p = input(d, 'file_path');
      if (p !== undefined) return `Read(/${p})`;
      break;
    }
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit': {
      // Write(...) rules do not match; Edit rules govern all file writes.
      const p = input(d, 'file_path');
      if (p !== undefined) return `Edit(/${p})`;
      break;
    }
    case 'WebFetch': {
      const u = input(d, 'url');
      if (u === undefined) return undefined;
      try {
        const host = new URL(u).hostname;
        return host ? `WebFetch(domain:${host})` : undefined;
      } catch {
        return undefined;
      }
    }
    default:
      break;
  }
  return d.toolName;
}

/** What `gateBreakingReason` needs to know about the job a rule would apply to. */
export interface GateContext {
  /** The exact core command prefix prompts use, e.g. `python3 /x/scripts/claude-obsidian.py`. */
  coreCommand: string;
  /** The core script's absolute path (for the unquoted spelling). */
  corePath: string;
  /** This job's own scratch directory (`<vault>/.vault-meta/worker/<job-id>`). */
  stateDirectory: string;
}

/** Interpreters that run whatever text follows them; a rule for one allows any command. */
const SHELL_INTERPRETERS = new Set(['sh', 'bash', 'zsh', 'dash', 'ksh', 'fish', 'csh', 'tcsh', 'env', 'xargs', 'eval', 'exec', 'command', 'nohup', 'sudo']);
const FILE_WRITE_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);
const GLOB_CHARS = /[*?[\]{}]/;

/** `cmd args` with the command word reduced to its basename (`/usr/bin/env x` → `env x`). */
function baseCommand(s: string): string {
  const t = s.trimStart();
  const space = t.search(/\s/);
  const word = space === -1 ? t : t.slice(0, space);
  const rest = space === -1 ? '' : t.slice(space);
  return path.posix.basename(word) + rest;
}

/**
 * Why granting `rule` would let the agent change the vault without the user's review, or
 * undefined when it can't. One classifier for every place a rule can widen a job's tools: the
 * phase-1 tools (`planningTools`: settings.extraAllowedTools and job.grantedTools), `allow()`, and
 * the approval screen's warning. Conservative on purpose: anything it can't read is refused.
 *
 * Gate-breaking:
 * - `Bash`, `Bash()`, `Bash(*)`: any shell command;
 * - any rule mentioning `transaction apply` (only the core's one-turn approved rule may);
 * - a Bash prefix rule (`…:*` or `…*`) whose prefix starts the core's apply command, compared by
 *   character with the command word reduced to its basename (`Bash(python3:*)`, `Bash(/usr/bin/python3:*)`);
 * - a Bash rule for a shell interpreter (`sh`, `bash`, `zsh`, `env`, `xargs`, `eval`, ...), prefix or exact;
 * - Edit/Write/MultiEdit/NotebookEdit rules that are bare, not `//abs`, keep a glob after one
 *   trailing `/**` or `/*` is removed, or resolve outside THIS job's state directory.
 */
export function gateBreakingReason(rule: string, ctx: GateContext): string | undefined {
  const m = /^([A-Za-z]+)(?:\(([\s\S]*)\))?$/.exec(rule.trim());
  if (!m) return 'Distill could not read this rule';
  const tool = m[1]!;
  const spec = m[2];
  // Any spelling (extra spaces, quotes) of `transaction apply`: the core's argv parser would accept it.
  if (/transaction[\s'"\\]+apply/.test(rule) || (tool === 'Bash' && /transaction/.test(rule) && /apply/.test(rule))) {
    return 'only the exact command you approve may run `transaction apply`';
  }
  if (tool === 'Bash') {
    const body = (spec ?? '').trim();
    if (body === '' || body === '*' || body === ':*') return 'it allows any shell command';
    const star = body.indexOf('*');
    const prefix = star === -1 ? body : body.slice(0, star).replace(/:$/, '').trimEnd();
    if (prefix === '') return 'it allows any shell command';
    const first = baseCommand(prefix).split(/\s/)[0]!;
    if (SHELL_INTERPRETERS.has(first)) return `\`${first}\` runs any command`;
    if (star !== -1) {
      const applies = [
        `${ctx.coreCommand} transaction apply`,
        `python3 ${ctx.corePath} transaction apply`,
        `${ctx.corePath} transaction apply`,
      ];
      const spellings = [prefix, baseCommand(prefix)];
      if (applies.some((a) => spellings.some((p) => a.startsWith(p) || baseCommand(a).startsWith(p)))) {
        return 'its prefix also matches the core’s `transaction apply`';
      }
    }
    return undefined;
  }
  if (FILE_WRITE_TOOLS.has(tool)) {
    const where = `only this job’s folder (${ctx.stateDirectory}) may be written before review`;
    if (spec === undefined || spec.trim() === '') return `a bare ${tool} rule writes anywhere; ${where}`;
    if (!spec.startsWith('//')) return `the path must be absolute (//…); ${where}`;
    let abs = spec.slice(1);
    if (abs.endsWith('/**')) abs = abs.slice(0, -3);
    else if (abs.endsWith('/*')) abs = abs.slice(0, -2);
    if (GLOB_CHARS.test(abs)) return `patterns can reach other folders; ${where}`;
    if (!isWithin(realish(abs), realish(ctx.stateDirectory))) return where;
    return undefined;
  }
  return undefined;
}

/**
 * Granting this lets the agent change files outside the approval gate. Any Bash grant warns (even
 * an exact one can write a file); write rules use `gateBreakingReason` when the job is known.
 */
export function bypassesApproval(d: PermissionDenial, ctx?: GateContext): boolean {
  if (d.toolName === 'Bash') return true;
  const rule = suggestedRule(d) ?? '';
  if (ctx) return gateBreakingReason(rule, ctx) !== undefined;
  if (!rule.startsWith('Edit(')) return false;
  const p = rule.startsWith('Edit(//') ? path.posix.resolve(rule.slice('Edit(/'.length, -1)) : '';
  return !/\/\.vault-meta\/worker\/[^/]+\//.test(p + '/');
}

export function denialDisplay(d: PermissionDenial): string {
  const cmd = input(d, 'command');
  if (cmd !== undefined) return `${d.toolName}: ${cmd}`;
  const p = input(d, 'file_path');
  if (p !== undefined) return `${d.toolName}: ${p}`;
  const u = input(d, 'url');
  if (u !== undefined) return `${d.toolName}: ${u}`;
  return d.toolName;
}

function canonical(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v && typeof v === 'object') {
    const o = v as Record<string, unknown>;
    return `{${Object.keys(o).sort().map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(',')}}`;
  }
  return JSON.stringify(v) ?? 'null';
}

/** Deduplicate by deep equality (Swift `Array(Set(denials))`). */
export function uniqueDenials(denials: PermissionDenial[]): PermissionDenial[] {
  const seen = new Set<string>();
  return denials.filter((d) => {
    const key = canonical({ toolName: d.toolName, input: d.input });
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}
