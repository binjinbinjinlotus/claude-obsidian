import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { CoreEvent, Job, JobStep, JobStepsPage, Progress, RunnerStep } from '../contracts.js';
import type { FullReadStep } from '../engine/full-read.js';
import { isoDate } from '../store/json.js';
import { clip, noteWords, redact, titleOf, toolWords, type WordsContext } from './words.js';

export { redact, toolWords, noteWords } from './words.js';

/**
 * The live log of each job (spec live-log.md): what a batch is doing, step by step, kept so a
 * past batch's log can be reopened. One JSONL file per job in <state>/steps/<job-id>.jsonl;
 * a changed step is appended again (the last line of an id wins). At most MAX_STEPS steps and
 * MAX_BYTES per job; after that one "not kept" line closes the log.
 *
 * Steps come from three places: the engine's events (job state, progress), the runner's
 * stream (tool calls and messages, via the engine's step sink) and the label pre-step.
 */

export const MAX_STEPS = 2000;
export const MAX_BYTES = 512 * 1024;
const TRUNCATED_ID = 'truncated';

export interface StepLogOptions {
  /** <state>/steps */
  dir: string;
  emit: (e: CoreEvent) => void;
  now?: () => Date;
  getJob: (id: string) => Job | undefined;
}

interface JobLog {
  steps: Map<string, JobStep>;
  bytes: number;
  truncated: boolean;
  seq: number;
  /** A tool_use id → the step it opened. */
  tools: Map<string, string>;
  /** The job as last seen in an event. */
  last?: Job;
  /** review-queue.md: the open queued and updating steps. */
  queued?: string;
  updating?: string;
  /** The review step waiting for the user, if any. */
  review?: string;
  turn: number;
  /** v8: the apply in progress after Approve: its "starting" step (agent runs only) and its apply step. */
  apply?: { start?: string; apply: string; runner: string };
}

export interface StepLog {
  onEvent(e: CoreEvent): void;
  runnerStep(jobId: string, step: RunnerStep): void;
  labelFile(jobId: string, file: string, state: 'running' | 'done' | 'failed', labels?: number): void;
  /** v10: a full-read step (coverage, continuation, detail check, split, stop, archive). */
  fullRead(jobId: string, s: FullReadStep): void;
  list(jobId: string): JobStepsPage;
  /** Remove the logs of jobs that are no longer listed. */
  prune(keep: Iterable<string>): void;
}

function vaultName(p: string): string {
  return path.basename(p) || p;
}

function plural(n: number, noun: string, many = `${noun}s`): string {
  return `${n} ${n === 1 ? noun : many}`;
}

/** "Claude", "Codex", or "The AI" for a runner id. */
export function runnerName(id: string | null | undefined): string {
  if (!id || id === 'claude-code') return 'Claude';
  if (id === 'codex') return 'Codex';
  return 'The AI';
}

/** "22 source pages, 3 concepts, 1 entity added · 6 pages updated", from the approved change's counts. */
export function addedWords(job: Job): string {
  const c = job.approvedChange;
  if (!c) return `${plural(job.changedPaths.length, 'change')} applied`;
  const added = [
    c.sources ? plural(c.sources, 'source page') : '',
    c.concepts ? plural(c.concepts, 'concept') : '',
    c.entities ? plural(c.entities, 'entity', 'entities') : '',
    c.otherPages ? plural(c.otherPages, c.sources || c.concepts || c.entities ? 'other page' : 'page') : '',
  ].filter(Boolean);
  const parts = [added.length ? `${added.join(', ')} added` : '', c.updated ? `${plural(c.updated, 'page')} updated` : ''].filter(Boolean);
  return parts.length ? parts.join(' · ') : `${plural(c.changes, 'change')} applied`;
}

