/**
 * Self-recovery for batches (review-queue.md, section 3). This file holds the pure parts: the words
 * Distill sends a session whose tool call was blocked, and the plain sentence the owner sees when that
 * didn't help. The engine decides when they run; nothing here touches the vault.
 */
import path from 'node:path';
import type { PermissionDenial, RecoveryState } from '../contracts.js';

/** Auto-answers to blocked commands per batch before the recovery agent (or the owner) takes over. */
export const MAX_DENIAL_ANSWERS = 2;
const MAX_PATHS = 8;
const MAX_COMMAND = 200;

/** "Bash: diff <(…) …": the denied call as one line, cut to `max` characters. */
export function denialLine(d: PermissionDenial, max = MAX_COMMAND): string {
  const input = d.input ?? {};
  const body =
    typeof input.command === 'string'
      ? input.command
      : typeof input.file_path === 'string'
        ? input.file_path
        : typeof input.path === 'string'
          ? input.path
          : JSON.stringify(input);
  const line = `${d.toolName}: ${body.replace(/\s+/g, ' ').trim()}`;
  return line.length > max ? `${line.slice(0, max - 1)}…` : line;
}

/** Absolute paths named in the denied calls, kept only inside the vault or the job directory. */
export function denialPaths(denials: PermissionDenial[], vaultPath: string, jobDir: string): string[] {
  const roots = [path.resolve(vaultPath) + '/', path.resolve(jobDir) + '/'];
  const out: string[] = [];
  for (const d of denials) {
    const texts = Object.values(d.input ?? {}).filter((v): v is string => typeof v === 'string');
    for (const t of texts) {
      for (const m of t.matchAll(/\/[^\s'"`()<>;|&,]+/g)) {
        const p = path.resolve(m[0].replace(/[.:]+$/, ''));
        if (roots.some((r) => p.startsWith(r)) && !out.includes(p)) out.push(p);
        if (out.length >= MAX_PATHS) return out;
      }
    }
  }
  return out;
}

/** What Distill tells the session: the call isn't allowed here; read the files with Read, Grep or Glob. */
export function denialAnswer(denials: PermissionDenial[], o: { vaultPath: string; jobDir: string }): string {
  const lines = denials.slice(0, 3).map((d) => `\`${denialLine(d)}\``);
  const paths = denialPaths(denials, o.vaultPath, o.jobDir);
  const named = paths.length > 0 ? ` For example: ${paths.map((p) => `\`${p}\``).join(', ')}.` : '';
  return [
    `Distill sessions can't run ${lines.join(', ')} (no shell commands or python here).`,
    `Use Read, Grep or Glob to inspect files instead.${named} To compare two files, read both.`,
    "Don't run shell commands or python. Then continue the task and finish with the structured status.",
  ].join(' ');
}

const VERBS: Array<[RegExp, string]> = [
  [/^(diff|cmp|comm)\b/, 'compare'],
  [/^(rm|mv|cp|tee|touch|mkdir|chmod|ln)\b|(^|[^<>])>{1,2}\s*\S/, 'change'],
  [/^(python3?|node|ruby|perl|deno|bun)\b.*\s-(c|e)\b|^(python3?|node)\b/, 'run a script on'],
  [/^(cat|head|tail|less|more|sed|awk|grep|rg|jq|wc|ls|find|stat)\b/, 'read'],
];

/** The friendly name of a path: "the claim ledger", "this batch's copy", a page's title, or its file name. */
export function friendlyPath(p: string, o: { vaultPath: string; jobDir: string }): string {
  const abs = path.resolve(p);
  if (abs.startsWith(path.resolve(o.jobDir) + '/')) return "this batch's copy";
  const rel = path.relative(path.resolve(o.vaultPath), abs);
  const base = path.basename(abs);
  if (/claim-ledger\.json$/.test(base)) return 'the claim ledger';
  if (/source-ledger\.json$/.test(base)) return 'the source ledger';
  if (base === 'hot.md' && rel.startsWith('wiki/')) return 'the hot cache';
  if (base === 'log.md' && rel.startsWith('wiki/')) return 'the vault log';
  if (base === 'index.md' && rel.startsWith('wiki/')) return 'the wiki index';
  if (!rel.startsWith('..') && rel.startsWith('wiki/') && base.endsWith('.md')) return `“${base.slice(0, -3).replace(/[-_]+/g, ' ')}”`;
  return base;
}

