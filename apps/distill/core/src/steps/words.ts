import path from 'node:path';
import type { JobStep, RunnerStep } from '../contracts.js';

/**
 * Plain words for what an agent did (spec live-log.md, "Plain words"). Tool and target only:
 * a path, a line range, a search pattern, the first line of a command. Never what a file says,
 * what a tool returned or what a draft contains.
 */

export const NOTE_LIMIT = 280;
const DETAIL_LIMIT = 160;
const COMMAND_LIMIT = 120;

/** Things that look like keys or tokens become •••. */
export function redact(text: string): string {
  return text
    .replace(/\b(sk-(?:ant-|proj-)?[A-Za-z0-9_-]{12,}|xox[abprs]-[A-Za-z0-9-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{20,}|glpat-[A-Za-z0-9_-]{16,})/g, '•••')
    .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, '$1 •••')
    .replace(/((?:api[_-]?key|access[_-]?token|auth[_-]?token|token|secret|password|passwd)\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"']+)/gi, '$1•••');
}

export function clip(text: string, max: number): string {
  const t = text.replace(/\s+/g, ' ').trim();
  return t.length <= max ? t : t.slice(0, max - 1).trimEnd() + '…';
}

/** "inbox/Kettle comparison.md" → "Kettle comparison". */
export function titleOf(file: string): string {
  const base = path.basename(file);
  return base.replace(/\.(md|markdown|txt)$/i, '');
}

export interface WordsContext {
  vaultPath: string;
  /** <vault>/.vault-meta/worker/<job-id> */
  jobDir: string;
  /** The batch's own files, vault-relative (inbox/…). */
  sources: string[];
}

type Words = Pick<JobStep, 'verb' | 'text'> & Partial<Pick<JobStep, 'detail' | 'file' | 'count'>>;

function str(v: unknown): string {
  return typeof v === 'string' ? v : '';
}

/** A path as the log shows it: vault-relative inside the vault, else its last two parts. */
export function shownPath(p: string, ctx: WordsContext): string {
  if (!p) return '';
  const abs = path.isAbsolute(p) ? path.normalize(p) : path.normalize(path.join(ctx.vaultPath, p));
  const vault = path.normalize(ctx.vaultPath);
  if (abs === vault) return '.';
  if (abs.startsWith(vault + path.sep)) return path.relative(vault, abs);
  const parts = abs.split(path.sep).filter(Boolean);
  return parts.length <= 2 ? parts.join('/') : `…/${parts.slice(-2).join('/')}`;
}

function where(p: string, ctx: WordsContext): 'source' | 'page' | 'draft' | 'other' {
  const rel = shownPath(p, ctx);
  const jobRel = shownPath(ctx.jobDir, ctx);
  if (rel === jobRel || rel.startsWith(jobRel + '/')) return 'draft';
  if (ctx.sources.includes(rel) || rel.startsWith('inbox/') || rel.startsWith('.raw/')) return 'source';
  if (rel.startsWith('wiki/')) return 'page';
  return 'other';
}

/** `bash -lc "sed -n 1,200p file"` → `sed -n 1,200p file`. */
export function unwrapShell(cmd: string): string {
  const m = cmd.match(/^(?:\/bin\/|\/usr\/bin\/)?(?:ba|z)?sh\s+-l?c\s+(['"])([\s\S]*)\1\s*$/);
  return m?.[2] ?? cmd;
}

const READ_COMMANDS = /^(?:cat|head|tail|nl|less|sed\s+-n\s+\S+)\s+(?:-\S+\s+)*(?:'([^']+)'|"([^"]+)"|(\S+))\s*$/;

function readWords(file: string, ctx: WordsContext, detail: string): Words {
  const shown = shownPath(file, ctx);
  switch (where(file, ctx)) {
    case 'source':
      return { verb: 'read', text: `Read “${titleOf(file)}”`, file: titleOf(file), detail };
    case 'page':
      return { verb: 'readPage', text: `Read your page “${titleOf(file)}”`, file: titleOf(file), detail };
    case 'draft':
      return { verb: 'readRef', text: `Read its draft (${path.basename(file)})`, detail };
    default:
      return { verb: 'readRef', text: `Read ${path.basename(shown) || 'a file'}`, detail };
  }
}

function lines(input: Record<string, unknown>): string {
  const offset = typeof input.offset === 'number' ? input.offset : undefined;
  const limit = typeof input.limit === 'number' ? input.limit : undefined;
  if (offset === undefined && limit === undefined) return '';
  const from = offset ?? 1;
  return limit !== undefined ? ` · lines ${from}–${from + limit - 1}` : ` · from line ${from}`;
}

/** Words for one tool call; undefined for calls the log leaves out (the structured answer itself). */
/** The vault core's own steps, worded by how they ended: running, done, or failed (2026-10-08). */
const TOOL_TENSES = {
  apply: { running: 'Applying the approved changes', done: 'Applied the approved changes', failed: 'Couldn’t apply the approved changes' },
  check: { running: 'Checking the plan with the vault core', done: 'Checked the plan with the vault core', failed: 'Couldn’t check the plan with the vault core' },
} as const;

/**
 * The text a tool step ends with, when its words depend on the result; undefined keeps its own (the other
 * steps never claim a result). A step whose result never came keeps its running words.
 */
export function toolEndText(verb: string, state: 'done' | 'failed'): string | undefined {
  return verb === 'apply' || verb === 'check' ? TOOL_TENSES[verb][state] : undefined;
}

export function toolWords(step: Extract<RunnerStep, { kind: 'tool' }>, ctx: WordsContext): Words | undefined {
  const input = step.input;
  const tool = step.tool;
  const d = (s: string) => clip(redact(s), DETAIL_LIMIT);
  switch (tool) {
    case 'StructuredOutput':
      return undefined;
    case 'Read':
    case 'NotebookRead': {
      const file = str(input.file_path) || str(input.notebook_path) || str(input.path);
      return readWords(file, ctx, d(`${tool} · ${shownPath(file, ctx)}${lines(input)}`));
    }
    case 'Grep': {
      const pattern = str(input.pattern);
      const p = str(input.path);
      return { verb: 'search', text: `Searched for “${clip(redact(pattern), 60)}”`, detail: d(`Grep · “${pattern}”${p ? ` in ${shownPath(p, ctx)}` : ''}`) };
    }
    case 'Glob': {
      const raw = str(input.pattern);
      const pattern = raw.startsWith('/') ? shownPath(raw, ctx) : raw;
      return { verb: 'search', text: `Looked for files (${clip(pattern, 60)})`, detail: d(`Glob · ${pattern}${str(input.path) ? ` in ${shownPath(str(input.path), ctx)}` : ''}`) };
    }
    case 'Bash': {
      const raw = unwrapShell(str(input.command).trim());
      const first = raw.split('\n')[0] ?? '';
      const detail = clip(redact(`Bash · ${first}`), COMMAND_LIMIT + 7);
      // Present tense while it runs: the past tense comes only with a result (toolEndText).
      if (/\btransaction\s+inspect\b/.test(raw)) return { verb: 'check', text: TOOL_TENSES.check.running, detail };
      if (/\btransaction\s+apply\b/.test(raw)) return { verb: 'apply', text: TOOL_TENSES.apply.running, detail };
      const read = first.match(READ_COMMANDS);
      if (read && !/[|;&<>]/.test(first)) {
        const file = read[1] ?? read[2] ?? read[3] ?? '';
        return readWords(file, ctx, detail);
      }
      const program = path.basename((first.match(/^\s*(?:[A-Z_]+=\S+\s+)*(\S+)/)?.[1] ?? 'a command').replace(/['"]/g, ''));
      return { verb: 'command', text: `Ran a command: ${clip(program, 40)}`, detail };
    }
    case 'Write':
    case 'Edit':
    case 'MultiEdit':
    case 'NotebookEdit': {
      const file = str(input.file_path) || str(input.notebook_path);
      const verb = tool === 'Write' ? 'write' : 'edit';
      const n = typeof input.files === 'number' && input.files > 1 ? ` and ${input.files - 1} more` : '';
      const detail = d(`${tool} · ${shownPath(file, ctx)}`);
      if (where(file, ctx) === 'draft') {
        return { verb, text: `${tool === 'Write' ? 'Wrote' : 'Edited'} a draft (${path.basename(file)})${n}`, detail };
      }
      return { verb, text: `${tool === 'Write' ? 'Wrote' : 'Edited'} ${path.basename(file) || 'a file'}${n}`, detail };
    }
    case 'Skill': {
      const name = str(input.skill) || str(input.name);
      const short = name.split(':').pop() ?? name;
      return { verb: 'skill', text: short ? `Started the ${short} instructions` : 'Started its instructions', detail: d(`Skill · ${name}`) };
    }
    case 'TodoWrite':
      return { verb: 'plan', text: 'Updated its plan', detail: 'TodoWrite' };
    case 'Task':
    case 'Agent':
      return { verb: 'agent', text: `Started a helper: ${clip(redact(str(input.description) || 'a sub-task'), 60)}`, detail: d(`${tool} · ${str(input.description)}`) };
    case 'WebFetch': {
      let host = '';
      try {
        host = new URL(str(input.url)).host;
      } catch {
        /* not a URL */
      }
      return { verb: 'web', text: host ? `Looked up ${host}` : 'Looked up a web page', detail: d(`WebFetch · ${host || str(input.url)}`) };
    }
    case 'WebSearch':
      return { verb: 'web', text: `Searched the web for “${clip(redact(str(input.query)), 60)}”`, detail: d(`WebSearch · ${str(input.query)}`) };
    default:
      return { verb: 'tool', text: `Used ${clip(tool, 40)}`, detail: d(tool) };
  }
}

/** The AI's own status message, shortened and with keys hidden. */
export function noteWords(text: string): Words | undefined {
  const t = clip(redact(text), NOTE_LIMIT);
  return t ? { verb: 'note', text: t } : undefined;
}