/** Why an approved apply did not add the change, in plain words, with what to do (Review's words). */
export function notAddedWords(job: Job, runner: string): { text: string; hint: string } {
  const since = job.approvedChange?.at ?? '';
  const appTurns = job.turns.filter((t) => t.author === 'app' && t.date >= since).map((t) => t.text);
  const last = appTurns.at(-1) ?? '';
  const planError = job.approval?.planError ?? '';
  if (/vault lock|LOCK_TIMEOUT/.test(last)) {
    return { text: 'Not added: another app was changing your vault', hint: 'Nothing was changed. Approve again to try again.' };
  }
  if (/already used|OPERATION_ID_REUSED/.test(last + planError)) {
    return { text: 'Not added: this change’s operation ID was already used', hint: 'It may already be in your vault. Check the vault log, then reply to have it rebuilt, or reject.' };
  }
  if (/vault changed after|exited 75/.test(last + planError) || job.pendingPart?.reason === 'stale') {
    return {
      text: 'Not added: the vault changed after you reviewed this batch',
      hint: 'Nothing was changed. This batch’s own session rebuilds the change for the vault as it is now; it comes back here for your OK.',
    };
  }
  if (/^Nothing recorded as applied|^Nothing was applied/.test(last)) {
    return {
      text: `Nothing recorded as applied: ${runner} didn’t report the approved change`,
      hint: `Open Show steps to see what happened, or reply to ${runner}. Nothing is listed as added until the vault core confirms it.`,
    };
  }
  if (job.state === 'failed') {
    return { text: `Not added: ${clip(redact(job.error ?? 'the run failed'), 160)}`, hint: 'Nothing is listed as added. Approve again to try again, or reply.' };
  }
  if (job.state === 'cancelled') return { text: 'Cancelled before it was added', hint: 'Approve again to add it.' };
  if (job.state === 'awaitingApproval' && /interrupted|restart/i.test(last)) {
    return { text: 'Not added: Distill stopped while it was adding this batch', hint: 'Approve again; a change that was already applied is not applied twice.' };
  }
  return { text: `Not added: ${runner} came back without applying the change`, hint: 'Nothing was changed. Check what it says, then approve again or reply.' };
}

function duration(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.floor(s / 60);
  return s % 60 ? `${m} min ${s % 60} s` : `${m} min`;
}

