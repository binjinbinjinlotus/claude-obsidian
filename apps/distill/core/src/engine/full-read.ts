import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import {
  DEFAULT_DETAIL_LEVELS,
  type CoreEvent,
  type CoverageSummary,
  type DetailLevel,
  type HeldSource,
  type Job,
  type PendingPart,
  type RereadRequest,
  type RereadResult,
  type RunnerRegistry,
  type RunResult,
  type Settings,
  type StatePaths,
  type StoppedSource,
  type VaultProfile,
} from '../contracts.js';
import { isoDate } from '../store/json.js';
import { isFinished, jobRunnerID, jobStateDirectory } from '../store/jobs.js';
import { archiveFactsFor, archiveProblems, archivedCopy, ledgerRecords, type LedgerRecord } from '../coverage/archive.js';
import { estimateTokens, makeReadingCopy, sourceKind, type ReadingCopy } from '../coverage/copy.js';
import {
  computeCoverage,
  continuationPrompt,
  creditedLines,
  loadRecord,
  MAX_CONTINUATIONS,
  newRecord,
  partialPrompt,
  partialWording,
  rangeText,
  saveRecord,
  summarize,
  unchangedPagePrompt,
  type CoverageRecord,
  type SourceCoverage,
} from '../coverage/coverage.js';
import { detailContinuation, runDetailPass, type DetailResult } from '../coverage/detail.js';
import { parseTurn } from '../coverage/stream.js';
import { batchBudget, contextWindowFor, CoverageIndex, ModelWindows, RepairLog } from '../coverage/store.js';
import { NOTE_MANIFEST_SUFFIX, type ParsedStatus, type SourceFacts } from './job-kinds.js';
import { readBundle, sourcePages, type LoadedBundle, type SourcePage } from './review-labels.js';
import { mapPool } from './queue-labels.js';

/**
 * Full reads (full-read.md): every source of a batch is read from its first line to its last, and
 * its page carries what the source says, before the batch reaches Review. The core checks this from
 * the runner's own tool results; the AI's report is never trusted. When something is missing,
 * Distill fixes it without asking. Only a source that truly can't be read reaches the owner, and it
 * is never part of what they approve.
 */

export interface FullReadDeps {
  paths: StatePaths;
  now(): Date;
  settings(): Settings;
  runners: RunnerRegistry;
  jobs(): Job[];
  findJob(id: string): Job | undefined;
  mutate(id: string, change: (job: Job) => void): void;
  /** Resume (autoContinue) or start (first) a turn of the batch's session. */
  runTurn(id: string, prompt: string, extra: { first?: boolean; autoContinue?: boolean }): void;
  /** Is the batch's session known to be gone (positive evidence only)? */
  sessionGone(job: Job): boolean;
  vaultProfileFor(job: Job): VaultProfile;
  log(level: 'info' | 'warn' | 'error', message: string): void;
  emit(e: CoreEvent): void;
  signalOf(id: string): AbortSignal | undefined;
  step?(jobId: string, s: FullReadStep): void;
  /** Builds the first prompt of a reading session for these files (the ingest kind's prompt). */
  readingPrompt(job: Job, files: string[], facts: { sources: SourceFacts[]; unreadable: { file: string; reason: string }[]; bundlePath?: string; partNote?: string }): string;
  rereadSources(req: RereadRequest): Promise<RereadResult>;
  /** Files in re-read groups that haven't started (reread.json). */
  waitingRereadFiles(vaultPath: string): Set<string>;
  nextPartBundle(dir: string): string;
}

export interface FullReadStep {
  id?: string;
  text: string;
  state: 'done' | 'running' | 'failed' | 'waiting';
  verb: 'coverage' | 'continue' | 'detail' | 'split' | 'stop' | 'archive';
  detail?: string;
  count?: string;
}

const plural = (n: number, noun: string, many = `${noun}s`) => `${n} ${n === 1 ? noun : many}`;
const titleOf = (f: string) => path.posix.basename(f).replace(/\.(md|markdown|txt)$/i, '');

function sha256File(abs: string): string | undefined {
  try {
    return createHash('sha256').update(fs.readFileSync(abs)).digest('hex');
  } catch {
    return undefined;
  }
}

/** Which kind of source a ledger record or name is, for its detail level. */
export function detailTypeOf(file: string, contentKind?: string): keyof typeof DEFAULT_DETAIL_LEVELS {
  if (/meeting|notes by gemini|transcript|stand-?up|sync|\bcall\b|1:1|one-on-one|retro|standup/i.test(file)) return 'meeting';
  if (contentKind === 'conversation') return 'conversation';
  if (contentKind === 'research/paper' || contentKind === 'research' || contentKind === 'reference/web') return 'research';
  return 'other';
}