function joinNames(names: string[], verb: string): string {
  if (names.length === 0) return 'some files';
  if (verb === 'compare' && names.length === 2) return `${names[0]} with ${names[1]}`;
  if (names.length === 1) return names[0]!;
  return `${names.slice(0, -1).join(', ')} and ${names[names.length - 1]}`;
}

/**
 * The owner's sentence, never the argv: "Claude wanted to compare the claim ledger with this batch's copy.
 * Distill couldn't let it run that, and told it to read the files instead (twice)."
 */
export function denialSummary(denials: PermissionDenial[], o: { vaultPath: string; jobDir: string; answers: number }): string {
  const first = denials[0];
  let verb = 'run a command on';
  if (first) {
    if (first.toolName === 'Bash') {
      const cmd = String(first.input?.command ?? '').trim();
      verb = VERBS.find(([re]) => re.test(cmd))?.[1] ?? 'run a command on';
    } else if (/^(Write|Edit|MultiEdit|NotebookEdit)$/.test(first.toolName)) {
      verb = 'change';
    } else if (/^(WebFetch|WebSearch)$/.test(first.toolName)) {
      verb = 'look up';
    }
  }
  const names: string[] = [];
  for (const p of denialPaths(denials, o.vaultPath, o.jobDir)) {
    const n = friendlyPath(p, o);
    if (!names.includes(n)) names.push(n);
  }
  const what = names.length > 0 ? joinNames(names.slice(0, 3), verb) : verb === 'look up' ? 'something online' : 'some files';
  const told = o.answers === 0 ? '' : `, and told it to read the files instead (${o.answers === 1 ? 'once' : o.answers === 2 ? 'twice' : `${o.answers} times`})`;
  const tool = first && first.toolName !== 'Bash' ? ` (${first.toolName})` : '';
  return `Claude wanted to ${verb} ${what}${tool}. Distill couldn't let it run that${told}.`;
}

/** A fresh recovery state for a signature, or the job's own when it is already recovering from it. */
export function recoveryFor(current: RecoveryState | null | undefined, signature: RecoveryState['signature']): RecoveryState {
  if (current && current.signature === signature && current.state !== 'fixed') return current;
  return { state: 'running', signature, attempts: [], denialAnswers: 0 };
}

// ───────────── the recovery agent (review-queue.md, "The recovery agent") ─────────────

export const RECOVERY_FIXES = [
  'rebuild_in_session', 'reinspect_same_bundle', 'wait_then_retry', 'split_batch', 'discard_stale_part', 'answer_denial', 'new_session', 'give_up',
] as const;

export const RECOVERY_SCHEMA = JSON.stringify({
  type: 'object',
  properties: {
    diagnosis: { type: 'string', description: 'At most 400 characters, plain words for the owner: what is wrong.' },
    fix: { type: 'string', enum: [...RECOVERY_FIXES] },
    reason: { type: 'string', description: 'At most 300 characters: why this fix.' },
    guidance: { type: 'string', description: 'answer_denial or rebuild_in_session: at most 1200 characters Distill sends to the session.' },
  },
  required: ['diagnosis', 'fix', 'reason'],
  additionalProperties: false,
});

export interface RecoveryAnswer {
  diagnosis: string;
  fix: (typeof RECOVERY_FIXES)[number];
  reason: string;
  guidance?: string;
}

export function parseRecoveryAnswer(v: Record<string, unknown>): RecoveryAnswer | string {
  const fix = v.fix;
  if (typeof fix !== 'string' || !(RECOVERY_FIXES as readonly string[]).includes(fix)) return 'The answer named no fix Distill knows.';
  const diagnosis = typeof v.diagnosis === 'string' ? v.diagnosis.trim().slice(0, 400) : '';
  if (!diagnosis) return 'The answer had no diagnosis.';
  const out: RecoveryAnswer = { diagnosis, fix: fix as RecoveryAnswer['fix'], reason: typeof v.reason === 'string' ? v.reason.trim().slice(0, 300) : '' };
  if (typeof v.guidance === 'string' && v.guidance.trim()) out.guidance = v.guidance.trim();
  return out;
}

