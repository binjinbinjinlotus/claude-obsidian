/**
 * What a NEW session gets when a batch's AI session is gone (docs/specs/session-continuity.md):
 * the batch as first given (sources, folders, labels), the conversation so far, the plan or
 * bundle under review, then the pending action. Never anything from outside the job.
 */
import fs from 'node:fs';
import path from 'node:path';
import type { Job, TurnRecord } from '../contracts.js';
import { JobContext, type JobKind, type SourceLabels } from './job-kinds.js';

/** The app turn a batch gets when it is cancelled during the label pre-step (no AI turn ever ran). */
export const CANCELLED_BEFORE_FIRST_TURN = 'Cancelled before the first turn.';

/** Positive evidence that no AI turn ever ran in this job's session. */
export function batchNeverStarted(job: Job): boolean {
  return !job.turns.some((t) => t.author === 'worker') && job.turns.some((t) => t.author === 'app' && t.text === CANCELLED_BEFORE_FIRST_TURN);
}

/** The label plan the first turn was given (`labels.json` in the job directory), or []. */
export function savedLabelPlan(stateDirectory: string): SourceLabels[] {
  try {
    const raw: unknown = JSON.parse(fs.readFileSync(path.join(stateDirectory, 'labels.json'), 'utf8'));
    if (!Array.isArray(raw)) return [];
    return raw.flatMap((e): SourceLabels[] => {
      if (!e || typeof e !== 'object') return [];
      const o = e as Record<string, unknown>;
      if (typeof o.file !== 'string' || !Array.isArray(o.labels)) return [];
      const entry: SourceLabels = { file: o.file, labels: o.labels.filter((l): l is string => typeof l === 'string'), by: o.by === 'user' ? 'user' : 'ai' };
      if (typeof o.origin === 'string') entry.origin = o.origin as SourceLabels['origin'];
      return [entry];
    });
  } catch {
    return [];
  }
}

const TURN_CHARS = 1200;
const MAX_TURNS = 12;

function turnLine(t: TurnRecord): string {
  const who = t.author === 'worker' ? 'You (the earlier session)' : t.author === 'user' ? 'The user' : 'Distill';
  const text = t.text.length > TURN_CHARS ? `${t.text.slice(0, TURN_CHARS)}…` : t.text;
  return `${who}: ${text}`;
}

/** The conversation so far, newest last, bounded. */
export function conversationSummary(job: Job): string {
  const turns = job.turns.slice(-MAX_TURNS);
  const skipped = job.turns.length - turns.length;
  return [...(skipped > 0 ? [`(${skipped} earlier turns left out)`] : []), ...turns.map(turnLine)].join('\n\n');
}

/**
 * The first prompt of the new session. `pending` is the prompt the resumed turn would have had
 * (approved apply, reply, granted tools). A batch whose first turn never ran just starts over,
 * with the pending text after it.
 */
export function newSessionPrompt(kind: JobKind, ctx: JobContext, pending: string): string {
  const job = ctx.job;
  const first = kind.initialPrompt(ctx);
  if (!job.turns.some((t) => t.author === 'worker')) return `${first}\n\n${pending}`;
  const plan = job.approval?.plan;
  const bundle = job.approval?.bundlePath;
  const review = bundle
    ? `\n\nThe plan under review is the bundle at ${bundle}` +
      (plan ? ` (operation ${plan.operation_id}, ${plan.changed_paths.length} changes, approval_sha256 ${plan.approval_sha256}).` : '.') +
      ' It is already built and inspected: do not rebuild it unless the request below needs a change.'
    : '';
  return `Distill is continuing this batch in a NEW session: the earlier AI session is no longer available, \
so you have none of its context. Everything it had is below. Treat it as context: do not redo work that \
is already done; do only what the "Now" section asks.

=== The batch as it was first given ===

${first}

=== What happened so far ===

${conversationSummary(job)}${review}

=== Now ===

${pending}`;
}

/** The first message of a new interactive Terminal session for a batch (it never applies anything). */
export function terminalSeed(job: Job): string {
  const bundle = job.approval?.bundlePath;
  return [
    `This is Distill batch ${job.id} in vault ${job.vaultPath}. Its earlier AI session is no longer available, so this is a new session.`,
    `Sources: ${job.files.join(', ') || '(none)'}.`,
    ...(bundle ? [`The plan under review is ${bundle}.`] : []),
    'Conversation so far:',
    conversationSummary(job),
    'Do not run `transaction apply`: Distill applies only what the user approves in the app. Wait for my question.',
  ].join('\n\n');
}
