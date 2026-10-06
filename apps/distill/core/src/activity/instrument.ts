import fs from 'node:fs';
import path from 'node:path';
import type {
  ActionItem,
  ActionButtonRun,
  ActivityObject,
  ActivityRecovery,
  ActivitySource,
  Collector,
  CollectorRun,
  CoreEvent,
  DistillCore,
  Job,
  QueueEntry,
  Settings,
  TrashItem,
} from '../contracts.js';
import type { EngineExtras } from '../engine/index.js';
import { titleFrom } from '../ask/conversations.js';
import { currentMethod, currentSource, runInMethod } from './context.js';
import type { ActivityLog } from './log.js';
import { isSecretKey } from './redact.js';
import { describeSettingsChanges, settingsPatchSections } from './settings-labels.js';
import type { Trash } from './trash.js';

/**
 * Logging at the core's mutation points. Every DistillCore method is classified below; the
 * mapped type makes a method added to the contract fail typecheck until someone decides
 * whether it logs. Work the core does on its own (batches finishing, collector runs, history
 * retention, queue scans) is logged from the core's event stream.
 */

type Core = DistillCore & EngineExtras;
/** Every method of the core facade except lifecycle, events and the engine-internal setJobActions. */
type Method = Exclude<keyof Core, 'subscribe' | 'start' | 'stop' | 'setJobActions'>;
type Fn = (...args: never[]) => unknown;
type M<K extends Method> = NonNullable<Core[K]>;
type Args<K extends Method> = M<K> extends Fn ? Parameters<M<K>> : never;
type Result<K extends Method> = M<K> extends Fn ? Awaited<ReturnType<M<K>>> : never;

/** What one entry says (source, outcome, id and time are added by the log). */
export interface Described {
  type: string;
  object: ActivityObject;
  summary: string;
  details?: Record<string, unknown>;
  recovery?: ActivityRecovery;
}

interface TrashRequest {
  kind: TrashItem['kind'];
  objectID: string;
  name: string;
  details: TrashItem['details'];
  payload: unknown;
  /** v6: a folder to keep with it (a script collector's files). */
  folder?: string;
  /** A shorter stay than the trash's days. */
  keepHours?: number;
}

interface Spec<K extends Method> {
  /** Read what the change is about to replace or remove (names for deletes, settings before). Failures are ignored. */
  before?: (...args: Args<K>) => unknown;
  /** Keep a copy in Distill's trash before the call (deletes of user content). */
  trash?: (args: Args<K>, before: any) => TrashRequest | null;
  /** The entries for a success. */
  ok: (args: Args<K>, result: Result<K>, before: any, trashed: TrashItem | undefined) => Described | Described[] | null;
  /** The entry for a failure: its type and object, and a sentence starting "Couldn't …". */
  fail: (args: Args<K>, before: any) => Omit<Described, 'details' | 'recovery'>;
}

/**
 * read  – no change to anything
 * event – the change is logged from the event stream (it also happens without a request)
 * quiet – changes nothing the user keeps (Stop on an Ask turn, Extract content)
 */
type Classification<K extends Method> = Spec<K> | 'read' | 'event' | 'quiet';
export type Specs = { [K in Method]: Classification<K> };

export interface InstrumentDeps {
  log: ActivityLog;
  trash: Trash;
  /** <state>/ask: chat files, read before a delete so the chat can go to the trash. */
  askDir: string;
}

/** Chats deleted while Keep Ask history is off stay in the trash this long (the owner, 2026-10-04). */
export const HISTORY_OFF_KEEP_HOURS = 24;

// ───────────── naming helpers ─────────────

const q = (name: string | undefined) => (name ? `“${name}”` : '');
const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

export function jobName(job: Pick<Job, 'kind' | 'files' | 'folders'> | undefined): string {
  if (!job) return 'batch';
  const kind = job.kind === 'labels' ? 'Labels' : job.kind === 'ingest' ? 'Batch' : job.kind;
  const count = job.files.length + (job.folders?.length ?? 0);
  return `${kind} · ${plural(count, 'file')}`;
}

function jobObject(id: string, job: Job | undefined): ActivityObject {
  return { kind: 'batch', id, name: jobName(job) };
}

function collectorObject(id: string, c: Collector | undefined): ActivityObject {
  return { kind: 'collector', id, ...(c?.name ? { name: c.name } : {}) };
}

function actionObject(id: string, a: ActionItem | undefined): ActivityObject {
  return { kind: 'action', id, ...(a?.title ? { name: a.title } : {}) };
}

function scriptFacts(c: Collector | undefined): Record<string, unknown> {
  if (!c) return {};
  if (c.kind === 'folder' && c.folder) return { kind: 'folder', folder: c.folder.source, afterCollect: c.folder.afterCollect, schedule: c.schedule.cron, vault: c.vaultPath };
  const s = c.script;
  if (!s) return { kind: c.kind };
  const facts: Record<string, unknown> = { kind: 'script', interpreter: s.interpreter, schedule: c.schedule.cron, vault: c.vaultPath };
  if ('file' in s.source) {
    // The path stays for Show in Finder; for a script Distill keeps, clients show "N lines · size, written in Distill".
    facts.scriptFile = s.source.file;
    if (s.source.managed) {
      facts.scriptManaged = true;
      // A script Distill keeps: its size and line count, read here and never logged as text.
      try {
        const text = fs.readFileSync(s.source.file, 'utf8');
        facts.scriptBytes = Buffer.byteLength(text);
        facts.scriptLines = lineCount(text);
      } catch {
        // missing: the path says enough
      }
      const m = c.status?.script?.manifest;
      if (m?.exists) facts.manifest = m.name;
    }
  } else {
    // Never the body: it can hold credentials. Its size and line count say what was there.
    facts.scriptBytes = Buffer.byteLength(s.source.inline);
    facts.scriptLines = lineCount(s.source.inline);
  }
  return facts;
}

/** Lines as an editor numbers them: a final newline doesn't start another line. */
export function lineCount(text: string): number {
  if (text === '') return 0;
  const n = text.split('\n').length;
  return text.endsWith('\n') ? n - 1 : n;
}

const kb = (bytes: number) => (bytes < 1024 ? `${bytes} bytes` : `${(bytes / 1024).toFixed(1).replace(/\.0$/, '')} KB`);

/** "61 lines · 2.1 KB, written in Distill", or the user's own file's path. */
function scriptLine(facts: Record<string, unknown>): string {
  const bytes = typeof facts.scriptBytes === 'number' ? facts.scriptBytes : undefined;
  const lines = typeof facts.scriptLines === 'number' ? facts.scriptLines : undefined;
  if (facts.scriptManaged || !facts.scriptFile) {
    const parts = [lines !== undefined ? plural(lines, 'line') : undefined, bytes !== undefined ? kb(bytes) : undefined].filter(Boolean);
    return parts.length ? `${parts.join(' · ')}, written in Distill` : 'written in Distill';
  }
  return String(facts.scriptFile);
}

