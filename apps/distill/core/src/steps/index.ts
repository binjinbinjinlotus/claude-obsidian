import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import type { CoreEvent, Job, JobStep, JobStepsPage, Progress, RunnerStep } from '../contracts.js';
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
  /** The review step waiting for the user, if any. */
  review?: string;
  turn: number;
}

export interface StepLog {
  onEvent(e: CoreEvent): void;
  runnerStep(jobId: string, step: RunnerStep): void;
  labelFile(jobId: string, file: string, state: 'running' | 'done' | 'failed', labels?: number): void;
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

  function closeReview(jobId: string, text: string): void {
    const l = logFor(jobId);
    if (!l.review) return;
    const end = isoDate(now());
    // Blocked tools and questions were answered along with the review.
    for (const s of [...l.steps.values()]) if (s.state === 'review' && s.id !== l.review) change(jobId, s.id, { state: 'done', endedAt: end });
    change(jobId, l.review, { state: 'done', verb: 'answer', text, endedAt: end });
    l.review = undefined;
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
      if (job.kind === 'ingest' && job.files.length + (job.folders?.length ?? 0) > 0) {
        const n = job.files.length;
        step(job.id, { phase: 'prepare', kind: 'step', state: 'done', verb: 'move', text: `Moved ${plural(n, 'file')} from the queue to your inbox` });
      }
      if (job.state !== 'running') return;
    }
    const was = prev?.state;
    if (job.state === 'running' && was !== 'running') {
      if (was === 'awaitingApproval' || was === 'cancelled' || was === 'failed') closeReview(job.id, 'You answered');
      l.turn += 1;
      l.tools.clear();
    }
    if (job.state !== 'running' && was === 'running') closeRunning(job.id, ['agent', 'check']);
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
        const apply = [...l.steps.values()].reverse().find((s) => s.verb === 'apply' && s.state === 'running');
        if (apply) {
          change(job.id, apply.id, { state: 'done', endedAt: end, text: `Applied ${plural(job.changedPaths.length, 'change')} to ${vaultName(job.vaultPath)}`, ...(job.operationID ? { count: job.operationID } : {}) });
        } else {
          closeReview(job.id, 'You answered');
          step(job.id, { phase: 'apply', kind: 'step', state: 'done', verb: 'done',
            text: job.changedPaths.length > 0 ? `Finished: ${plural(job.changedPaths.length, 'change')} applied` : 'Finished: nothing to change' });
        }
        break;
      }
      case 'failed':
        for (const s of [...l.steps.values()]) if (s.state === 'running' || s.state === 'review') change(job.id, s.id, { state: 'done', endedAt: end });
        step(job.id, { phase: l.review ? 'review' : 'agent', kind: 'step', state: 'failed', verb: 'error', text: `Failed: ${clip(redact(job.error ?? 'unknown error'), 200)}` });
        break;
      case 'cancelled':
        for (const s of [...l.steps.values()]) if (s.state === 'running' || s.state === 'review') change(job.id, s.id, { state: 'done', endedAt: end });
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
      closeReview(p.key, 'You approved');
      if (![...l.steps.values()].some((s) => s.verb === 'apply' && s.state === 'running')) {
        step(p.key, { phase: 'apply', kind: 'step', state: 'running', verb: 'apply', text: clip(p.message || 'Applying the changes', 120) });
      }
    }
    if (p.kind === 'apply' && p.finished && p.error) {
      const apply = [...l.steps.values()].reverse().find((s) => s.verb === 'apply' && s.state === 'running');
      if (apply) change(p.key, apply.id, { state: 'failed', text: `Couldn’t apply: ${clip(redact(p.error), 160)}`, endedAt: isoDate(now()) });
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