export function createFullRead(d: FullReadDeps) {
  const dir = path.join(d.paths.dir, 'coverage');
  const index = new CoverageIndex(path.join(dir, 'sources.json'));
  const repairs = new RepairLog(path.join(dir, 'repair.json'));
  const windows = new ModelWindows(path.join(dir, 'models.json'));

  const runnerOf = (job: Job) => d.runners.get(jobRunnerID(job));
  /** The gate runs for batches on runners whose reads can be verified. */
  function coverageOn(job: Job): boolean {
    return job.kind === 'ingest' && runnerOf(job)?.capabilities.has('readCoverage') === true;
  }

  function step(jobId: string, s: FullReadStep): void {
    try {
      d.step?.(jobId, s);
    } catch {
      /* the log never breaks a batch */
    }
  }

  // ───────────── the budget ─────────────

  function budget(model: string): { tokens: number; contextWindow: number; model: string; automatic: boolean } {
    const s = d.settings();
    const w = contextWindowFor(model, windows);
    return { tokens: batchBudget(s.batchSourceTokens, w), contextWindow: w, model, automatic: !(typeof s.batchSourceTokens === 'number' && s.batchSourceTokens > 0) };
  }

  // ───────────── before the first turn ─────────────

  /** Note images kept as attachments (not read) and manifests are not sources to read. */
  function readableSources(vaultPath: string, files: string[]): string[] {
    const keep = new Set<string>();
    for (const f of files) {
      if (!f.endsWith(NOTE_MANIFEST_SUFFIX)) continue;
      try {
        const m = JSON.parse(fs.readFileSync(path.join(vaultPath, f), 'utf8')) as { images?: { file?: unknown; mode?: unknown }[] };
        for (const i of m.images ?? []) {
          if (typeof i.file === 'string' && i.mode !== 'extract') keep.add(path.posix.join(path.posix.dirname(f), i.file));
        }
      } catch {
        /* an unreadable manifest: its images are read like any source */
      }
    }
    return files.filter((f) => !f.endsWith(NOTE_MANIFEST_SUFFIX) && !keep.has(f));
  }

  /**
   * Makes the reading copies of `files` in the job directory and starts this session's coverage
   * record. Returns the facts the prompt gives. A source the core can't read as text is stopped
   * here: it is left out of the prompt and never read by the AI.
   */
  function prepare(job: Job, vault: VaultProfile, files: string[], o: { small?: boolean; existing?: Map<string, { pages: string[] }>; carryFull?: string[] } = {}): { sources: SourceFacts[]; unreadable: { file: string; reason: string }[] } {
    const jobDir = jobStateDirectory(job);
    const sessionDir = o.small ? path.join(jobDir, `session-${job.sessionID.slice(0, 8)}`) : jobDir;
    const sources = readableSources(vault.path, files);
    const copies: ReadingCopy[] = sources.map((f, i) => makeReadingCopy(vault.path, f, sessionDir, i + 1, o.small ? { small: true } : {}));
    const archive = archiveFactsFor(vault.path, copies.filter((c) => !c.unreadable && c.sha256).map((c) => ({ file: c.file, sha256: c.sha256 })));
    const record = newRecord(job.sessionID, copies);
    // A source already read in full by this batch (before a new session) stays full.
    for (const f of o.carryFull ?? []) {
      const s = record.sources.find((x) => x.file === f);
      if (s) record.events.push({ t: 'read', seq: ++record.seq, path: s.copy ?? path.join(vault.path, s.file), from: 1, to: s.lines, ...(s.kind !== 'text' ? { whole: true } : {}) });
    }
    try {
      saveRecord(jobDir, record);
    } catch (err) {
      d.log('warn', `Could not save the coverage of ${job.id}: ${(err as Error).message}`);
    }
    const unreadable = copies.filter((c) => c.unreadable).map((c) => ({ file: c.file, reason: c.unreadable! }));
    const at = isoDate(d.now());
    const cov = computeCoverage(record, { vaultPath: vault.path });
    d.mutate(job.id, (j) => {
      j.coverage = summarize(cov, record, 'reading');
      if (unreadable.length > 0) {
        const known = new Set((j.stopped ?? []).map((s) => s.file));
        j.stopped = [
          ...(j.stopped ?? []),
          ...unreadable.filter((u) => !known.has(u.file)).map((u): StoppedSource => {
            const sha = copies.find((c) => c.file === u.file)?.sha256;
            return { file: u.file, reason: u.reason, at, ...(sha ? { sha256: sha } : {}) };
          }),
        ];
      }
    });
    for (const u of unreadable) step(job.id, { text: `Can’t read “${titleOf(u.file)}”: ${u.reason}`, state: 'failed', verb: 'stop', detail: 'Left out of this batch; never part of what you approve' });
    const facts: SourceFacts[] = copies
      .filter((c) => !c.unreadable)
      .map((c) => {
        const f: SourceFacts = {
          file: c.file,
          bytes: c.bytes,
          lines: c.sourceLines,
          textBytes: c.textBytes,
          imageLines: c.imageLines,
          longLines: c.longLines,
          pages: o.existing?.get(c.file)?.pages ?? [],
          estTokens: c.estTokens,
          sha256: c.sha256,
        };
        if (c.imageAt) f.imageAt = c.imageAt;
        if (c.copy) {
          f.copy = path.relative(vault.path, c.copy).split(path.sep).join('/');
          f.copyLines = c.lines;
          f.sections = c.sections.map((s) => [s.from, s.to]);
        }
        const a = archive.get(c.file);
        if (a) f.archive = a;
        return f;
      });
    return { sources: facts, unreadable };
  }

  // ───────────── the gate ─────────────

  function draftsOf(b: LoadedBundle | undefined, pages: SourcePage[], files: string[], vaultPath: string): Map<string, string> {
    const out = new Map<string, string>();
    if (!b) return out;
    for (const p of pages) {
      const file = sourceOf(p, files, vaultPath);
      if (!file) continue;
      const w = p.write;
      if (typeof w.content_file === 'string') out.set(path.isAbsolute(w.content_file) ? w.content_file : path.resolve(b.dir, w.content_file), file);
      else out.set(b.path, file);
    }
    return out;
  }

  /** The source a page names (`source_path`), as one of `files`; a reading copy's path never counts. */
  function sourceOf(p: SourcePage, files: string[], vaultPath: string): string | undefined {
    if (!p.source) return undefined;
    let rel = p.source.normalize('NFC');
    if (path.isAbsolute(rel)) rel = path.relative(vaultPath, rel).split(path.sep).join('/');
    if (files.includes(rel)) return rel;
    const lower = rel.toLowerCase();
    return files.find((f) => f.toLowerCase() === lower);
  }

  function pageSha(p: SourcePage): string {
    return createHash('sha256').update(p.text).digest('hex');
  }

  function bundleText(b: LoadedBundle, pagePath: string): string | undefined {
    const w = b.writes.find((x) => x.path === pagePath);
    if (!w) return undefined;
    if (typeof w.content === 'string') return w.content;
    if (typeof w.content_file !== 'string') return undefined;
    try {
      return fs.readFileSync(path.isAbsolute(w.content_file) ? w.content_file : path.resolve(b.dir, w.content_file), 'utf8');
    } catch {
      return undefined;
    }
  }

  function bundleOf(job: Job, status: ParsedStatus, vault: VaultProfile): string | undefined {
    if (status.status !== 'needs_approval' || !status.bundle_path) return undefined;
    const bundle = path.resolve(vault.path, status.bundle_path);
    return bundle.startsWith(path.resolve(jobStateDirectory(job)) + '/') ? bundle : undefined;
  }

  function setSummary(id: string, record: CoverageRecord, cov: SourceCoverage[], state: CoverageSummary['state'], extra: Partial<CoverageSummary> = {}): void {
    d.mutate(id, (j) => {
      const prev = j.coverage;
      const next = summarize(cov, record, state);
      if (prev?.detail) next.detail = prev.detail;
      if (prev?.later) next.later = prev.later;
      if (prev?.archived) next.archived = prev.archived;
      if (prev?.partialWording) next.partialWording = prev.partialWording;
      for (const s of next.sources) {
        if (j.stopped?.some((x) => x.file === s.file)) s.state = 'stopped';
        if (next.later?.includes(s.file)) s.state = 'later';
      }
      j.coverage = { ...next, ...extra };
    });
  }

  function continueWith(id: string, record: CoverageRecord, prompt: string, said: string): boolean {
    const job = d.findJob(id);
    if (!job) return false;
    if (d.sessionGone(job)) return false;
    saveRecord(jobStateDirectory(job), record);
    d.mutate(id, (j) => j.turns.push({ id: randomUUID(), date: isoDate(d.now()), author: 'app', text: said, costUSD: 0 }));
    d.runTurn(id, prompt, { autoContinue: true });
    return true;
  }

  /**
   * Runs first in `handle()` for a reading turn. Returns true when it took over (a continuation, a
   * split, a fresh session or a stop); false lets the decision go on as usual.
   */
  async function gate(id: string, status: ParsedStatus | undefined, result: RunResult, applying: boolean): Promise<boolean> {
    const job = d.findJob(id);
    if (!job || applying || !coverageOn(job)) return false;
    const reason = job.pendingPart?.reason;
    // Parts rebuilt from pages that already passed skip it; a fresh session reading what was left doesn't.
    if (reason && reason !== 'unread') return false;
    const jobDir = jobStateDirectory(job);
    const record = loadRecord(jobDir);
    if (!record) return false;
    const vault = d.vaultProfileFor(job);
    const parsed = parseTurn(result.raw, record.seq, record.lastContext);
    record.events.push(...parsed.events);
    record.seq = parsed.nextSeq;
    record.lastContext = parsed.lastContext;
    if (Object.keys(parsed.contextWindows).length > 0) windows.set(parsed.contextWindows, job.model);
    saveRecord(jobDir, record);
    if (!status) return false;
    const st = status.status;
    if (st === 'failed') return false;
    // Real questions or a blocked tool go to the owner; the gate runs on the turn after their reply.
    if (st === 'needs_input' && (status.questions.length > 0 || result.denials.length > 0)) return false;
    if (st !== 'needs_approval' && st !== 'nothing_to_do' && st !== 'needs_input' && st !== 'done') return false;

    const files = record.sources.map((s) => s.file);
    const bundlePath = bundleOf(job, status, vault);
    const b = bundlePath ? readBundle(bundlePath) : undefined;
    const pages = b ? sourcePages(b) : [];
    const cov = computeCoverage(record, { vaultPath: vault.path, drafts: draftsOf(b, pages, files, vault.path) });
    const stopped = new Set((job.stopped ?? []).map((s) => s.file));
    const missing = cov.filter((c) => !c.full && !c.unreadable && !stopped.has(c.file));
    const credited = creditedLines(cov);
    const target = bundlePath ?? path.join(jobDir, 'bundle.json');

    // 1. Lines never read: ask the same session for exactly those lines.
    if (missing.length > 0) {
      const progress = record.rounds === 0 || credited > record.creditedAtLastRound;
      if (record.rounds < MAX_CONTINUATIONS && progress) {
        record.rounds += 1;
        record.creditedAtLastRound = credited;
        for (const m of missing) {
          const s = record.sources.find((x) => x.file === m.file);
          if (s) s.rounds = (s.rounds ?? 0) + 1;
        }
        // Only the sources asked for more lines: their pages must change once those lines are read.
        const asked = new Set(missing.map((m) => m.file));
        record.pageShaAtRound = {
          ...(record.pageShaAtRound ?? {}),
          ...Object.fromEntries(pages.flatMap((p) => {
            const f = sourceOf(p, files, vault.path);
            return f && asked.has(f) ? [[f, pageSha(p)]] : [];
          })),
        };
        setSummary(id, record, cov, 'reading');
        const first = missing[0]!;
        step(id, {
          text: `Not read yet: ${rangeText(first.missing.slice(0, 2))} of “${titleOf(first.file)}”${missing.length > 1 ? ` and ${missing.length - 1} more` : ''}`,
          state: 'done',
          verb: 'coverage',
          detail: missing.map((m) => `${titleOf(m.file)}: ${rangeText(m.missing)} (${m.read} of ${m.required} lines read)`).join(' · ').slice(0, 300),
        });
        step(id, { text: `Asked ${runnerOf(job)?.displayName ?? 'the AI'} to read what was left · round ${record.rounds} of ${MAX_CONTINUATIONS}`, state: 'done', verb: 'continue' });
        const said = `${plural(missing.length, 'source')} ${missing.length === 1 ? 'wasn’t' : 'weren’t'} read to the end (${missing.map((m) => `${titleOf(m.file)}: ${m.read} of ${m.required} lines`).join('; ')}). Asked for exactly the lines that never came back.`;
        if (continueWith(id, record, continuationPrompt(record, cov, target, vault.path), said)) return true;
        // The session is gone: every source goes to a fresh session.
        return freshSession(id, record, files.filter((f) => !stopped.has(f)), 'the session isn’t available any more');
      }
    }

    const covered = cov.filter((c) => c.full);
    const coveredFiles = new Set(covered.map((c) => c.file));

    // 2. The checks on what was read in full, before Review (and before any split).
    if (b && bundlePath && covered.length > 0) {
      const ownPages = pages.filter((p) => {
        const f = sourceOf(p, files, vault.path);
        return f !== undefined && coveredFiles.has(f);
      });
      // A page naming its reading copy instead of its source.
      const copyNamed = pages.filter((p) => p.source && /\.vault-meta\/worker\//.test(p.source));
      if (copyNamed.length > 0 && record.rounds < MAX_CONTINUATIONS) {
        record.rounds += 1;
        const prompt = `These source pages name Distill's reading copy as their source. Set \`source_path\` (and every citation) to the ORIGINAL path, rebuild the bundle at ${bundlePath}, inspect it, and finish with \`needs_approval\`:\n${copyNamed.map((p) => `- ${p.page}: ${p.source}`).join('\n')}`;
        if (continueWith(id, record, prompt, 'Some pages named the reading copy as their source; asked for the original path.')) return true;
      }
      // Partial wording although every line was read: never escalates to a stop.
      const partial = ownPages.flatMap((p) => {
        const snippet = partialWording(p.text);
        return snippet ? [{ page: p.page, file: sourceOf(p, files, vault.path)!, snippet }] : [];
      });
      for (const meta of ['wiki/log.md', 'wiki/hot.md']) {
        const text = bundleText(b, meta);
        const snippet = text ? partialWording(text.split('\n').slice(0, 80).join('\n')) : undefined;
        if (snippet && partial.length === 0 && covered.length === record.sources.filter((s) => !s.unreadable).length) partial.push({ page: meta, file: covered[0]!.file, snippet });
      }
      if (partial.length > 0) {
        if (record.rounds < MAX_CONTINUATIONS) {
          record.rounds += 1;
          setSummary(id, record, cov, 'reading');
          step(id, { text: `Every line was read, but ${plural(partial.length, 'page')} still ${partial.length === 1 ? 'says' : 'say'} partial`, state: 'done', verb: 'continue', detail: partial.map((p) => p.page).join(', ') });
          if (continueWith(id, record, partialPrompt(partial, bundlePath), `Every line was read, but ${partial.map((p) => p.page).join(', ')} still ${partial.length === 1 ? 'says it is' : 'say they are'} partial; asked to drop that.`)) return true;
        }
        d.mutate(id, (j) => {
          if (j.coverage) j.coverage.partialWording = partial.map((p) => p.page);
        });
      } else {
        d.mutate(id, (j) => {
          if (j.coverage) delete j.coverage.partialWording;
        });
      }
      // New lines were read after the last continuation, but the page didn't change.
      const before = record.pageShaAtRound ?? {};
      const unchanged = ownPages.flatMap((p) => {
        const f = sourceOf(p, files, vault.path)!;
        return before[f] && before[f] === pageSha(p) ? [{ page: p.page, file: f, ranges: 'the lines read after the first round' }] : [];
      });
      if (unchanged.length > 0 && record.rounds < MAX_CONTINUATIONS) {
        record.rounds += 1;
        record.pageShaAtRound = {};
        if (continueWith(id, record, unchangedPagePrompt(unchanged, bundlePath), `${plural(unchanged.length, 'page')} didn’t change after more of ${unchanged.length === 1 ? 'its source was' : 'their sources were'} read; asked to update ${unchanged.length === 1 ? 'it' : 'them'}.`)) return true;
      }
      // The detail pass: what the pages miss at the chosen level is added before Review.
      if (!record.detail?.ran) {
        const results = await detailPass(job, record, ownPages, files, vault);
        const found = results.filter((r) => r.missing.length > 0);
        const added = found.reduce((n, r) => n + r.missing.length, 0);
        record.detail = { ran: true, missing: added };
        saveRecord(jobDir, record);
        d.mutate(id, (j) => {
          if (j.coverage) j.coverage.detail = { checked: results.length, added, left: 0, ...(results.some((r) => r.skipped) ? { note: `${results.filter((r) => r.skipped).length} not checked (too long)` } : {}) };
        });
        step(id, { text: added > 0 ? `Checked each page against its source: ${plural(added, 'thing')} to add` : 'Checked each page against its source: nothing missing', state: 'done', verb: 'detail', count: plural(results.length, 'page') });
        if (found.length > 0 && continueWith(id, record, detailContinuation(found, bundlePath), `The detail check found ${plural(added, 'thing')} the pages miss; asked to add them.`)) return true;
      } else if (record.detail.missing > 0 && record.detail.left === undefined) {
        // After the additions: the second pass is information only.
        const results = await detailPass(job, record, ownPages, files, vault);
        const left = results.reduce((n, r) => n + r.missing.length, 0);
        record.detail.left = left;
        saveRecord(jobDir, record);
        d.mutate(id, (j) => {
          if (j.coverage?.detail) j.coverage.detail.left = left;
        });
      }
      // Option A: each source archived, one ledger record per content.
      const facts = covered.flatMap((c) => {
        const s = record.sources.find((x) => x.file === c.file)!;
        if (!s.sha256) return [];
        const a = archiveFactsFor(vault.path, [{ file: c.file, sha256: s.sha256 }]).get(c.file)!;
        return [{ file: c.file, sha256: s.sha256, archive: a }];
      });
      const writes = b.writes.map((w) => {
        const text = w.path.endsWith('.json') ? bundleText(b, w.path) : undefined;
        return text !== undefined ? { path: w.path, text } : { path: w.path };
      });
      const problems = archiveProblems(writes, vault.path, facts);
      if (problems.length > 0 && record.rounds < MAX_CONTINUATIONS) {
        record.rounds += 1;
        const prompt = `The change doesn't archive the originals as asked (each source's original goes to .raw/captured/ with this change; one source ledger record per content):\n${problems.map((p) => `- ${p}`).join('\n')}\n\nFix the bundle at ${bundlePath}, inspect it, and finish with \`needs_approval\`.`;
        if (continueWith(id, record, prompt, `The archive of the originals is incomplete (${problems.length}); asked to fix it.`)) return true;
      }
      if (problems.length === 0) {
        d.mutate(id, (j) => {
          if (j.coverage) j.coverage.archived = facts.filter((f) => !f.archive.exists).length;
        });
      }
    }

    // 3. Lines one session couldn't finish: split them off (or stop them in a fresh session).
    if (missing.length > 0) {
      const fresh = job.pendingPart?.reason === 'unread';
      if (fresh) {
        const at = isoDate(d.now());
        const add: StoppedSource[] = missing.map((m) => ({
          file: m.file,
          reason: `the reads stopped at line ${lastRead(m)} of ${m.required + (record.sources.find((s) => s.file === m.file)?.imageLines.length ?? 0)} every time, also alone in a fresh session`,
          at,
          ...(record.sources.find((s) => s.file === m.file)?.sha256 ? { sha256: record.sources.find((s) => s.file === m.file)!.sha256 } : {}),
        }));
        d.mutate(id, (j) => {
          j.stopped = [...(j.stopped ?? []), ...add];
        });
        for (const s of add) step(id, { text: `Couldn’t read “${titleOf(s.file)}” in full`, state: 'failed', verb: 'stop', detail: s.reason });
      }
      if (covered.length === 0 || !b || !bundlePath) {
        if (fresh) return stopAll(id, record, cov);
        return freshSession(id, record, files.filter((f) => !stopped.has(f)), 'nothing could be finished in this session');
      }
      return split(id, record, cov, b, bundlePath, pages, fresh ? [] : missing.map((m) => m.file), fresh ? missing.map((m) => m.file) : []);
    }

    setSummary(id, record, cov, (job.stopped?.length ?? 0) > 0 ? 'stopped' : 'complete');
    const n = cov.filter((c) => c.full).length;
    step(id, { text: `Read in full · ${n} of ${cov.filter((c) => !c.unreadable).length} sources · ${cov.reduce((k, c) => k + (c.full ? c.required : 0), 0).toLocaleString('en-US')} lines`, state: 'done', verb: 'coverage', count: 'counted from the tool results' });
    return false;
  }

  function lastRead(c: SourceCoverage): number {
    const first = c.missing[0];
    return first ? Math.max(0, first[0] - 1) : c.required;
  }

  async function detailPass(job: Job, record: CoverageRecord, pages: SourcePage[], files: string[], vault: VaultProfile): Promise<DetailResult[]> {
    const runner = runnerOf(job);
    if (!runner) return [];
    const levels = { ...DEFAULT_DETAIL_LEVELS, ...(d.settings().detailLevel ?? {}) };
    const ledger = ledgerRecordsSafe(vault.path);
    step(job.id, { id: 'detail', text: `Checking each page against its source · 0 of ${pages.length}`, state: 'running', verb: 'detail' });
    let done = 0;
    const out = await mapPool(pages, 3, async (p) => {
      const file = sourceOf(p, files, vault.path)!;
      const s = record.sources.find((x) => x.file === file);
      const contentKind = ledger.find((r) => r.sha256 === s?.sha256)?.kind;
      const level: DetailLevel = levels[detailTypeOf(file, contentKind)] ?? 'detailed';
      try {
        return await runDetailPass(
          runner,
          d.settings(),
          { file, page: p.page, sourcePath: s?.copy ?? path.join(vault.path, file), pageText: p.text, estTokens: s?.estTokens ?? 0, level },
          path.join(jobStateDirectory(job), 'detail'),
          d.signalOf(job.id),
        );
      } catch (err) {
        d.log('warn', `Detail check of ${p.page}: ${(err as Error).message}`);
        return { file, page: p.page, missing: [], skipped: 'the check failed', costUSD: 0 } satisfies DetailResult;
      } finally {
        done += 1;
        step(job.id, { id: 'detail', text: `Checking each page against its source · ${done} of ${pages.length}`, state: done === pages.length ? 'done' : 'running', verb: 'detail' });
      }
    });
    const cost = out.reduce((n, r) => n + r.costUSD, 0);
    if (cost > 0) d.mutate(job.id, (j) => j.turns.push({ id: randomUUID(), date: isoDate(d.now()), author: 'app', text: `Checked ${plural(out.length, 'page')} against ${out.length === 1 ? 'its source' : 'their sources'}.`, costUSD: cost }));
    return out;
  }

  function ledgerRecordsSafe(vaultPath: string): (LedgerRecord & { kind: string })[] {
    try {
      return ledgerRecords(vaultPath);
    } catch {
      return [];
    }
  }

  /**
   * Covered sources go to Review as a part; the rest (`unread`) are read next in a fresh session
   * after it applies, and `stoppedNow` never come back. A dedicated step: the same session builds
   * `bundle-part-<n>.json` from the covered pages, byte for byte, with nothing for the others.
   */
  function split(id: string, record: CoverageRecord, cov: SourceCoverage[], b: LoadedBundle, bundlePath: string, pages: SourcePage[], unread: string[], stoppedNow: string[]): boolean {
    const job = d.findJob(id)!;
    const vault = d.vaultProfileFor(job);
    const files = record.sources.map((s) => s.file);
    const out = new Set([...unread, ...stoppedNow, ...(job.stopped ?? []).map((s) => s.file)]);
    const keepPages = pages.filter((p) => {
      const f = sourceOf(p, files, vault.path);
      return f !== undefined && !out.has(f);
    });
    const leavePages = pages.filter((p) => {
      const f = sourceOf(p, files, vault.path);
      return f !== undefined && out.has(f);
    });
    if (d.sessionGone(job)) return freshSession(id, record, files.filter((f) => !(job.stopped ?? []).some((s) => s.file === f)), 'the session isn’t available any more');
    const jobDir = jobStateDirectory(job);
    const partBundle = d.nextPartBundle(jobDir);
    const pagesDir = path.join(jobDir, `${path.basename(partBundle, '.json')}-pages`);
    fs.mkdirSync(pagesDir, { recursive: true });
    const keep = keepPages.map((p) => {
      const w = p.write;
      let file = typeof w.content_file === 'string' ? (path.isAbsolute(w.content_file) ? w.content_file : path.resolve(b.dir, w.content_file)) : '';
      if (!file) {
        file = path.join(pagesDir, path.posix.basename(p.page));
        fs.writeFileSync(file, p.text);
      }
      return { page: p.page, source: p.source ?? null, contentFile: file, sha256: pageSha(p) };
    });
    const shas = (j: Job) => (j.stopped ?? []).filter((s) => out.has(s.file)).flatMap((s) => (s.sha256 ? [s.sha256] : []));
    const part: PendingPart = {
      reason: 'covered',
      expected: Object.fromEntries(keep.map((k) => [k.page, k.sha256])),
      excluded: leavePages.map((p) => p.page),
      labels: 'confirm',
      bundlePath: partBundle,
      ...(unread.length > 0 ? { unread } : {}),
    };
    const shaOut = [...shas(job), ...record.sources.filter((s) => out.has(s.file)).map((s) => s.sha256)];
    const leaveOut = [...out].filter((f) => files.includes(f));
    const prompt = [
      `Distill is splitting this batch: ${plural(keep.length, 'source')} ${keep.length === 1 ? 'was' : 'were'} read in full and ${plural(leaveOut.length, 'source')} ${leaveOut.length === 1 ? 'was' : 'were'} not.`,
      '',
      `Build a NEW transaction bundle at \`${partBundle}\` (leave every earlier bundle as it is), for the vault as it is now.`,
      '',
      'It must create these source pages, each byte for byte the file given: use a `content_file` pointing at that exact file and its sha256; do not rewrite, reformat or relabel them:',
      ...keep.map((k) => `- ${k.page}${k.source ? ` (from ${k.source})` : ''}: ${k.contentFile} (sha256 ${k.sha256})`),
      '',
      'Leave these sources out entirely: no page, no source or claim ledger record, no archive write for them:',
      ...leaveOut.map((f) => `- ${f}`),
      '',
      'Write the index, log, hot cache, overview, ledgers, and any concept or entity pages again so they cover only the sources above plus what is already in the vault, and keep the archive writes for the sources above.',
      'Run `transaction inspect` on the new bundle and finish with `needs_approval` and its `bundle_path`. Distill checks the source pages and the ledger before the user sees it.',
    ].join('\n');
    part.prompt = prompt;
    fs.writeFileSync(path.join(jobDir, `${path.basename(partBundle, '.json')}-excluded.json`), JSON.stringify({ files: leaveOut, sha256: shaOut }));
    d.mutate(id, (j) => {
      j.pendingPart = part;
      const summary = summarize(cov, record, unread.length > 0 ? 'split' : 'stopped');
      if (j.coverage?.detail) summary.detail = j.coverage.detail;
      if (j.coverage?.archived) summary.archived = j.coverage.archived;
      if (unread.length > 0) summary.later = unread;
      for (const s of summary.sources) {
        if (unread.includes(s.file)) s.state = 'later';
        if (j.stopped?.some((x) => x.file === s.file)) s.state = 'stopped';
      }
      j.coverage = summary;
    });
    if (unread.length > 0) step(id, { text: `${plural(unread.length, 'source')} go to a fresh session: this one ran out of room`, state: 'done', verb: 'split', detail: unread.map(titleOf).join(', ') });
    const said = unread.length > 0
      ? `${plural(unread.length, 'source')} didn’t finish in ${MAX_CONTINUATIONS} rounds (${unread.map(titleOf).join(', ')}): taken out of this change; ${unread.length === 1 ? 'it gets' : 'they get'} a fresh session after you approve these ${keep.length}.`
      : `${plural(stoppedNow.length, 'source')} couldn’t be read in full (${stoppedNow.map(titleOf).join(', ')}): taken out of this change.`;
    if (continueWith(id, record, prompt, said)) return true;
    return freshSession(id, record, files.filter((f) => !(d.findJob(id)?.stopped ?? []).some((s) => s.file === f)), 'the session isn’t available any more');
  }

  /** Nothing could be read in full even in a fresh session: the batch reaches Review with nothing to approve. */
  function stopAll(id: string, record: CoverageRecord, cov: SourceCoverage[]): boolean {
    d.mutate(id, (j) => {
      j.state = 'awaitingApproval';
      j.approval = {
        summary: 'Nothing in this batch could be read in full.',
        questions: [],
        denials: [],
        skipped: [],
        planError: 'Nothing in this batch could be read in full, so there is no change to approve. The files stay in inbox/ under Held; fix them and press Try again, or reject the batch.',
      };
      j.coverage = { ...summarize(cov, record, 'stopped'), ...(j.coverage?.detail ? { detail: j.coverage.detail } : {}) };
      for (const s of j.coverage.sources) if (j.stopped?.some((x) => x.file === s.file)) s.state = 'stopped';
      delete j.pendingPart;
    });
    return true;
  }

  /**
   * Reads `files` again from the start in a NEW session (a first turn: nothing is resumed, so no
   * SessionReplaceConfirm). Used for the unread part after the covered part applied, and when the
   * session is gone before anything was approved (then every source goes this way).
   */
  function freshSession(id: string, _record: CoverageRecord | undefined, files: string[], why: string): boolean {
    const job = d.findJob(id);
    if (!job) return false;
    const vault = d.vaultProfileFor(job);
    const applied = (job.parts ?? []).flatMap((p) => p.pages);
    const jobDir = jobStateDirectory(job);
    const bundle = d.nextPartBundle(jobDir);
    const session = randomUUID().toLowerCase();
    d.mutate(id, (j) => {
      j.sessionID = session;
      j.state = 'running';
      delete j.approval;
      j.pendingPart = { reason: 'unread', expected: {}, excluded: applied, labels: 'confirm', bundlePath: bundle };
      j.turns.push({ id: randomUUID(), date: isoDate(d.now()), author: 'app', text: `Reading ${plural(files.length, 'source')} again from the start in a fresh session (${why}).`, costUSD: 0 });
    });
    const fresh = d.findJob(id)!;
    const facts = prepare(fresh, vault, files, { small: true });
    const readable = facts.sources.map((s) => s.file);
    if (readable.length === 0) {
      const record = loadRecord(jobDir);
      return stopAll(id, record ?? newRecord(session, []), record ? computeCoverage(record, { vaultPath: vault.path }) : []);
    }
    const note = (fresh.parts?.length ?? 0) > 0
      ? `This batch's other sources were already added (operation ${fresh.parts!.at(-1)!.operationID}); the vault already has their pages. Build the change for the sources above only, at ${bundle}.`
      : `Build the change at ${bundle} (not bundle.json).`;
    step(id, { text: `Reading ${plural(readable.length, 'source')} again in a fresh session`, state: 'running', verb: 'split', detail: readable.map(titleOf).join(', ') });
    d.runTurn(id, d.readingPrompt(fresh, readable, { ...facts, bundlePath: bundle, partNote: note }), { first: true });
    return true;
  }

  /** After the covered part applied: what was left goes to a fresh session. */
  function startUnreadPart(id: string, files: string[]): void {
    freshSession(id, undefined, files, `${files.length === 1 ? 'it' : 'they'} didn’t finish in the first session`);
  }

  /** A refused resume of an automatic continuation: a fresh session reads everything not yet added. */
  function autoContinueRefused(id: string): void {
    const job = d.findJob(id);
    if (!job) return;
    const record = loadRecord(jobStateDirectory(job));
    const done = new Set((job.parts ?? []).flatMap((p) => p.pages));
    const stopped = new Set((job.stopped ?? []).map((s) => s.file));
    const vault = d.vaultProfileFor(job);
    const pagesBySource = new Map<string, string[]>();
    for (const r of ledgerRecordsSafe(vault.path)) pagesBySource.set(r.locator, r.pages);
    const files = (record?.sources.map((s) => s.file) ?? readableSources(vault.path, job.files)).filter(
      (f) => !stopped.has(f) && !(pagesBySource.get(f) ?? []).some((p) => done.has(p)),
    );
    freshSession(id, record, files, 'the session isn’t available any more');
  }

  /** Before the decision of an unread or covered part: what must not be in it (pages and ledger records). */
  function excludedOf(job: Job): { files: string[]; sha256: string[] } {
    const part = job.pendingPart;
    if (!part?.bundlePath) return { files: [], sha256: [] };
    try {
      const v = JSON.parse(fs.readFileSync(path.join(path.dirname(part.bundlePath), `${path.basename(part.bundlePath, '.json')}-excluded.json`), 'utf8')) as { files?: string[]; sha256?: string[] };
      return { files: v.files ?? [], sha256: v.sha256 ?? [] };
    } catch {
      return { files: (job.stopped ?? []).map((s) => s.file), sha256: (job.stopped ?? []).flatMap((s) => (s.sha256 ? [s.sha256] : [])) };
    }
  }

  // ───────────── after an apply ─────────────

  /** Pages applied: each source whose page applied and that was read in full is recorded by its sha256. */
  function recordApplied(job: Job, pagesApplied: string[], bundlePath?: string): void {
    const jobDir = jobStateDirectory(job);
    const record = loadRecord(jobDir);
    if (!record) return;
    const vault = d.vaultProfileFor(job);
    const b = bundlePath ? readBundle(bundlePath) : undefined;
    const pages = b ? sourcePages(b) : [];
    const files = record.sources.map((s) => s.file);
    const cov = computeCoverage(record, { vaultPath: vault.path, drafts: draftsOf(b, pages, files, vault.path) });
    const applied = new Set(pagesApplied);
    const ledger = ledgerRecordsSafe(vault.path);
    for (const c of cov) {
      const s = record.sources.find((x) => x.file === c.file)!;
      const sourcePagesOf = pages.filter((p) => sourceOf(p, files, vault.path) === c.file).map((p) => p.page);
      const ledgerPages = ledger.find((r) => r.sha256 === s.sha256)?.pages ?? [];
      const mine = [...new Set([...sourcePagesOf, ...ledgerPages])].filter((p) => applied.has(p));
      if (mine.length === 0 || !s.sha256) continue;
      if (!ledger.some((r) => r.sha256 === s.sha256)) continue;
      index.record(s.sha256, { full: c.full, file: c.file, lines: c.required, jobId: job.id, at: isoDate(d.now()), pages: mine });
    }
  }

  /**
   * At start: coverage of past batches from their saved stream turns. A source counts only when the
   * job is completed with an operation ID, its page is in an applied part (or the applied plan's
   * changed paths when it has no parts), and the bytes read still equal the ledger's content_sha256.
   * Jobs still running or in Review are skipped; their pages are recorded when they apply.
   */
  function backfill(): number {
    let added = 0;
    for (const job of d.jobs()) {
      if (job.kind !== 'ingest' || job.state !== 'completed' || !job.operationID) continue;
      const vault = d.vaultProfileFor(job);
      const jobDir = jobStateDirectory(job);
      const applied = new Set(job.parts?.length ? job.parts.flatMap((p) => p.pages) : job.changedPaths);
      if (applied.size === 0) continue;
      const ledger = ledgerRecordsSafe(vault.path);
      const files = readableSources(vault.path, job.files).filter((f) => sourceKind(f) === 'text');
      const candidates = files.flatMap((f) => {
        const sha = sha256File(path.join(vault.path, f));
        if (!sha || index.isFull(sha)) return [];
        const rec = ledger.find((r) => r.sha256 === sha && (r.locator === f || r.locator.startsWith('.raw/captured/')));
        if (!rec || !rec.pages.some((p) => applied.has(p))) return [];
        return [{ file: f, sha, pages: rec.pages.filter((p) => applied.has(p)) }];
      });
      if (candidates.length === 0) continue;
      let turnFiles: string[];
      try {
        turnFiles = fs.readdirSync(jobDir).filter((n) => /^turn-\d+\.json$/.test(n)).sort((a, b) => Number(a.slice(5, -5)) - Number(b.slice(5, -5)));
      } catch {
        continue;
      }
      if (turnFiles.length === 0) continue;
      // Copies are not on disk for these jobs: the record counts the original lines (image lines left out).
      const copies = candidates.map((c) => {
        const rc = makeReadingCopy(vault.path, c.file, path.join(jobDir, 'backfill'), candidates.indexOf(c) + 1);
        return rc;
      });
      const record = newRecord(job.sessionID, copies);
      for (const s of record.sources) delete s.copy;
      for (const s of record.sources) s.lines = s.sourceLines;
      for (const t of turnFiles) {
        let raw = '';
        try {
          raw = fs.readFileSync(path.join(jobDir, t), 'utf8');
        } catch {
          continue;
        }
        const parsed = parseTurn(raw, record.seq, record.lastContext);
        record.events.push(...parsed.events);
        record.seq = parsed.nextSeq;
        record.lastContext = parsed.lastContext;
      }
      const cov = computeCoverage(record, { vaultPath: vault.path });
      for (const c of cov) {
        const cand = candidates.find((x) => x.file === c.file);
        if (!cand || !c.full) continue;
        index.record(cand.sha, { full: true, file: c.file, lines: c.required, jobId: job.id, at: isoDate(d.now()), pages: cand.pages, backfilled: true });
        added += 1;
      }
      try {
        fs.rmSync(path.join(jobDir, 'backfill'), { recursive: true, force: true });
      } catch {
        /* a scratch copy */
      }
    }
    if (added > 0) d.log('info', `Full reads: ${plural(added, 'source')} of past batches were read in full (from their saved steps).`);
    return added;
  }

  // ───────────── the automatic repair ─────────────

  /** Sources a live job holds (running or in Review, including a pending part): by path and by sha256. */
  function heldByLiveJobs(vaultPath: string): { files: Set<string>; shas: Set<string> } {
    const files = new Set<string>();
    const shas = new Set<string>();
    for (const j of d.jobs()) {
      if (j.vaultPath !== vaultPath || isFinished(j.state)) continue;
      for (const f of j.files) files.add(f);
      const r = loadRecord(jobStateDirectory(j));
      for (const s of r?.sources ?? []) if (s.sha256) shas.add(s.sha256);
      for (const s of j.stopped ?? []) if (s.sha256) shas.add(s.sha256);
    }
    for (const f of d.waitingRereadFiles(vaultPath)) files.add(f);
    return { files, shas };
  }

  let scanning = false;
  /**
   * Every source-ledger entry whose content has no full read on record is read again, through the
   * re-read entry point, packed by tokens, one batch at a time (the next starts when the previous
   * applies). Never twice for the same content; never while a live job holds it.
   */
  async function repairScan(vault: VaultProfile, o: { force?: boolean } = {}): Promise<RereadResult | undefined> {
    if (scanning) return undefined;
    const s = d.settings();
    if (!s.autoProcessEnabled) return undefined;
    const today = isoDate(d.now()).slice(0, 10);
    if (!o.force && repairs.lastScan[vault.path] === today) return undefined;
    scanning = true;
    try {
      repairs.lastScan[vault.path] = today;
      repairs.save();
      const ledger = ledgerRecordsSafe(vault.path).filter((r) => r.kind.toLowerCase() === 'file' && r.sha256);
      const live = heldByLiveJobs(vault.path);
      const stoppedShas = new Set(d.jobs().flatMap((j) => (j.stopped ?? []).flatMap((x) => (x.sha256 ? [x.sha256] : []))));
      const files: string[] = [];
      const missing: string[] = [];
      const shaOf = new Map<string, string>();
      for (const r of ledger) {
        const sha = r.sha256!;
        if (index.isFull(sha) || repairs.tried(sha) || stoppedShas.has(sha) || live.shas.has(sha) || live.files.has(r.locator)) continue;
        if (shaOf.has(sha)) continue;
        const archived = archivedCopy(vault.path, sha);
        let file: string | undefined;
        if (archived) file = archived;
        else if (r.locator.startsWith('inbox/') && sha256File(path.join(vault.path, r.locator)) === sha) file = r.locator;
        if (!file) {
          missing.push(r.locator);
          continue;
        }
        if (live.files.has(file)) continue;
        files.push(file);
        shaOf.set(sha, file);
      }
      if (files.length === 0) {
        if (missing.length > 0) d.log('warn', `Full reads: ${plural(missing.length, 'source')} never read in full can't be re-read: the original is missing (${missing.slice(0, 5).join(', ')}).`);
        return undefined;
      }
      const res = await d.rereadSources({ vaultPath: vault.path, files, reason: 'repair' });
      for (const [sha, file] of shaOf) repairs.add(sha, { at: isoDate(d.now()), file, rereadId: res.id });
      repairs.save();
      d.emit({ type: 'repair.queued', vaultPath: vault.path, rereadId: res.id, sources: files.length, batches: res.groups.length, files, ...(missing.length ? { missing } : {}) });
      d.log('info', `Full reads: ${plural(files.length, 'source')} weren't checked for a full read; reading them again in ${plural(res.groups.length, 'batch', 'batches')}.`);
      return res;
    } catch (err) {
      d.log('warn', `Full reads: the repair scan stopped: ${(err as Error).message}`);
      return undefined;
    } finally {
      scanning = false;
    }
  }

  // ───────────── held sources ─────────────

  function listHeld(vaultPath: string): HeldSource[] {
    const out: HeldSource[] = [];
    const seen = new Set<string>();
    for (const j of d.jobs()) {
      if (j.vaultPath !== vaultPath) continue;
      for (const s of j.stopped ?? []) {
        if (seen.has(s.file)) continue;
        if (s.sha256 && index.isFull(s.sha256)) continue;
        const abs = path.join(vaultPath, s.file);
        let size: number | undefined;
        try {
          size = fs.statSync(abs).size;
        } catch {
          continue; // removed by the owner
        }
        const now = sha256File(abs);
        if (now && index.isFull(now)) continue;
        seen.add(s.file);
        out.push({ ...s, jobId: j.id, ...(size !== undefined ? { size } : {}) });
      }
    }
    return out;
  }

  return {
    coverageOn,
    budget,
    prepare,
    gate,
    startUnreadPart,
    autoContinueRefused,
    excludedOf,
    recordApplied,
    backfill,
    repairScan,
    listHeld,
    heldByLiveJobs,
    index,
    estimate: (abs: string) => estimateTokens(abs),
  };
}

export type FullRead = ReturnType<typeof createFullRead>;