const isPlain = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Dotted keys whose values differ, one level into objects; values only for short primitives. */
export function settingsChanges(before: Settings | undefined, after: Settings): string[] {
  if (!before) return [];
  const out: string[] = [];
  const show = (v: unknown) => (v === undefined || v === null ? '—' : typeof v === 'string' ? (v.length > 60 ? `${v.slice(0, 59)}…` : v) : String(v));
  const primitive = (v: unknown) => v === null || v === undefined || ['string', 'number', 'boolean'].includes(typeof v);
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  for (const key of [...keys].sort()) {
    const a = (before as unknown as Record<string, unknown>)[key];
    const b = (after as unknown as Record<string, unknown>)[key];
    if (JSON.stringify(a) === JSON.stringify(b)) continue;
    if (isSecretKey(key)) {
      out.push(`${key}: changed`);
    } else if (primitive(a) && primitive(b)) {
      out.push(`${key}: ${show(a)} → ${show(b)}`);
    } else if (isPlain(a ?? {}) && isPlain(b ?? {})) {
      // An absent object (a setting never saved) compares as {}.
      const oa = (a ?? {}) as Record<string, unknown>;
      const ob = (b ?? {}) as Record<string, unknown>;
      const inner = new Set([...Object.keys(oa), ...Object.keys(ob)]);
      for (const k of [...inner].sort()) {
        const x = oa[k];
        const y = ob[k];
        if (JSON.stringify(x) === JSON.stringify(y)) continue;
        out.push(primitive(x) && primitive(y) && !isSecretKey(k) ? `${key}.${k}: ${show(x)} → ${show(y)}` : `${key}.${k}: changed`);
      }
    } else if (Array.isArray(a) || Array.isArray(b)) {
      const n = (v: unknown) => (Array.isArray(v) ? v.length : 0);
      out.push(`${key}: changed (${n(a)} → ${n(b)} items)`);
    } else out.push(`${key}: changed`);
  }
  return out;
}

// ───────────── the classification ─────────────