export function createStepLog(opts: StepLogOptions): StepLog {
  const now = opts.now ?? (() => new Date());
  const logs = new Map<string, JobLog>();
  /** Jobs first seen after they started (older than this core): their logs stay "not kept". */
  const skip = new Set<string>();

  const fileFor = (jobId: string) => path.join(opts.dir, `${jobId.replace(/[^A-Za-z0-9._-]/g, '_')}.jsonl`);

  function read(jobId: string): { steps: Map<string, JobStep>; bytes: number; kept: boolean } {
    const steps = new Map<string, JobStep>();
    let text = '';
    try {
      text = fs.readFileSync(fileFor(jobId), 'utf8');
    } catch {
      return { steps, bytes: 0, kept: false };
    }
    for (const line of text.split('\n')) {
      if (!line.trim()) continue;
      try {
        const s = JSON.parse(line) as JobStep;
        if (s && typeof s.id === 'string' && typeof s.text === 'string') steps.set(s.id, s);
      } catch {
        /* a torn last line after a crash */
      }
    }
    return { steps, bytes: Buffer.byteLength(text), kept: true };
  }

  function logFor(jobId: string): JobLog {
    let l = logs.get(jobId);
    if (!l) {
      const r = read(jobId);
      l = { steps: r.steps, bytes: r.bytes, truncated: r.steps.has(TRUNCATED_ID), seq: r.steps.size, tools: new Map(), turn: 0 };
      // A job that resumes after a restart continues its numbering past what is kept.
      for (const id of r.steps.keys()) {
        const m = id.match(/^a(\d+)-/);
        if (m) l.turn = Math.max(l.turn, Number(m[1]));
      }
      const open = [...r.steps.values()].reverse().find((s) => s.state === 'review');
      if (open) l.review = open.id;
      // An apply still open when the core stopped: settled by the next job event.
      const applying = [...r.steps.values()].reverse().find((s) => s.phase === 'apply' && s.verb === 'apply' && (s.state === 'running' || s.state === 'waiting'));
      if (applying) {
        const start = applying.id.replace(/^apply-/, 'start-');
        const st = r.steps.get(start);
        l.apply = { apply: applying.id, runner: st?.text.match(/^(.*?) (?:is starting|resumed|couldn’t start)/)?.[1] ?? 'Claude', ...(st ? { start } : {}) };
      }
      logs.set(jobId, l);
    }
    return l;
  }

  function write(jobId: string, l: JobLog, step: JobStep): void {
    const line = JSON.stringify(step) + '\n';
    try {
      fs.mkdirSync(opts.dir, { recursive: true });
      fs.appendFileSync(fileFor(jobId), line, { mode: 0o600 });
      l.bytes += Buffer.byteLength(line);
    } catch {
      /* the log is a convenience; never fail the job over it */
    }
  }

  /** Add or change a step; sends `job.step` and appends it to the job's file. */
  function put(jobId: string, step: JobStep): void {
    const l = logFor(jobId);
    const isNew = !l.steps.has(step.id);
    // Past the cap, new steps are dropped; a kept step can still finish (running → done).
    if (l.truncated && (isNew || l.bytes >= MAX_BYTES * 2)) return;
    if (isNew && (l.steps.size >= MAX_STEPS - 1 || l.bytes >= MAX_BYTES)) {
      l.truncated = true;
      const marker: JobStep = {
        id: TRUNCATED_ID,
        at: isoDate(now()),
        phase: step.phase,
        kind: 'step',
        state: 'done',
        verb: 'truncated',
        text: `Later steps weren’t kept (the log keeps ${MAX_STEPS.toLocaleString('en-US')} steps)`,
      };
      l.steps.set(marker.id, marker);
      write(jobId, l, marker);
      opts.emit({ type: 'job.step', jobId, step: marker });
      return;
    }
    l.steps.set(step.id, step);
    write(jobId, l, step);
    opts.emit({ type: 'job.step', jobId, step: { ...step } });
  }

  function change(jobId: string, id: string, patch: Partial<JobStep>): void {
    const l = logFor(jobId);
    const s = l.steps.get(id);
    if (!s) return;
    const next = { ...s, ...patch };
    if (JSON.stringify(next) === JSON.stringify(s)) return;
    put(jobId, next);
  }

  function nextId(l: JobLog, prefix: string): string {
    l.seq += 1;
    return `${prefix}-${l.seq}`;
  }

  function step(jobId: string, s: Omit<JobStep, 'id' | 'at'> & { id?: string; at?: string }): string {
    const l = logFor(jobId);
    const id = s.id ?? nextId(l, s.phase);
    put(jobId, { ...s, id, at: s.at ?? isoDate(now()) } as JobStep);
    return id;
  }

  /** Close what was still running when a turn ended (a tool whose result never came). */
  function closeRunning(jobId: string, phases: JobStep['phase'][]): void {
    const l = logFor(jobId);
    const end = isoDate(now());
    for (const s of [...l.steps.values()]) {
      if (s.state === 'running' && phases.includes(s.phase) && s.verb !== 'labels' && s.verb !== 'label') {
        change(jobId, s.id, { state: 'done', endedAt: end });
      }
    }
  }

  /** A job whose log is being kept (in memory or on disk). */
  function tracked(jobId: string): boolean {
    return !skip.has(jobId) && (logs.has(jobId) || fs.existsSync(fileFor(jobId)));
  }

  function context(job: Job): WordsContext {
    return { vaultPath: job.vaultPath, jobDir: path.join(job.vaultPath, '.vault-meta', 'worker', job.id), sources: job.files };
  }

  function closeReview(jobId: string, text: string, count?: string): void {
    const l = logFor(jobId);
    if (!l.review) return;
    const end = isoDate(now());
    // Blocked tools and questions were answered along with the review.
    for (const s of [...l.steps.values()]) if (s.state === 'review' && s.id !== l.review) change(jobId, s.id, { state: 'done', endedAt: end });
    change(jobId, l.review, { state: 'done', verb: 'answer', text, endedAt: end, ...(count ? { count } : {}) });
    l.review = undefined;
  }

  function approvedCount(job: Job | undefined): string | undefined {
    const n = job?.approvedChange?.sourcesApproved;
    return n ? plural(n, 'source') : undefined;
  }

  /** v8: the steps after Approve: "<runner> is starting" (agent runs) and "Applying N changes through the vault core". */
  function openApply(jobId: string, agent: boolean, runnerID: string | undefined, message: string): void {
    const l = logFor(jobId);
    if (l.apply) return;
    const job = opts.getJob(jobId) ?? l.last;
    const runner = runnerName(runnerID ?? job?.runnerID);
    const k = (l.seq += 1);
    const n = job?.approvedChange?.changes;
    const what = n !== undefined ? plural(n, 'change') : message.replace(/^Applying\s*/, '') || 'the changes';
    const start = agent
      ? step(jobId, { id: `start-${k}`, phase: 'apply', kind: 'step', state: 'running', verb: 'start', text: `${runner} is starting: resuming this batch’s session` })
      : undefined;
    const apply = step(jobId, { id: `apply-${k}`, phase: 'apply', kind: 'step', state: agent ? 'waiting' : 'running', verb: 'apply', text: `Applying ${what} through the vault core` });
    l.apply = { apply, runner, ...(start ? { start } : {}) };
  }

  /** v8: the job left `running` after Approve: added, or why not (and what to do). */
  function settleApply(job: Job): void {
    const l = logFor(job.id);
    const a = l.apply;
    if (!a) return;
    const end = isoDate(now());
    const startStep = a.start ? l.steps.get(a.start) : undefined;
    const startOpen = startStep?.state === 'running';
    const applied = job.state === 'completed' && !!job.operationID && (!job.approvedChange || job.operationID === job.approvedChange.operationID);
    if (applied) {
      if (startOpen) change(job.id, a.start!, { state: 'done', text: `${a.runner} resumed this batch’s session`, endedAt: end });
      change(job.id, a.apply, { state: 'done', text: 'Applied through the vault core', count: job.operationID!, endedAt: end });
      step(job.id, { id: a.apply.replace(/^apply-/, 'added-'), phase: 'apply', kind: 'step', state: 'done', verb: 'added', text: `Added to ${vaultName(job.vaultPath)}: ${addedWords(job)}`, endedAt: end });
    } else if (job.sessionUnavailable && startOpen) {
      change(job.id, a.start!, {
        state: 'failed',
        text: 'This batch’s AI session isn’t available anymore',
        hint: 'Nothing was changed. Continue starts a new session with this batch and the plan you approved.',
        endedAt: end,
      });
    } else {
      const w = notAddedWords(job, a.runner);
      if (startOpen && job.state === 'failed') {
        change(job.id, a.start!, { state: 'failed', text: `${a.runner} couldn’t start: ${clip(redact(job.error ?? 'the run failed'), 120)}`, hint: w.hint, endedAt: end });
      } else {
        if (startOpen) change(job.id, a.start!, { state: 'done', text: `${a.runner} resumed this batch’s session`, endedAt: end });
        change(job.id, a.apply, { state: 'failed', text: w.text, hint: w.hint, endedAt: end });
      }
    }
    l.apply = undefined;
  }

  /** review-queue.md: queued, updating and each recovery attempt, as live-log steps (`queued-n`, `updating-n`, `recover-n`). */
  function queueSteps(job: Job, prev: Job | undefined): void {
    const end = isoDate(now());
    const l = logFor(job.id);
    const queued = !!job.queuedApply?.planSha256 && job.state === 'awaitingApproval';
    const wasQueued = !!prev?.queuedApply?.planSha256 && prev.state === 'awaitingApproval';
    if (queued && !wasQueued) {
      l.queued = step(job.id, { id: `queued-${l.seq + 1}`, phase: 'apply', kind: 'step', state: 'waiting', verb: 'queued', text: 'Queued · applies after the batch before it' });
    } else if (!queued && wasQueued && l.queued) {
      change(job.id, l.queued, { state: 'done', text: job.state === 'running' ? 'Its turn came: applying' : 'Left the queue', endedAt: end });
      l.queued = undefined;
    }
    if (job.refresh && !prev?.refresh) {
      l.updating = step(job.id, { id: `updating-${job.refresh.attempt}-${l.seq + 1}`, phase: 'apply', kind: 'step', state: 'running', verb: 'updating', text: 'Updating against the latest pages', ...(job.refresh.stalePaths.length ? { detail: job.refresh.stalePaths.join('\n') } : {}) });
    } else if (!job.refresh && prev?.refresh && l.updating) {
      change(job.id, l.updating, { state: 'done', text: 'Rebuilt against the latest pages', endedAt: end });
      l.updating = undefined;
    }
    const attempts = job.recovery?.attempts ?? [];
    const before = prev?.recovery?.attempts ?? [];
    attempts.forEach((a, i) => {
      const id = `recover-${i + 1}`;
      const words =
        a.by === 'rule'
          ? 'Recovering · told Claude to read the files instead'
          : `Recovering · ${a.model ? a.model.charAt(0).toUpperCase() + a.model.slice(1) : 'Recovery model'} · ${a.fix === 'answer_denial' ? 'answering a blocked command' : 'looking at what went wrong'}`;
      const state = a.result === 'running' ? 'running' : a.result === 'fixed' ? 'done' : 'failed';
      const detail = [a.diagnosis, a.error, a.costUSD > 0 ? `$${a.costUSD.toFixed(2)}` : ''].filter(Boolean).join(' · ');
      if (!l.steps.has(id) || i >= before.length) {
        if (!l.steps.has(id)) step(job.id, { id, phase: 'apply', kind: 'step', state, verb: 'recover', text: words, ...(detail ? { detail } : {}) });
      } else if (before[i]?.result !== a.result) {
        change(job.id, id, { state, ...(detail ? { detail } : {}), ...(state !== 'running' ? { endedAt: end } : {}) });
      }
    });
  }

  function onJob(job: Job, deleted: boolean): void {
    if (deleted) {
      logs.delete(job.id);
      try {
        fs.rmSync(fileFor(job.id), { force: true });
      } catch {
        /* already gone */
      }
      return;
    }
    if (skip.has(job.id)) return;
    const known = tracked(job.id);
    if (!known) {
      // Only a job that just started gets a log; an older one stays "not kept".
      const fresh = job.state === 'running' && job.turns.length <= 1;
      if (!fresh) {
        skip.add(job.id);
        return;
      }
    }
    const l = logFor(job.id);
    const prev = l.last;
    l.last = structuredClone(job);
    if (!known) {
      if (job.kind === 'ingest' && job.reread) {
        // v9: a re-read reads files already in inbox/ where they are; nothing moves.
        const n = job.files.length;
        step(job.id, { phase: 'prepare', kind: 'step', state: 'done', verb: 'reread', text: `Re-reading ${plural(n, 'file')} already in your inbox (group ${job.reread.group} of ${job.reread.groups})` });
      } else if (job.kind === 'ingest' && job.files.length + (job.folders?.length ?? 0) > 0) {
        const n = job.files.length;
        step(job.id, { phase: 'prepare', kind: 'step', state: 'done', verb: 'move', text: `Moved ${plural(n, 'file')} from the queue to your inbox` });
      }
      if (job.state !== 'running') return;
    }
    queueSteps(job, prev);
    const was = prev?.state;
    if (job.state === 'running' && was !== 'running') {
      if (was === 'awaitingApproval' || was === 'cancelled' || was === 'failed') {
        const lastTurn = job.turns.at(-1);
        const approved = lastTurn?.author === 'user' && /^Approved /.test(lastTurn.text);
        closeReview(job.id, approved ? 'You approved' : 'You answered', approved ? approvedCount(job) : undefined);
      }
      l.turn += 1;
      l.tools.clear();
    }
    if (job.state !== 'running' && was === 'running') closeRunning(job.id, ['agent', 'check']);
    const hadApply = !!l.apply;
    if (job.state !== 'running' && l.apply) settleApply(job);
    if (job.state === was) {
      actionsStep(job, prev);
      return;
    }
    const end = isoDate(now());
    switch (job.state) {
      case 'awaitingApproval': {
        const a = job.approval;
        const checkId = `check-${l.turn}`;
        if (a?.plan) {
          const n = a.plan.changed_paths.length;
          const ok = a.plan.valid;
          const s = { phase: 'check' as const, kind: 'step' as const, verb: 'check', endedAt: end,
            state: ok ? ('done' as const) : ('failed' as const),
            text: ok ? 'Checked the changes with the vault core' : 'The vault core found a problem in the plan',
            count: plural(n, 'change') };
          if (l.steps.has(checkId)) change(job.id, checkId, s);
          else step(job.id, { id: checkId, ...s });
        } else if (a?.planError) {
          const s = { phase: 'check' as const, kind: 'step' as const, verb: 'check', state: 'failed' as const, endedAt: end,
            text: `Couldn’t check the changes: ${clip(redact(a.planError), 160)}` };
          if (l.steps.has(checkId)) change(job.id, checkId, s);
          else step(job.id, { id: checkId, ...s });
        }
        for (const d of a?.denials ?? []) {
          const what = typeof d.input.command === 'string' ? `“${clip(redact(d.input.command), 60)}”` : d.toolName;
          step(job.id, { phase: 'review', kind: 'step', state: 'review', verb: 'review', text: `Asked to run ${what}: waiting for you`, detail: clip(redact(`${d.toolName}`), 80) });
        }
        if ((a?.questions.length ?? 0) > 0) {
          step(job.id, { phase: 'review', kind: 'step', state: 'review', verb: 'review', text: `Has ${plural(a!.questions.length, 'question')} for you` });
        }
        l.review = step(job.id, { id: `review-${l.turn}`, phase: 'review', kind: 'step', state: 'review', verb: 'review',
          text: a?.plan ? 'Waiting for your review' : 'Waiting for your answer' });
        break;
      }
      case 'completed': {
        if (hadApply) {
          /* settled above: Applied through the vault core, then Added */
        } else {
          closeReview(job.id, 'You answered');
          step(job.id, { phase: 'apply', kind: 'step', state: 'done', verb: 'done',
            text: job.changedPaths.length > 0 ? `Finished: ${plural(job.changedPaths.length, 'change')} applied` : 'Finished: nothing to change' });
        }
        break;
      }
      case 'failed':
        for (const s of [...l.steps.values()]) if (s.state === 'running' || s.state === 'review') change(job.id, s.id, { state: 'done', endedAt: end });
        if (hadApply) break;
        step(job.id, { phase: l.review ? 'review' : 'agent', kind: 'step', state: 'failed', verb: 'error', text: `Failed: ${clip(redact(job.error ?? 'unknown error'), 200)}` });
        break;
      case 'cancelled':
        for (const s of [...l.steps.values()]) if (s.state === 'running' || s.state === 'review') change(job.id, s.id, { state: 'done', endedAt: end });
        if (hadApply) break;
        step(job.id, { phase: 'agent', kind: 'step', state: 'failed', verb: 'error', text: 'Cancelled' });
        break;
      case 'rejected':
        closeReview(job.id, 'You rejected the changes');
        break;
      default:
        break;
    }
    actionsStep(job, prev);
  }

  function actionsStep(job: Job, prev: Job | undefined): void {
    const a = job.actionsFound;
    if (!a || JSON.stringify(a) === JSON.stringify(prev?.actionsFound)) return;
    if (!tracked(job.id)) return;
    const l = logFor(job.id);
    const id = 'actions';
    const s: Partial<JobStep> =
      a.status === 'finding' ? { state: 'running', text: 'Finding actions' }
      : a.status === 'done' ? { state: 'done', text: a.found > 0 ? `Found ${plural(a.found, 'action')} to confirm` : 'Found no actions', endedAt: isoDate(now()) }
      : a.status === 'failed' ? { state: 'failed', text: `Couldn’t find actions${a.error ? `: ${clip(redact(a.error), 120)}` : ''}`, endedAt: isoDate(now()) }
      : { state: 'done', text: 'Didn’t look for actions', endedAt: isoDate(now()) };
    if (l.steps.has(id)) change(job.id, id, s);
    else step(job.id, { id, phase: 'apply', kind: 'step', verb: 'actions', state: 'running', text: '', ...s } as JobStep);
  }

  function onProgress(p: Progress): void {
    if (!tracked(p.key)) return;
    const l = logFor(p.key);
    const at = (p.steps && p.stepIndex !== undefined ? p.steps[p.stepIndex] : undefined) ?? '';
    const labels = l.steps.get('labels');
    if (p.kind === 'batch' && at === 'Suggesting labels' && !p.finished) {
      const count = p.total !== undefined ? `${p.done ?? 0} of ${p.total}` : undefined;
      if (!labels) {
        step(p.key, { id: 'labels', phase: 'prepare', kind: 'step', state: 'running', verb: 'labels', text: 'Suggesting labels', ...(count ? { count } : {}) });
      } else if (labels.state === 'running') {
        change(p.key, 'labels', count ? { count } : {});
      }
      return;
    }
    if (labels?.state === 'running' && (p.kind !== 'batch' || at !== 'Suggesting labels' || p.finished)) {
      const n = p.total ?? [...l.steps.values()].filter((s) => s.parent === 'labels').length;
      change(p.key, 'labels', { state: 'done', text: `Suggested labels for ${plural(n, 'file')}`, count: duration(now().getTime() - Date.parse(labels.at)), endedAt: isoDate(now()) });
    }
    if (p.kind === 'batch' && /^Checking the page changes/.test(p.message) && !p.finished) {
      const id = `check-${l.turn}`;
      if (!l.steps.has(id)) step(p.key, { id, phase: 'check', kind: 'step', state: 'running', verb: 'check', text: 'Checking the changes with the vault core' });
    }
    if (p.kind === 'apply' && !p.finished) {
      closeReview(p.key, 'You approved', approvedCount(opts.getJob(p.key)));
      openApply(p.key, !!p.runnerID, p.runnerID, p.message || '');
    }
    if (p.kind === 'apply' && p.finished && p.error && l.apply) {
      change(p.key, l.apply.apply, { state: 'failed', text: `Couldn’t apply: ${clip(redact(p.error), 160)}`, endedAt: isoDate(now()) });
    }
  }

  return {
    onEvent(e) {
      try {
        if (e.type === 'job') onJob(e.job, e.deleted === true);
        else if (e.type === 'progress') onProgress(e.progress);
      } catch {
        /* the log must never break the core */
      }
    },
    runnerStep(jobId, s) {
      try {
        const job = opts.getJob(jobId);
        if (!job || !tracked(jobId)) return;
        const l = logFor(jobId);
        if (s.kind === 'toolDone') {
          const id = l.tools.get(s.id);
          if (id) change(jobId, id, { state: 'done', endedAt: isoDate(now()) });
          return;
        }
        const w = s.kind === 'tool' ? toolWords(s, context(job)) : noteWords(s.text);
        if (!w) return;
        if (l.apply) {
          const a = l.apply;
          if (a.start && l.steps.get(a.start)?.state === 'running') change(jobId, a.start, { state: 'done', text: `${a.runner} resumed this batch’s session`, endedAt: isoDate(now()) });
          if (s.kind === 'tool' && w.verb === 'apply' && l.steps.get(a.apply)?.state === 'waiting') change(jobId, a.apply, { state: 'running', at: isoDate(now()) });
        }
        const id = nextId(l, `a${l.turn}`);
        if (s.kind === 'tool' && s.id) l.tools.set(s.id, id);
        put(jobId, {
          id,
          at: isoDate(now()),
          phase: 'agent',
          kind: s.kind === 'message' ? 'note' : 'step',
          state: s.kind === 'tool' && s.id ? 'running' : 'done',
          ...w,
        });
      } catch {
        /* the log must never break a run */
      }
    },
    labelFile(jobId, file, state, labels) {
      try {
        if (!tracked(jobId)) return;
        const l = logFor(jobId);
        if (!l.steps.has('labels')) {
          step(jobId, { id: 'labels', phase: 'prepare', kind: 'step', state: 'running', verb: 'labels', text: 'Suggesting labels' });
        }
        const id = `label-${createHash('sha1').update(file).digest('hex').slice(0, 10)}`;
        const s = {
          phase: 'prepare' as const,
          kind: 'step' as const,
          verb: 'label',
          parent: 'labels',
          text: titleOf(file),
          file: titleOf(file),
          state,
          ...(state === 'done' && labels !== undefined ? { count: plural(labels, 'label') } : {}),
          ...(state === 'failed' ? { count: 'couldn’t suggest labels' } : {}),
          ...(state !== 'running' ? { endedAt: isoDate(now()) } : {}),
        };
        if (l.steps.has(id)) change(jobId, id, s);
        else step(jobId, { id, ...s });
      } catch {
        /* never break the label step */
      }
    },
    fullRead(jobId, s) {
      try {
        if (!tracked(jobId)) return;
        const l = logFor(jobId);
        const fields = {
          phase: 'check' as const,
          kind: 'step' as const,
          verb: s.verb,
          state: s.state,
          text: clip(s.text, 200),
          ...(s.detail ? { detail: clip(s.detail, 300) } : {}),
          ...(s.count ? { count: s.count } : {}),
          ...(s.state !== 'running' && s.state !== 'waiting' ? { endedAt: isoDate(now()) } : {}),
        };
        // A step with an id (the detail check's progress) is updated in place.
        const id = s.id ? `fr-${s.id}` : undefined;
        if (id && l.steps.has(id)) change(jobId, id, fields);
        else step(jobId, { ...(id ? { id } : {}), ...fields });
      } catch {
        /* the log must never break a batch */
      }
    },
    list(jobId) {
      const live = skip.has(jobId) ? undefined : logs.get(jobId);
      const r = live ? { steps: live.steps, kept: true } : read(jobId);
      const steps = [...r.steps.values()];
      return { jobId, steps, kept: r.kept && steps.length > 0, ...(r.steps.has(TRUNCATED_ID) ? { truncated: true } : {}) };
    },
    prune(keep) {
      const list = [...keep];
      // An empty list may be a jobs.json set aside as unreadable: never wipe every log then.
      if (list.length === 0) return;
      const ids = new Set(list.map((id) => path.basename(fileFor(id))));
      let names: string[] = [];
      try {
        names = fs.readdirSync(opts.dir);
      } catch {
        return;
      }
      for (const n of names) {
        if (n.endsWith('.jsonl') && !ids.has(n)) {
          try {
            fs.rmSync(path.join(opts.dir, n), { force: true });
          } catch {
            /* try again next start */
          }
        }
      }
    },
  };
}