/** The fixes this problem allows. Anything else is a failed attempt (the core never runs it). */
const ALLOWED: Record<RecoveryState['signature'], ReadonlyArray<RecoveryAnswer['fix']>> = {
  denial: ['answer_denial', 'new_session', 'give_up'],
  'stale-again': ['rebuild_in_session', 'new_session', 'give_up'],
  lock: ['reinspect_same_bundle', 'give_up'],
  'plan-error': ['rebuild_in_session', 'new_session', 'give_up'],
  'not-recorded': ['give_up'],
  'full-read-stop': ['give_up'],
  'session-gone': ['new_session', 'give_up'],
  'runner-failed': ['rebuild_in_session', 'new_session', 'give_up'],
};

/** Null when the core may carry the fix out; otherwise why not. The approval gate is never negotiable. */
export function validateFix(a: RecoveryAnswer, signature: RecoveryState['signature']): string | null {
  if (!ALLOWED[signature].includes(a.fix)) return `${a.fix} isn't a fix for this problem.`;
  if (a.fix === 'answer_denial' || (a.fix === 'rebuild_in_session' && a.guidance)) {
    const g = a.guidance ?? '';
    if (!g) return 'answer_denial needs guidance.';
    if (g.length > 1200) return 'The guidance is longer than 1200 characters.';
    if (/transaction\s+apply|approved-plan-sha256/i.test(g)) return 'The guidance named the vault apply, which only your approval runs.';
    if (/\b(Bash|Edit|Write)\(/.test(g) || /allow(ing)?\s+(the\s+)?(rule|tool|command)/i.test(g)) return 'The guidance asked for a tool rule; only the owner can allow one.';
  }
  return null;
}

/** What the agent sees: the job's facts, capped near 24k characters. It never sees or touches the vault itself. */
export function recoveryFacts(o: {
  signature: RecoveryState['signature'];
  turns: { author: string; text: string }[];
  denials: PermissionDenial[];
  answersSent: string[];
  attempts: RecoveryState['attempts'];
  vaultPath: string;
  jobDir: string;
}): string {
  const turns = o.turns.slice(-12).map((t) => `[${t.author}] ${t.text.slice(0, 1500)}`).join('\n\n');
  const lines = [
    `Problem: ${o.signature}.`,
    'This is a Distill batch: an AI session reads sources and writes a transaction bundle in its job directory; the owner approves it before anything reaches the vault.',
    'The session may use Read, Grep and Glob anywhere in the vault, and Write/Edit only in its job directory. It cannot run shell commands or python.',
    `Vault: ${o.vaultPath}`,
    `Job directory: ${o.jobDir}`,
  ];
  if (o.denials.length > 0) lines.push('Blocked calls in the last turn:', ...o.denials.slice(0, 6).map((d) => `- ${denialLine(d)}`));
  if (o.answersSent.length > 0) lines.push('What Distill already told the session:', ...o.answersSent.slice(-3).map((t) => `- ${t.slice(0, 600)}`));
  if (o.attempts.length > 0) lines.push('Earlier attempts:', ...o.attempts.map((a) => `- ${a.by} ${a.fix}: ${a.result}${a.diagnosis ? ` (${a.diagnosis.slice(0, 200)})` : ''}`));
  lines.push('Conversation (newest last):', turns);
  const text = lines.join('\n');
  return text.length > 24_000 ? text.slice(text.length - 24_000) : text;
}

export function recoveryPrompt(facts: string): string {
  return [
    'You are the recovery step for a stuck Distill batch. Pick exactly one fix from the list and explain it in plain words for the owner.',
    'Fixes: answer_denial (send the session guidance so it can continue with the tools it has), rebuild_in_session (ask the same session to rebuild its plan, with optional guidance), new_session (suggest the owner start a fresh session), give_up (the owner must decide).',
    'Only the fixes allowed for this problem count; any other is a failed attempt.',
    'Never suggest applying anything to the vault, never ask for a tool rule: only the owner approves or allows.',
    '',
    facts,
  ].join('\n');
}