function buildSpecs(core: Core, deps: InstrumentDeps): Specs {
  const factsBefore = new WeakMap<Collector, Record<string, unknown>>();
  const getJob = (id: string) => core.getJob(id);
  const getAction = (id: string) => core.getAction(id).catch(() => undefined);
  const getCollector = (id: string) => core.getCollector(id).catch(() => undefined);

  const jobVerb = (type: string, verb: string, fail: string): Spec<'approve'> => ({
    before: (id) => getJob(id),
    ok: ([id], _r, job: Job | undefined) => ({ type, object: jobObject(id, job), summary: `${verb} ${jobName(job)}` }),
    fail: ([id], job: Job | undefined) => ({ type, object: jobObject(id, job), summary: `Couldn't ${fail} ${jobName(job)}` }),
  });

  const actionVerb = <K extends 'draftAction' | 'improveAction' | 'undoImprove' | 'removeAction' | 'restoreAction'>(
    type: string,
    verb: string,
    fail: string,
  ): Spec<K> => ({
    before: ((id: string) => getAction(id)) as Spec<K>['before'],
    ok: (args, result) => {
      const item = result as ActionItem;
      return { type, object: actionObject(item.id, item), summary: `${verb} ${q(item.title)}`, details: { actionType: item.type, status: item.status } };
    },
    fail: (args, before: ActionItem | undefined) => ({ type, object: actionObject(String(args[0]), before), summary: `Couldn't ${fail} ${q(before?.title)}`.trim() }),
  });

  return {
    // ── reads ──
    status: 'read',
    getSettings: 'read',
    listQueue: 'read',
    listJobs: 'read',
    getJob: 'read',
    jobResumeCommand: 'read',
    listJobSteps: 'read',
    previewInboxCleanup: 'read',
    listHeld: 'read',
    searchPages: 'read',
    listLabels: 'read',
    labelReview: 'read',
    listConversations: 'read', // its retention sweep is logged from `conversation` events
    getConversation: 'read',
    listProgress: 'read',
    listRunners: 'read',
    listActionTypes: 'read',
    listActions: 'read', // its History sweep is logged from `action` events
    getAction: 'read',
    summarizeAction: 'read', // fills an older item's summary on first open; routine, not the owner's change
    previewActionButton: 'read',
    previewButtonDraft: 'read',
    stopActionButtonRun: 'read', // the run's end is on the item
    // action-buttons.md: who ran which button; never the argv values (they can hold message text).
    runActionButton: {
      before: (id: string) => getAction(id),
      ok: ([id], r: { run: ActionButtonRun; item: ActionItem }) => ({
        type: 'action.button_run',
        object: actionObject(String(id), r.item),
        summary: `Ran ${r.run.label} for ${q(r.item.title)}`,
        details: { buttonId: r.run.buttonId, runId: r.run.runId, actionType: r.item.type },
      }),
      fail: ([id, buttonId], before: ActionItem | undefined) => ({
        type: 'action.button_run',
        object: actionObject(String(id), before),
        summary: `Couldn't run a button for ${q(before?.title)}`.trim(),
        details: { buttonId: String(buttonId) },
      }),
    },
    listConnections: 'read',
    signInURL: 'read',
    listCollectors: 'read',
    getCollector: 'read',
    listCollectorRuns: 'read',
    listCollected: 'read',
    checkSchedule: 'read',
    getCollectorScript: 'read',
    getCollectorInstall: 'read',

    // ── logged from events ──
    processQueue: 'event', // batch.started (also scheduled batches)
    rereadSources: 'event', // batch.started with details.reread, once per group as it starts
    retryHeld: 'event', // batch.started with details.reread (reason retry)
    scanQueue: 'event', // queue.scanned (also the window scan and the periodic check)
    runCollector: 'event', // collector.run when it finishes (also scheduled runs)
    testCollector: 'event', // collector.test_run when it finishes
    installCollectorPackages: 'event', // collector.install when it finishes (also installs on Allow and before a run)
    findJobActions: 'event', // action.found when the job's actionsFound settles
    jobActions: 'read',

    // ── nothing kept changes ──
    cancelAsk: 'quiet',
    extractImageText: 'quiet',

    // ── settings and secrets ──
    updateSettings: {
      before: () => structuredClone(core.getSettings()),
      ok: (_args, after, before: Settings | undefined) => {
        const changes = settingsChanges(before, after);
        if (changes.length === 0) return null;
        // In Settings' words ("Ask history (Keep history off)"); `changes` keeps the raw keys for scripts and older clients.
        const readable = describeSettingsChanges(before, after);
        const keys = [...new Set(changes.map((c) => c.split(/[.:]/)[0]!))];
        return {
          type: 'settings.changed',
          object: { kind: 'settings', name: 'Settings' },
          summary: `Changed settings: ${readable.summary || keys.join(', ')}`,
          details: { changes, ...(readable.lines.length ? { readableChanges: readable.lines } : {}) },
        };
      },
      fail: ([patch]) => ({
        type: 'settings.changed',
        object: { kind: 'settings', name: 'Settings' },
        summary: `Couldn't change settings: ${settingsPatchSections(patch as Record<string, unknown> | undefined)}`,
      }),
    },
    setRunnerSecret: {
      ok: ([runnerID, name, value]) => ({
        type: value === null ? 'runner.secret_cleared' : 'runner.secret_saved',
        object: { kind: 'runner', id: runnerID, name: runnerID },
        // The value is never read here; the name says which key (e.g. "apiKey").
        summary: value === null ? `Removed the ${runnerID} key from the Keychain` : `Saved a ${runnerID} key in the Keychain`,
        details: { keyName: name },
      }),
      fail: ([runnerID, , value]) => ({
        type: value === null ? 'runner.secret_cleared' : 'runner.secret_saved',
        object: { kind: 'runner', id: runnerID, name: runnerID },
        summary: `Couldn't ${value === null ? 'remove' : 'save'} the ${runnerID} key`,
      }),
    },

    // ── queue and notes ──
    addQueueFiles: {
      ok: ([paths], entries) => ({
        type: 'queue.added',
        object: { kind: 'queue', name: paths.length === 1 ? path.basename(paths[0]!) : plural(paths.length, 'file') },
        summary: `Added ${paths.length === 1 ? q(path.basename(paths[0]!)) : plural(paths.length, 'file')} to the queue`,
        details: { files: paths.map((p) => path.basename(p)), added: entries.length },
      }),
      fail: ([paths]) => ({ type: 'queue.added', object: { kind: 'queue', name: plural(paths.length, 'file') }, summary: `Couldn't add ${plural(paths.length, 'file')} to the queue` }),
    },
    removeQueueEntry: {
      before: (file) => core.listQueue().find((e) => e.path === file || path.resolve(e.path) === path.resolve(file)),
      ok: ([file], _r, entry: QueueEntry | undefined) => {
        const name = entry?.name ?? path.basename(file);
        return {
          type: 'queue.removed',
          object: { kind: 'queue', id: file, name },
          summary: `Removed ${q(name)} from the queue (moved to the Trash)`,
          details: {
            path: file,
            itemKind: entry?.kind ?? 'file',
            size: entry?.size ?? null,
            ...(entry?.fileCount !== undefined ? { fileCount: entry.fileCount } : {}),
            ...(entry?.members?.length ? { members: entry.members.map((m) => path.basename(m)) } : {}),
          },
          // The engine moves it into the macOS Trash (a numbered name when one is taken).
          recovery: { kind: 'macosTrash', path: `~/.Trash/${name}` },
        };
      },
      fail: ([file]) => ({ type: 'queue.removed', object: { kind: 'queue', id: file, name: path.basename(file) }, summary: `Couldn't remove ${q(path.basename(file))} from the queue` }),
    },
    addNote: {
      ok: ([req], result) => ({
        type: 'note.added',
        object: { kind: 'note', id: result.requestID, name: req.title },
        summary: `Added the note ${q(req.title)} to the queue`,
        details: {
          notePath: result.notePath,
          files: result.queued.length,
          images: req.images?.length ?? 0,
          labels: req.labels ?? [],
          ...(req.source ? { noteSource: req.source } : {}),
        },
      }),
      fail: ([req]) => ({ type: 'note.added', object: { kind: 'note', name: req.title }, summary: `Couldn't add the note ${q(req.title)}` }),
    },
    labelNote: {
      ok: ([requestID, labels], result) => ({
        type: 'note.labeled',
        object: { kind: 'note', id: requestID, name: path.basename(result.notePath) },
        summary: `Labeled ${q(path.basename(result.notePath))}: ${labels.map((l) => `#${l}`).join(' ') || 'no labels'}`,
        details: { labels },
      }),
      fail: ([requestID]) => ({ type: 'note.labeled', object: { kind: 'note', id: requestID }, summary: `Couldn't label the note` }),
    },
    labelQueueItem: {
      ok: ([file, labels]) => ({
        type: 'queue.labeled',
        object: { kind: 'queue', id: file, name: path.basename(file) },
        summary: `Labeled ${q(path.basename(file))} in the queue: ${labels.map((l) => `#${l}`).join(' ') || 'no labels'}`,
        details: { labels },
      }),
      fail: ([file]) => ({ type: 'queue.labeled', object: { kind: 'queue', id: file, name: path.basename(file) }, summary: `Couldn't label ${q(path.basename(file))}` }),
    },
    retryQueueLabels: 'read',
    skipQueueLabels: {
      ok: ([file]) => ({ type: 'queue.labeled', object: { kind: 'queue', id: file, name: path.basename(file) }, summary: `Sent ${q(path.basename(file))} to the next batch without labels` }),
      fail: ([file]) => ({ type: 'queue.labeled', object: { kind: 'queue', id: file, name: path.basename(file) }, summary: `Couldn't send ${q(path.basename(file))} without labels` }),
    },
    removeReviewSource: {
      before: (id) => getJob(id),
      ok: ([id, page, removed], _r, job: Job | undefined) => ({
        type: removed ? 'batch.source_removed' : 'batch.source_restored',
        object: jobObject(id, job),
        summary: `${removed ? 'Removed' : 'Put back'} ${q(path.posix.basename(page, '.md'))} ${removed ? 'from' : 'in'} ${jobName(job)}`,
        details: { page },
      }),
      fail: ([id, , removed], job: Job | undefined) => ({
        type: removed ? 'batch.source_removed' : 'batch.source_restored',
        object: jobObject(id, job),
        summary: `Couldn't change a source in ${jobName(job)}`,
      }),
    },
    editReviewLabels: {
      before: (id) => getJob(id),
      ok: ([id, edits], _r, job: Job | undefined) => ({
        type: 'batch.labels_edited',
        object: jobObject(id, job),
        summary: `Changed labels on ${plural(edits.length, 'source page')} in ${jobName(job)}`,
        details: { pages: edits.map((e) => e.page), labels: edits.map((e) => e.labels) },
      }),
      fail: ([id], job: Job | undefined) => ({ type: 'batch.labels_edited', object: jobObject(id, job), summary: `Couldn't change labels in ${jobName(job)}` }),
    },

    // ── batches (jobs) ──
    approve: jobVerb('batch.approved', 'Approved', 'approve'),
    unqueue: {
      before: (id) => getJob(id),
      ok: ([id], _r, job: Job | undefined) => ({ type: 'batch.unqueued', object: jobObject(id, job), summary: `Took ${jobName(job)} out of the apply queue` }),
      fail: ([id], job: Job | undefined) => ({ type: 'batch.unqueued', object: jobObject(id, job), summary: `Couldn't take ${jobName(job)} out of the apply queue` }),
    },
    reply: {
      before: (id) => getJob(id),
      // The reply text is not logged (it can be anything); its length says it was there.
      ok: ([id, text], _r, job: Job | undefined) => ({ type: 'batch.replied', object: jobObject(id, job), summary: `Replied to ${jobName(job)}`, details: { characters: text.length } }),
      fail: ([id], job: Job | undefined) => ({ type: 'batch.replied', object: jobObject(id, job), summary: `Couldn't reply to ${jobName(job)}` }),
    },
    allow: {
      before: (id) => getJob(id),
      ok: ([id, rules], _r, job: Job | undefined) => ({ type: 'batch.allowed', object: jobObject(id, job), summary: `Allowed ${plural(rules.length, 'tool rule')} for ${jobName(job)}`, details: { rules } }),
      fail: ([id], job: Job | undefined) => ({ type: 'batch.allowed', object: jobObject(id, job), summary: `Couldn't allow tools for ${jobName(job)}` }),
    },
    reject: {
      before: (id) => getJob(id),
      // A rebuilt part discarded alone leaves the batch in Review: not a rejection of the batch.
      ok: ([id], _r, job: Job | undefined) =>
        getJob(id)?.state === 'awaitingApproval'
          ? { type: 'batch.part_discarded', object: jobObject(id, job), summary: `Discarded a rebuilt part of ${jobName(job)}` }
          : { type: 'batch.rejected', object: jobObject(id, job), summary: `Rejected ${jobName(job)}` },
      fail: ([id], job: Job | undefined) => ({ type: 'batch.rejected', object: jobObject(id, job), summary: `Couldn't reject ${jobName(job)}` }),
    },
    cancel: jobVerb('batch.cancelled', 'Cancelled', 'cancel'),
    finishReview: 'quiet', // takes an approved batch out of Review; the batch and the vault are unchanged
    cleanUpInbox: {
      ok: ([req], r) => {
        const files = r.moved.reduce((n, m) => n + m.fileCount, 0);
        const stayed = r.stayed.length + r.failed.length;
        return {
          type: 'queue.inbox_cleaned',
          object: { kind: 'queue', id: req.jobId ?? 'inbox', name: req.jobId ? 'inbox/ (one batch)' : 'inbox/' },
          // v10 (full reads): only originals archived in .raw/captured/ are cleared from inbox/.
          summary: r.moved.length === 0
            ? `Cleared inbox: nothing cleared${stayed ? `, ${plural(stayed, 'item')} stayed` : ''}`
            : `Cleared ${plural(files, 'file')} from inbox · originals archived${stayed ? ` · ${stayed} stayed` : ''}`,
          details: {
            moved: r.moved.map((m) => m.path),
            stayed: [...r.stayed.map((x) => `${x.path} (${x.reason})`), ...r.failed.map((f) => `${f.path} (couldn't move)`)],
            files,
            method: r.method,
            ...(req.jobId ? { jobId: req.jobId } : {}),
          },
          recovery: { kind: 'macosTrash', path: '~/.Trash' },
        };
      },
      fail: ([req]) => ({ type: 'queue.inbox_cleaned', object: { kind: 'queue', id: req?.jobId ?? 'inbox', name: 'inbox/' }, summary: "Couldn't clear inbox" }),
    },
    deleteJob: {
      before: (id) => (getJob(id) ? structuredClone(getJob(id)) : undefined),
      ok: ([id], _r, job: Job | undefined) => ({
        type: 'batch.deleted',
        object: jobObject(id, job),
        summary: `Deleted ${jobName(job)} from the list`,
        details: {
          state: job?.state ?? null,
          createdAt: job?.createdAt ?? null,
          files: job?.files ?? [],
          changedPaths: job?.changedPaths.length ?? 0,
          operationID: job?.operationID ?? null,
        },
        recovery: { kind: 'none', reason: 'Only the record of the batch is gone; pages it applied stay in the vault (wiki/log.md lists the operation).' },
      }),
      fail: ([id], job: Job | undefined) => ({ type: 'batch.deleted', object: jobObject(id, job), summary: `Couldn't delete ${jobName(job)}` }),
    },
    suggestLabelsForPages: {
      ok: ([paths], job) => ({ type: 'labels.suggest_started', object: jobObject(job.id, job), summary: `Started label suggestions for ${plural(paths.length, 'page')}`, details: { pages: paths } }),
      fail: ([paths]) => ({ type: 'labels.suggest_started', object: { kind: 'labels' }, summary: `Couldn't start label suggestions for ${plural(paths.length, 'page')}` }),
    },
    confirmLabels: {
      ok: ([items], job) => ({
        type: 'labels.confirm_started',
        object: jobObject(job.id, job),
        summary: `Confirmed labels for ${plural(items.length, 'page')} (waiting for approval)`,
        details: { pages: items.map((i) => i.path) },
      }),
      fail: ([items]) => ({ type: 'labels.confirm_started', object: { kind: 'labels' }, summary: `Couldn't confirm labels for ${plural(items.length, 'page')}` }),
    },

    // ── Ask chats ──
    ask: {
      before: (req) => (req.conversationID ? core.getConversation(req.conversationID).catch(() => undefined) : undefined),
      ok: ([req], result, before: { title?: string; turns?: unknown[] } | undefined) =>
        req.conversationID
          ? {
              type: 'chat.updated',
              object: { kind: 'chat', id: result.conversationID, name: before?.title ?? titleFrom(req.question) },
              summary: `Asked a follow-up in ${q(before?.title ?? titleFrom(req.question))}`,
            }
          : {
              type: 'chat.created',
              object: { kind: 'chat', id: result.conversationID, name: titleFrom(req.question) },
              summary: `Started the chat ${q(titleFrom(req.question))}`,
            },
      fail: ([req], before: { title?: string } | undefined) => ({
        type: req.conversationID ? 'chat.updated' : 'chat.created',
        object: { kind: 'chat', ...(req.conversationID ? { id: req.conversationID } : {}), name: before?.title ?? titleFrom(req.question) },
        summary: `Couldn't answer ${q(before?.title ?? titleFrom(req.question))}`,
      }),
    },
    setConversationPinned: {
      ok: ([id, pinned], summary) => ({ type: pinned ? 'chat.pinned' : 'chat.unpinned', object: { kind: 'chat', id, name: summary.title }, summary: `${pinned ? 'Pinned' : 'Unpinned'} the chat ${q(summary.title)}` }),
      fail: ([id, pinned]) => ({ type: pinned ? 'chat.pinned' : 'chat.unpinned', object: { kind: 'chat', id }, summary: `Couldn't ${pinned ? 'pin' : 'unpin'} the chat` }),
    },
    deleteConversation: {
      before: (id) => {
        const file = path.join(deps.askDir, `${id}.json`);
        const raw = fs.readFileSync(file, 'utf8');
        const record = JSON.parse(raw) as { title?: string; history?: unknown[]; turns?: number; createdAt?: string; updatedAt?: string; pinned?: boolean };
        const keepHistory = core.getSettings().askPreferences?.keepHistory;
        return { record, bytes: Buffer.byteLength(raw), historyOff: keepHistory === false };
      },
      trash: ([id], before: { record: { title?: string; history?: unknown[]; turns?: number }; historyOff: boolean } | undefined) => {
        // With Keep history off the app deletes each chat when it's closed. The owner (2026-10-04):
        // those go to the trash too, but only for 24 hours.
        if (!before) return null;
        return {
          kind: 'chat',
          objectID: id,
          name: before.record.title || 'Earlier conversation',
          details: { turnCount: before.record.history?.length ?? before.record.turns ?? 0, ...(before.historyOff ? { reason: 'keep-history-off' } : {}) },
          payload: before.record,
          ...(before.historyOff ? { keepHours: HISTORY_OFF_KEEP_HOURS } : {}),
        };
      },
      ok: ([id], _r, before: { record: { title?: string; history?: unknown[]; turns?: number; createdAt?: string; updatedAt?: string }; bytes: number; historyOff: boolean } | undefined, trashed) => {
        const name = before?.record.title || 'Earlier conversation';
        return {
          type: 'chat.deleted',
          object: { kind: 'chat', id, name },
          summary: `Deleted the chat ${q(name)}`,
          details: {
            turnCount: before?.record.history?.length ?? before?.record.turns ?? null,
            sizeBytes: before?.bytes ?? null,
            createdAt: before?.record.createdAt ?? null,
            lastMessageAt: before?.record.updatedAt ?? null,
            reason: before?.historyOff ? 'keep-history-off' : 'deleted',
          },
          recovery: trashed
            ? { kind: 'trash', trashId: trashed.id, expiresAt: trashed.expiresAt }
            : { kind: 'none', reason: 'No copy was kept.' },
        };
      },
      fail: ([id], before: { record: { title?: string } } | undefined) => ({ type: 'chat.deleted', object: { kind: 'chat', id, name: before?.record.title }, summary: `Couldn't delete the chat ${q(before?.record.title)}`.trim() }),
    },

    // ── actions ──
    createAction: {
      ok: ([input], item) => ({
        type: 'action.created',
        object: actionObject(item.id, item),
        summary: `Added ${q(item.title)}${item.type !== 'todo' ? ` (${item.type})` : ''}`,
        details: { actionType: item.type, status: item.status, from: input.source?.kind ?? 'manual' },
      }),
      fail: ([input]) => ({ type: 'action.created', object: { kind: 'action', name: input.title }, summary: `Couldn't add ${q(input.title)}` }),
    },
    updateAction: {
      ok: ([, patch], item) => ({
        type: 'action.updated',
        object: actionObject(item.id, item),
        summary: `Edited ${q(item.title)}`,
        // Which parts changed, not what they say.
        details: { changed: [...Object.keys(patch).filter((k) => k !== 'fields'), ...Object.keys(patch.fields ?? {}).map((k) => `fields.${k}`)] },
      }),
      fail: ([id]) => ({ type: 'action.updated', object: { kind: 'action', id }, summary: `Couldn't save the action` }),
    },
    confirmActions: {
      ok: (_args, items) => items.map((item) => ({ type: 'action.confirmed', object: actionObject(item.id, item), summary: `Confirmed ${q(item.title)}`, details: { actionType: item.type, status: item.status } })),
      fail: ([ids]) => ({ type: 'action.confirmed', object: { kind: 'action', name: plural(ids.length, 'action') }, summary: `Couldn't confirm ${plural(ids.length, 'action')}` }),
    },
    dismissActions: {
      before: async (ids) => Promise.all(ids.map((id) => getAction(id))),
      ok: ([ids], _r, before: (ActionItem | undefined)[] | undefined) =>
        ids.map((id, i) => ({ type: 'action.dismissed', object: actionObject(id, before?.[i]), summary: `Dismissed ${q(before?.[i]?.title)}`.trim() })),
      fail: ([ids]) => ({ type: 'action.dismissed', object: { kind: 'action', name: plural(ids.length, 'action') }, summary: `Couldn't dismiss ${plural(ids.length, 'action')}` }),
    },
    draftAction: actionVerb('action.drafted', 'Wrote the draft for', 'write the draft for'),
    improveAction: actionVerb('action.improved', 'Improved the draft for', 'improve the draft for'),
    undoImprove: actionVerb('action.improve_undone', 'Undid the improvement to', 'undo the improvement to'),
    performAction: {
      ok: ([, handler], item) => ({ type: 'action.performed', object: actionObject(item.id, item), summary: `${handler}: ${q(item.title)}`, details: { handler, actionType: item.type, status: item.status, ...(item.external?.key ? { externalKey: item.external.key } : {}) } }),
      fail: ([id, handler]) => ({ type: 'action.performed', object: { kind: 'action', id }, summary: `Couldn't run ${handler}` }),
    },
    sendActionTo: {
      ok: ([id, type], item) => ({ type: 'action.sent', object: actionObject(item.id, item), summary: `Sent ${q(item.title)} to ${type}`, details: { from: id, to: type } }),
      fail: ([id, type]) => ({ type: 'action.sent', object: { kind: 'action', id }, summary: `Couldn't send the action to ${type}` }),
    },
    removeAction: actionVerb('action.removed', 'Removed', 'remove'),
    restoreAction: actionVerb('action.restored', 'Restored', 'restore'),
    deleteActionForever: {
      before: (id) => getAction(id),
      ok: ([id], _r, before: ActionItem | undefined) => ({
        type: 'action.deleted',
        object: actionObject(id, before),
        summary: `Deleted ${q(before?.title)} from History`.replace('  ', ' '),
        details: { actionType: before?.type ?? null, status: before?.status ?? null, createdAt: before?.createdAt ?? null },
        recovery: { kind: 'none', reason: 'Deleted from History; actions are not kept in the trash.' },
      }),
      fail: ([id], before: ActionItem | undefined) => ({ type: 'action.deleted', object: actionObject(id, before), summary: `Couldn't delete ${q(before?.title)}`.trim() }),
    },
    detectAskActions: {
      ok: ([conversationID], items) =>
        items.length === 0
          ? null
          : { type: 'action.found', object: { kind: 'chat', id: conversationID }, summary: `Found ${plural(items.length, 'action')} in an Ask answer`, details: { actions: items.map((i) => i.title) } },
      fail: ([conversationID]) => ({ type: 'action.found', object: { kind: 'chat', id: conversationID }, summary: `Couldn't find actions in the answer` }),
    },

    // ── connections ──
    connect: {
      // The token and email are never logged.
      ok: ([id, req], info) => ({ type: 'connection.connected', object: { kind: 'connection', id, name: info.label }, summary: `Connected ${info.label}${info.site ? ` (${info.site})` : ''}`, details: { site: req.site ?? info.site ?? null, status: info.status } }),
      fail: ([id, req]) => ({ type: 'connection.connected', object: { kind: 'connection', id, name: id }, summary: `Couldn't connect ${id}${req.site ? ` (${req.site})` : ''}` }),
    },
    disconnect: {
      ok: ([id], info) => ({ type: 'connection.disconnected', object: { kind: 'connection', id, name: info.label }, summary: `Disconnected ${info.label}` }),
      fail: ([id]) => ({ type: 'connection.disconnected', object: { kind: 'connection', id, name: id }, summary: `Couldn't disconnect ${id}` }),
    },

    // ── collectors ──
    createCollector: {
      ok: (_args, c) => ({ type: 'collector.created', object: collectorObject(c.id, c), summary: `Added the ${c.kind} collector ${q(c.name)}${c.kind === 'script' ? ' (off until you allow it)' : ''}`, details: scriptFacts(c) }),
      fail: ([input]) => ({ type: 'collector.created', object: { kind: 'collector', name: input.name ?? input.kind }, summary: `Couldn't add the ${input.kind} collector ${q(input.name)}`.trim() }),
    },
    updateCollector: {
      before: (id) => getCollector(id),
      ok: ([, patch], c, before: Collector | undefined) => {
        const keys = Object.keys(patch);
        if (keys.length === 1 && patch.enabled !== undefined) {
          return { type: patch.enabled ? 'collector.enabled' : 'collector.disabled', object: collectorObject(c.id, c), summary: `Turned ${patch.enabled ? 'on' : 'off'} ${q(c.name)}` };
        }
        const changed = [...keys.filter((k) => k !== 'script' && k !== 'folder'), ...Object.keys(patch.folder ?? {}).map((k) => `folder.${k}`), ...Object.keys(patch.script ?? {}).map((k) => `script.${k}`)];
        const details: Record<string, unknown> = { changed };
        if (before?.name !== c.name) details.renamedFrom = before?.name ?? null;
        if (patch.script?.source) {
          const was = scriptFacts(before);
          const now = scriptFacts(c);
          details.script = `${scriptLine(was)} → ${scriptLine(now)}`;
        }
        if (patch.enabled !== undefined) details.enabled = patch.enabled;
        return { type: 'collector.updated', object: collectorObject(c.id, c), summary: `Changed ${q(c.name)}: ${changed.join(', ')}`, details };
      },
      fail: ([id, patch], before: Collector | undefined) => ({
        type: Object.keys(patch).length === 1 && patch.enabled !== undefined ? (patch.enabled ? 'collector.enabled' : 'collector.disabled') : 'collector.updated',
        object: collectorObject(id, before),
        summary: `Couldn't change ${q(before?.name) || 'the collector'}`,
      }),
    },
    deleteCollector: {
      // The facts are read before the delete: a managed script's file is gone afterwards.
      before: async (id) => {
        const c = await getCollector(id);
        if (c) factsBefore.set(c, scriptFacts(c));
        return c;
      },
      trash: ([id], c: Collector | undefined) => {
        if (!c) return null;
        const { status: _s, ...record } = c;
        const facts = factsBefore.get(c) ?? scriptFacts(c);
        const details: TrashItem['details'] = {};
        for (const [k, v] of Object.entries(facts)) if (typeof v === 'string' || typeof v === 'number') details[k] = v;
        // v6: a script Distill keeps goes with its folder (script and manifest, not installed packages).
        const folder = c.status?.script?.managed ? (c.status.script.dir ?? undefined) : undefined;
        return { kind: 'collector', objectID: id, name: c.name, details, payload: record, ...(folder ? { folder } : {}) };
      },
      ok: ([id], _r, c: Collector | undefined, trashed) => ({
        type: 'collector.deleted',
        object: collectorObject(id, c),
        summary: `Deleted the ${c?.kind ?? ''} collector ${q(c?.name)}`.replace('  ', ' '),
        details: { ...(c ? (factsBefore.get(c) ?? scriptFacts(c)) : {}), lastRunAt: c?.status?.lastRun?.startedAt ?? null, collected: c?.status?.collectedCount ?? null },
        recovery: trashed ? { kind: 'trash', trashId: trashed.id, expiresAt: trashed.expiresAt } : { kind: 'none', reason: 'No copy was kept.' },
      }),
      fail: ([id], c: Collector | undefined) => ({ type: 'collector.deleted', object: collectorObject(id, c), summary: `Couldn't delete ${q(c?.name) || 'the collector'}` }),
    },
    stopCollector: {
      before: (id) => getCollector(id),
      ok: ([id], run, c: Collector | undefined) => (run ? { type: 'collector.stopped', object: collectorObject(id, c), summary: `Stopped ${q(c?.name)}`.trim() } : null),
      fail: ([id], c: Collector | undefined) => ({ type: 'collector.stopped', object: collectorObject(id, c), summary: `Couldn't stop ${q(c?.name) || 'the collector'}` }),
    },
    writeCollectorScript: {
      before: (id) => getCollector(id),
      ok: ([id, update], files, c: Collector | undefined) => {
        const parts: string[] = [];
        const details: Record<string, unknown> = { file: files.path };
        // What changed, sizes and a hash prefix; never the text (scripts and manifests can hold credentials).
        if (update.code !== undefined) {
          parts.push('script');
          // Only Distill's own script files are saved here: written in Distill.
          if (c?.script?.interpreter) details.interpreter = c.script.interpreter;
          details.scriptManaged = true;
          details.scriptBytes = Buffer.byteLength(update.code);
          details.scriptLines = lineCount(update.code);
          details.scriptSha256 = files.sha256?.slice(0, 12) ?? null;
        }
        if (update.manifest !== undefined) {
          const name = files.manifest?.name ?? 'manifest';
          parts.push(update.manifest === null ? `removed ${name}` : name);
          details.manifest = name;
          details.manifestBytes = update.manifest === null ? null : Buffer.byteLength(update.manifest);
          details.manifestSha256 = files.manifest?.sha256?.slice(0, 12) ?? null;
        }
        return { type: 'collector.script_saved', object: collectorObject(id, c), summary: `Saved ${parts.join(' and ')} of ${q(c?.name)} (needs your OK before it runs)`, details };
      },
      fail: ([id], c: Collector | undefined) => ({ type: 'collector.script_saved', object: collectorObject(id, c), summary: `Couldn't save the script of ${q(c?.name) || 'the collector'}` }),
    },
    stopCollectorInstall: {
      before: (id) => getCollector(id),
      ok: ([id], install, c: Collector | undefined) => (install ? { type: 'collector.install_stopped', object: collectorObject(id, c), summary: `Stopped installing packages for ${q(c?.name)}`.trim(), details: { installId: install.id } } : null),
      fail: ([id], c: Collector | undefined) => ({ type: 'collector.install_stopped', object: collectorObject(id, c), summary: `Couldn't stop the install for ${q(c?.name) || 'the collector'}` }),
    },
    allowCollector: {
      ok: ([, sha256], c) => ({ type: 'collector.consented', object: collectorObject(c.id, c), summary: `Allowed the script of ${q(c.name)} and turned it on`, details: { sha256: sha256.slice(0, 12) } }),
      fail: ([id]) => ({ type: 'collector.consented', object: { kind: 'collector', id }, summary: `Couldn't allow the script` }),
    },
    revokeCollector: {
      ok: (_args, c) => ({ type: 'collector.consent_revoked', object: collectorObject(c.id, c), summary: `Revoked consent for ${q(c.name)} and turned it off` }),
      fail: ([id]) => ({ type: 'collector.consent_revoked', object: { kind: 'collector', id }, summary: `Couldn't revoke consent` }),
    },
    forgetCollected: {
      before: (id) => getCollector(id),
      ok: ([id, sha], files, c: Collector | undefined) => ({
        type: 'collector.forgot',
        object: collectorObject(id, c),
        summary: sha ? `Forgot ${q(files[0]?.name)} in ${q(c?.name)}` : `Forgot ${plural(files.length, 'collected file')} in ${q(c?.name)}`,
        details: { files: files.map((f) => f.name) },
      }),
      fail: ([id], c: Collector | undefined) => ({ type: 'collector.forgot', object: collectorObject(id, c), summary: `Couldn't forget collected files` }),
    },
    restoreCollected: {
      before: (id) => getCollector(id),
      ok: ([id, files], count, c: Collector | undefined) => ({ type: 'collector.forget_undone', object: collectorObject(id, c), summary: `Put back ${plural(count, 'collected file')} in ${q(c?.name)}`, details: { files: files.map((f) => f.name) } }),
      fail: ([id], c: Collector | undefined) => ({ type: 'collector.forget_undone', object: collectorObject(id, c), summary: `Couldn't put back collected files` }),
    },
    createCollectorFolder: {
      ok: ([, which], c) => ({ type: 'collector.folder_created', object: collectorObject(c.id, c), summary: `Created the ${which} folder for ${q(c.name)}`, details: { which, ...(which === 'source' && c.folder ? { folder: c.folder.source } : {}) } }),
      fail: ([id, which]) => ({ type: 'collector.folder_created', object: { kind: 'collector', id }, summary: `Couldn't create the ${which} folder` }),
    },
  };
}

/** How each method is logged: "logged" (wrapped here), "read", "event" or "quiet". For tests and the spec. */
export function classifiedMethods(): Record<string, 'logged' | 'read' | 'event' | 'quiet'> {
  const specs = buildSpecs({} as Core, { askDir: '' } as InstrumentDeps) as Record<string, unknown>;
  return Object.fromEntries(Object.entries(specs).map(([k, v]) => [k, typeof v === 'string' ? (v as 'read' | 'event' | 'quiet') : 'logged']));
}

// ───────────── the wrapper ─────────────

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** The spec's failure entry, or a plain one when the spec itself throws (an entry is never dropped). */
function describeFailure(name: string, s: Spec<Method>, args: never, before: unknown): Omit<Described, 'details' | 'recovery'> {
  try {
    return s.fail(args, before);
  } catch (err) {
    console.warn(`distill activity: couldn't describe a failed ${name}: ${errorMessage(err)}`);
    return { type: `core.${name}`, object: { kind: 'core', name }, summary: `Couldn't ${name}` };
  }
}

/** Wrap every logged method of the core. Returns a new object; reads are passed through. */
export function instrumentCore<T extends Core>(core: T, deps: InstrumentDeps): T {
  const specs = buildSpecs(core, deps) as Record<string, Classification<Method>>;
  const out = { ...core } as Record<string, unknown>;
  for (const [name, spec] of Object.entries(specs)) {
    if (typeof spec === 'string') continue;
    const original = (core as unknown as Record<string, (...a: unknown[]) => Promise<unknown>>)[name];
    if (typeof original !== 'function') continue;
    const s = spec as unknown as Spec<Method>;
    out[name] = (...args: unknown[]) =>
      runInMethod(name, async () => {
        const a = args as never;
        let before: unknown;
        try {
          before = await (s.before as ((...x: unknown[]) => unknown) | undefined)?.(...args);
        } catch {
          before = undefined;
        }
        const source: ActivitySource = currentSource();
        const write = (d: Described, outcome: 'ok' | 'failed', error?: string) =>
          deps.log.record({ ...d, source, outcome, ...(error ? { error } : {}) });
        let trashed: TrashItem | undefined;
        const request = s.trash?.(a, before) ?? null;
        if (request) {
          try {
            trashed = deps.trash.put({ ...request, source });
          } catch (err) {
            // No copy, no delete: a delete that can't be undone is refused.
            const message = `Couldn't keep a copy in Distill's trash, so nothing was deleted: ${errorMessage(err)}`;
            write(describeFailure(name, s, a, before), 'failed', message);
            throw Object.assign(new Error(message), { code: 'invalid_state' });
          }
        }
        let result: unknown;
        try {
          result = await original.apply(core, args);
        } catch (err) {
          if (trashed) deps.trash.remove(trashed.id);
          // The core's error is what the caller gets, even when describing the failure fails.
          write(describeFailure(name, s, a, before), 'failed', errorMessage(err));
          throw err;
        }
        let described: Described | Described[] | null;
        try {
          described = s.ok(a, result as never, before, trashed);
        } catch (err) {
          // Describing never fails the change, and never drops its entry: a plain one says it happened.
          console.warn(`distill activity: couldn't describe ${name}: ${errorMessage(err)}`);
          const f = describeFailure(name, s, a, before);
          described = { type: f.type, object: f.object, summary: `${name}: done (the entry couldn't be described)`, details: { describeError: errorMessage(err) } };
        }
        for (const d of Array.isArray(described) ? described : described ? [described] : []) write(d, 'ok');
        return result;
      });
  }
  return out as T;
}

// ───────────── the event stream ─────────────

export interface EventLoggerDeps {
  log: ActivityLog;
  /** Settings for the retention days in "expired" entries. */
  getSettings: () => Settings;
  /** Names for collector runs (collector.run.finished carries only the id). */
  collectorName: (id: string) => string | undefined;
}

const RUN_FAILED = new Set(['failed', 'timedout', 'notTrusted']);

function runSummary(name: string, run: CollectorRun): string {
  const n = q(name) || 'A collector';
  const added = run.filesAdded.length || run.counts.added + run.counts.copied + run.counts.moved;
  switch (run.result) {
    case 'success':
      return `${n} added ${plural(added, 'file')} to the queue`;
    case 'nothing':
      return `${n} ran: nothing new`;
    case 'stopped':
      return `${n} was stopped`;
    case 'skipped':
      return `${n} skipped a run${run.skipReason ? `: ${run.skipReason}` : ''}`;
    case 'notTrusted':
      return `${n} didn't run: the script changed since you allowed it`;
    case 'timedout':
      return `${n} timed out`;
    default:
      return `${n} failed${run.error?.message ? `: ${run.error.message}` : ''}`;
  }
}

/** Log what happens without a direct request: batches moving on, runs, retention, queue scans. */
export function createEventLogger(deps: EventLoggerDeps, seedJobs: Job[]): (event: CoreEvent) => void {
  const jobs = new Map<string, { state: Job['state']; actions?: string; stopped?: number }>();
  for (const j of seedJobs) jobs.set(j.id, { state: j.state, ...(j.actionsFound?.status ? { actions: j.actionsFound.status } : {}), stopped: j.stopped?.length ?? 0 });
  const write = (d: Described, source: ActivitySource, outcome: 'ok' | 'failed' = 'ok', error?: string) =>
    deps.log.record({ ...d, source, outcome, ...(error ? { error } : {}) });

  return (event) => {
    try {
      const method = currentMethod();
      switch (event.type) {
        case 'job': {
          const job = event.job;
          if (event.deleted) {
            jobs.delete(job.id);
            return;
          }
          const seen = jobs.get(job.id);
          jobs.set(job.id, { state: job.state, ...(job.actionsFound?.status ? { actions: job.actionsFound.status } : {}), stopped: job.stopped?.length ?? 0 });
          const source = currentSource();
          const object = jobObject(job.id, job);
          // v10 (full reads): a source that couldn't be read in full is left out of the change.
          const stoppedNow = job.stopped ?? [];
          if (stoppedNow.length > (seen?.stopped ?? 0)) {
            const added = stoppedNow.slice(seen?.stopped ?? 0);
            write(
              {
                type: 'batch.read_stopped',
                object,
                summary: `${plural(added.length, 'source')} in ${jobName(job)} couldn't be read in full: left out of the change`,
                details: { files: added.map((s) => s.file), reasons: added.map((s) => s.reason) },
              },
              'core',
            );
          }
          if (!seen && method !== 'suggestLabelsForPages' && method !== 'confirmLabels') {
            const reread = job.reread ? { reread: true, rereadID: job.reread.id, rereadGroup: job.reread.group, rereadGroups: job.reread.groups, ...(job.reread.fromJob ? { fromJob: job.reread.fromJob } : {}) } : {};
            const summary = job.reread ? `Started ${jobName(job)} (re-read ${job.reread.group} of ${job.reread.groups})` : `Started ${jobName(job)}`;
            write({ type: 'batch.started', object, summary, details: { files: job.files, ...(job.folders?.length ? { folders: job.folders } : {}), runner: job.runnerID ?? 'claude-code', model: job.model, ...reread } }, source);
          }
          if (seen && seen.state !== job.state) {
            if (job.state === 'awaitingApproval') write({ type: 'batch.ready', object, summary: `${jobName(job)} is ready for review`, details: { changedPaths: job.approval?.plan?.changed_paths ?? [] } }, source);
            else if (job.state === 'completed')
              write({ type: 'batch.applied', object, summary: job.changedPaths.length ? `${jobName(job)} applied ${plural(job.changedPaths.length, 'page change')}` : `${jobName(job)} finished with nothing to change`, details: { changedPaths: job.changedPaths, operationID: job.operationID ?? null } }, source);
            else if (job.state === 'failed') write({ type: 'batch.failed', object, summary: `${jobName(job)} failed`, details: { files: job.files } }, source, 'failed', job.error ?? 'failed');
            else if (job.state === 'rejected' && method !== 'reject') write({ type: 'batch.rejected', object, summary: `${jobName(job)} was rejected` }, source);
            else if (job.state === 'cancelled' && method !== 'cancel') write({ type: 'batch.cancelled', object, summary: `${jobName(job)} was cancelled` }, source);
          }
          const found = job.actionsFound;
          if (found && found.status !== seen?.actions && (found.status === 'done' || found.status === 'failed')) {
            if (found.status === 'failed') write({ type: 'action.found', object, summary: `Couldn't find actions in ${jobName(job)}` }, source, 'failed', found.error ?? 'failed');
            else if (found.found > 0) write({ type: 'action.found', object, summary: `Found ${plural(found.found, 'action')} in ${jobName(job)}`, details: { pending: found.pending, added: found.added, byType: Object.entries(found.byType).map(([k, v]) => `${k}: ${v}`) } }, source);
          }
          return;
        }
        case 'collector.install.finished': {
          const i = event.install;
          const name = deps.collectorName(i.collectorId) ?? i.collectorId;
          const failed = i.result === 'failed' || i.result === 'timedout';
          const verb = i.result === 'success' ? 'Installed' : i.result === 'stopped' ? 'Stopped installing' : "Couldn't install";
          write(
            {
              type: 'collector.install',
              object: { kind: 'collector', id: i.collectorId, name },
              summary: `${verb} packages for ${q(name)} (${i.manifestName})`,
              // Never the output: an install can print tokens.
              details: { installId: i.id, result: i.result, trigger: i.trigger, manifest: i.manifestName, manifestSha256: i.manifestSha256.slice(0, 12), command: i.command, durationMs: i.durationMs ?? null, ...(i.exitCode !== undefined ? { exitCode: i.exitCode } : {}), ...(i.clean ? { clean: true } : {}), ...(i.runtime ? { runtime: i.runtime.label } : {}) },
            },
            i.trigger === 'beforeRun' ? 'scheduler' : currentSource(),
            failed ? 'failed' : 'ok',
            failed ? (i.error?.message ?? i.result) : undefined,
          );
          return;
        }
        case 'collector.script.changed_outside': {
          // A kept script or manifest saved by another program (an editor opened with "Open in editor"):
          // no request reached the core, so the entry is Distill noticing it, with sizes and hash
          // prefixes and never the text. Its consent hash changed too, so it won't run until allowed.
          const ch = event.change;
          const parts = ch.changes.map((p) => (p === 'manifest' ? (ch.manifest?.name ?? 'manifest') : 'script'));
          const gone = (ch.changes.includes('script') && !ch.script) || (ch.changes.includes('manifest') && ch.manifest === null);
          const details: Record<string, unknown> = { changedOutside: true, changes: ch.changes, interpreter: ch.interpreter };
          if (ch.script) {
            details.file = ch.script.path;
            details.modifiedAt = ch.script.modifiedAt;
            if (ch.changes.includes('script')) {
              details.scriptBytes = ch.script.bytes;
              details.scriptLines = ch.script.lines;
              details.scriptSha256 = ch.script.sha256.slice(0, 12);
            }
          }
          if (ch.changes.includes('manifest')) {
            details.manifest = ch.manifest?.name ?? null;
            details.manifestBytes = ch.manifest?.bytes ?? null;
            details.manifestSha256 = ch.manifest?.sha256.slice(0, 12) ?? null;
            if (ch.manifest) details.modifiedAt = ch.manifest.modifiedAt;
          }
          write(
            {
              type: 'collector.script_changed_outside',
              object: { kind: 'collector', id: ch.collectorId, name: ch.name },
              summary: `${gone ? 'Removed' : 'Changed'} ${parts.join(' and ')} of ${q(ch.name)} outside Distill (needs your OK before it runs)`,
              details,
            },
            'scheduler',
          );
          return;
        }
        case 'collector.run.finished': {
          const run = event.run;
          if (run.trigger === 'test') {
            const name = deps.collectorName(run.collectorId) ?? run.collectorId;
            const failed = RUN_FAILED.has(run.result);
            write(
              {
                type: 'collector.test_run',
                object: { kind: 'collector', id: run.collectorId, name },
                summary: failed ? `Test run of ${q(name)} failed${run.error?.message ? `: ${run.error.message}` : ''}` : `Test run of ${q(name)}: ${plural(run.filesAdded.length, 'file')} in its test folder, nothing in the queue`,
                details: { runId: run.id, result: run.result, durationMs: run.durationMs ?? null, filesAdded: run.filesAdded, outputDir: run.outputDir ?? null, ...(run.exitCode !== undefined ? { exitCode: run.exitCode } : {}), ...(run.runtime ? { runtime: run.runtime.label } : {}) },
              },
              currentSource(),
              failed ? 'failed' : 'ok',
              failed ? (run.error?.message ?? run.result) : undefined,
            );
            return;
          }
          const scheduled = run.trigger !== 'now';
          if (scheduled && (run.result === 'nothing' || run.result === 'skipped')) return; // in the run history; nothing changed
          const name = deps.collectorName(run.collectorId) ?? run.collectorId;
          const source: ActivitySource = scheduled ? 'scheduler' : currentSource();
          const failed = RUN_FAILED.has(run.result);
          write(
            {
              type: 'collector.run',
              object: { kind: 'collector', id: run.collectorId, name },
              summary: runSummary(name, run),
              details: {
                runId: run.id,
                result: run.result,
                trigger: run.trigger,
                durationMs: run.durationMs ?? null,
                filesAdded: run.filesAdded,
                ...(run.exitCode !== undefined ? { exitCode: run.exitCode } : {}),
                ...(run.runtime ? { runtime: run.runtime.label } : {}),
              },
            },
            source,
            failed ? 'failed' : 'ok',
            failed ? (run.error?.message ?? run.result) : undefined,
          );
          return;
        }
        case 'conversation': {
          if (!event.deleted || method === 'deleteConversation') return;
          const days = event.conversation.pinned ? undefined : deps.getSettings().askPreferences?.historyDays;
          write(
            {
              type: 'chat.expired',
              object: { kind: 'chat', id: event.conversation.id, name: event.conversation.title },
              summary: `Removed the chat ${q(event.conversation.title)}: older than ${days ?? 10} days (Ask history retention)`,
              details: { turnCount: event.conversation.turnCount, lastMessageAt: event.conversation.updatedAt, reason: 'retention' },
              recovery: { kind: 'none', reason: 'Ask history keeps unpinned chats for the days set in Settings → Ask; pin a chat to keep it.' },
            },
            'scheduler',
          );
          return;
        }
        case 'action': {
          if (!event.deleted || method === 'deleteActionForever') return;
          write(
            {
              type: 'action.expired',
              object: actionObject(event.action.id, event.action),
              summary: `Removed ${q(event.action.title)} from History (History retention)`,
              details: { actionType: event.action.type, status: event.action.status },
              recovery: { kind: 'none', reason: 'Actions History keeps items for the days set in Settings → Actions.' },
            },
            'scheduler',
          );
          return;
        }
        case 'session.replaced': {
          // Session continuity: the place and the reason, never content.
          const object: ActivityObject =
            event.place === 'conversation'
              ? { kind: 'chat', id: event.objectID, ...(event.name ? { name: event.name } : {}) }
              : { kind: 'batch', id: event.objectID, name: event.name ?? event.objectID };
          const what = event.place === 'conversation' ? 'the chat' : event.place === 'terminal' ? 'a batch in Terminal' : 'a batch';
          write(
            {
              type: 'session.replaced',
              object,
              summary: `Continued ${what} in a new AI session (the earlier one was not available)`,
              details: { place: event.place, reason: event.reason ?? null },
            },
            currentSource(),
          );
          return;
        }
        case 'repair.queued': {
          write(
            {
              type: 'batch.repair_queued',
              object: { kind: 'batch', id: event.rereadId, name: 'Full-read repair' },
              summary: `Reading ${plural(event.sources, 'source')} again in ${plural(event.batches, 'batch', 'batches')}: never read in full`,
              details: { files: event.files, ...(event.missing?.length ? { missing: event.missing } : {}) },
            },
            'core',
          );
          return;
        }
        case 'queue.scanned': {
          const r = event.result;
          if (r.added === 0 && r.removed === 0) return; // changed sizes/times alone aren't worth a line
          const source: ActivitySource = r.trigger === 'periodic' ? 'scheduler' : currentSource();
          const parts = [r.added ? `${r.added} new` : '', r.removed ? `${r.removed} gone` : ''].filter(Boolean).join(', ');
          write(
            {
              type: 'queue.scanned',
              object: { kind: 'queue', name: 'Queue folder' },
              summary: `Queue folder changed outside Distill: ${parts}`,
              details: { trigger: r.trigger, added: r.addedEntries.map((e) => e.name), removed: r.removedEntries.map((e) => e.name) },
            },
            source,
          );
          return;
        }
        default:
          return;
      }
    } catch {
      /* logging never breaks the event stream */
    }
  };
}
