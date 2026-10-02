import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs, type ParseArgsConfig } from 'node:util';
import type {
  ActionItem,
  AddNoteRequest,
  AddNoteResult,
  AskConversation,
  AskConversationSummary,
  AskRequest,
  AskResponse,
  ModelSelection,
  NoteImage,
  Progress,
  Settings,
  StatusResponse,
} from '@distill/core/contracts';
import { ServerAlreadyRunningError, runServer, statePaths, type ServerLock } from '@distill/core/server';
import { CliError, connect, usageError, type EventStream, type ServerSpawner } from './client.js';
import { defaultPluginDir, installPlugin, type PluginInstallResult } from './plugin-install.js';

export interface CliIO {
  stdout(text: string): void;
  stderr(text: string): void;
  env: NodeJS.ProcessEnv;
  cwd: string;
  readStdin(): Promise<string>;
  /** Override how a missing server is started (tests). */
  spawner?: ServerSpawner;
  /** Override how `plugin install --target claude` runs commands (tests). */
  runCommand?: (argv: string[]) => number | null;
  /** stdout is a terminal: `ask` shows a live status line on stderr (never with --json). */
  isTTY?: boolean;
  /** Install a Ctrl-C handler; returns its remover. Default: SIGINT (a second Ctrl-C exits at once). */
  onInterrupt?: (handler: () => void) => () => void;
}

/** SIGINT: the first press calls the handler, a second one exits with 130. */
function onSigint(handler: () => void): () => void {
  let pressed = 0;
  const listener = () => {
    pressed += 1;
    if (pressed > 1) process.exit(130);
    handler();
  };
  process.on('SIGINT', listener);
  return () => process.off('SIGINT', listener);
}

export function defaultIO(): CliIO {
  return {
    stdout: (t) => process.stdout.write(t),
    stderr: (t) => process.stderr.write(t),
    env: process.env,
    cwd: process.cwd(),
    readStdin: async () => {
      const chunks: Buffer[] = [];
      for await (const c of process.stdin) chunks.push(c as Buffer);
      return Buffer.concat(chunks).toString('utf8');
    },
    isTTY: process.stdout.isTTY === true,
    onInterrupt: onSigint,
  };
}

export function cliVersion(): string {
  try {
    const pkg = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version?: string };
    return pkg.version ?? '0.0.0';
  } catch {
    return '0.0.0';
  }
}

export const HELP = `distill: ask your notes and queue new ones for Distill

Usage:
  distill ask "<question>" [--label L]... [--match any|all] [--unconfirmed include|exclude]
              [--source S]... [--runner R] [--model M] [--effort E] [--conversation ID]
              [--vault PATH] [--json]
  distill note add --title T [--text "..." | --file PATH | -] [--image PATH[:extract|:keep]]...
              [--source S] [--ref "..."] [--label L]... [--no-suggest] [--vault PATH] [--json]
  distill note label <request-id> --label L... [--json]
  distill history [--json]
  distill history show <conversation-id> [--json]
  distill history rm <conversation-id> [--json]
  distill status [--json]
  distill actions list [--type T] [--history] [--json]
  distill actions add "<title>" [--type todo] [--body "..."] [--why "..."] [--due YYYY-MM-DD]
              [--vault PATH] [--json]
  distill serve [--port N]
  distill plugin install --target claude|codex [--dry-run] [--copy] [--force] [--json]
  distill --help | --version

Commands:
  ask           Answer a question from your vault, with numbered citations and gaps.
                Read-only. Default scope is all notes; --label/--source narrow it.
                --runner/--model/--effort override the "ask" defaults from settings
                (effort: low | medium | high | xhigh | max). --conversation ID continues
                a previous answer's conversation. "-" as the question reads stdin.
                --match any (a note with at least one --label) or all (every --label);
                --unconfirmed include|exclude decides whether AI labels nobody has
                confirmed yet count. Both default to the user's Ask settings.
                Notices (e.g. a new session because the filter changed) are printed
                above the answer, or returned as "notices" with --json.
                In a terminal a live status line on stderr says what it is doing
                ("Reading your notes…", runner · model, elapsed time); never with --json.
                Ctrl-C stops the answer (the question is not saved; exit code 130);
                a second Ctrl-C quits at once. A new chat's ID is chosen by the CLI.
  note add      Queue a written note (text, images, source) for Distill to ingest.
                Text comes from --text, --file PATH, or "-" (stdin). --image may repeat;
                ":keep" (default) stores the image in the vault, ":extract" reads its
                text into the note without storing it. Nothing is written to the vault
                until a person approves the change in the Distill app.
                Labels: --label L (repeatable) sets the labels yourself and skips AI
                suggestions. Without --label, Distill suggests labels and waits for
                them (a short model call), then prints them with the request ID and the
                \`distill note label\` command that confirms your choice. --no-suggest
                skips the suggestion. Notes added here with no labels sent back before
                the next batch get the AI labels marked unconfirmed (if enabled in
                Settings → Labels).
  note label    Set the labels of a note added with \`note add\`, by its request ID,
                while it is still in the queue (afterwards: error invalid_state).
                Replaces any labels sent before; a leading "#" is dropped.
  history       List past Ask conversations (newest first; pinned ones are kept).
                \`history show ID\` prints every question and answer; \`history rm ID\`
                deletes one. Continue one with \`distill ask --conversation ID\`.
  status       Server, active vault, queue size, reviews waiting, runner problems.
  actions list  List open actions (to-dos, Slack messages, Jira tickets, Confluence pages),
                including found ones waiting for the user to confirm ("to confirm").
                --type narrows to one type; --history adds done, sent and removed items.
  actions add   Add a to-do (or, with --type, an item of another enabled type) by hand.
                It is added for the user; nothing is sent or created outside Distill.
  serve         Run the Distill core server in the foreground (one per user).
  plugin install
                Install the distill-ask and distill-note agent skills.
                --target claude: runs \`claude plugin marketplace add <plugin dir>\` and
                \`claude plugin install distill@distill-local\`.
                --target codex: links each skill into ~/.agents/skills/<name>
                (--copy copies instead; --force replaces existing entries).
                --dry-run prints the actions without doing them.

Approval stays with a person: this CLI has no approve, apply, reply or reject
commands, and no confirm-labels command. Review queued changes, and confirm AI
labels on pages already in the vault, in the Distill app (or another UI client).
Likewise there is no command to confirm, complete, send or create actions: found
actions are confirmed, and Jira/Confluence items created, only by the user.
\`note label\` only sets the labels of a note that is still in the queue.

Other commands start the server in the background when it is not running
(log: <state dir>/server.log). State dir: ~/Library/Application Support/Distill,
or $DISTILL_STATE_DIR.

--json output (one JSON document on stdout):
  ask       {"conversationID", "answer", "citations": [{"n","path","title"}], "gaps": [..],
             "selection": {"runnerID","model","effort"}, "costUSD", "notices"?: [..]}
  note add  {"notePath", "queued": [absolute paths], "requestID",
             "suggestedLabels"?: [{"name","existing"}],  (existing false = a new label)
             "suggestError"?: "why there are no suggestions"}
  note label
            {"notePath", "labels": [..]}
  history   {"conversations": [{"id","title","vaultPath","createdAt","updatedAt","pinned","turnCount"}]}
  history show
            {"id","title","vaultPath","createdAt","updatedAt","pinned","turnCount",
             "turns": [{"askedAt", "request": {ask request}, "response": {ask --json shape}}]}
  history rm
            {"id", "deleted": true}
  status    {"version", "activeVault": {"path","queueDirectory"}|null, "problems": [{"code","message"}],
             "queueCount", "pendingApprovals", "runningJobs", "nextBatchAt",
             "runners": [{"id","displayName","enabled","problems"}],
             "server": {"pid","port","startedAt","version"}}
  actions list
            {"actions": [{"id","type","status","title","body","fields","why","source",
             "createdAt","updatedAt","events", ...}]}
  actions add
            {the new action, same shape}
  plugin install
            {"target", "dryRun", "pluginDir", "actions": [{"action","skill","source","destination","command"}],
             "notes": [..]}
  errors    {"error": {"code", "message"}}  (also with exit code 1 or 2; "stopped" with 130)

Exit codes: 0 success, 1 error, 2 usage error, 130 stopped with Ctrl-C.
`;

type Values = Record<string, string | boolean | (string | boolean)[] | undefined>;

function parse(args: string[], options: ParseArgsConfig['options']): { values: Values; positionals: string[] } {
  // `--text "- a bullet"`: a string option always takes the next token, even one starting
  // with "-" (parseArgs alone rejects that as ambiguous). Rewrite to `--text=- a bullet`.
  const normalized: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const a = args[i]!;
    if (a === '--') {
      normalized.push(...args.slice(i));
      break;
    }
    const name = a.startsWith('--') && !a.includes('=') ? a.slice(2) : undefined;
    if (name && options?.[name]?.type === 'string' && i + 1 < args.length) {
      normalized.push(`${a}=${args[++i]!}`);
    } else {
      normalized.push(a);
    }
  }
  args = normalized;
  try {
    const r = parseArgs({ args, options: { ...options, json: { type: 'boolean' }, help: { type: 'boolean', short: 'h' } }, allowPositionals: true, strict: true });
    return { values: r.values as Values, positionals: r.positionals };
  } catch (err) {
    throw usageError((err as Error).message);
  }
}

const str = (v: Values[string]): string | undefined => (typeof v === 'string' ? v : undefined);
const strs = (v: Values[string]): string[] => (Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);

class Output {
  constructor(
    private io: CliIO,
    readonly json: boolean,
  ) {}
  result(data: unknown, human: () => string): void {
    this.io.stdout(this.json ? JSON.stringify(data, null, 2) + '\n' : human());
  }
  info(text: string): void {
    this.io.stderr(text + '\n');
  }
}

/** Run the CLI; returns the exit code. */
export async function run(argv: string[], io: CliIO = defaultIO()): Promise<number> {
  const wantsJSON = argv.includes('--json');
  try {
    return await dispatch(argv, io);
  } catch (err) {
    const e = err instanceof CliError ? err : new CliError((err as Error).message ?? String(err));
    if (wantsJSON) io.stdout(JSON.stringify({ error: { code: e.code, message: e.message } }) + '\n');
    else io.stderr(`distill: ${e.message}${e.exitCode === 2 ? '\nRun `distill --help` for usage.' : ''}\n`);
    return e.exitCode;
  }
}

async function dispatch(argv: string[], io: CliIO): Promise<number> {
  const [command, ...rest] = argv;
  if (command === undefined || command === '--help' || command === '-h' || command === 'help') {
    io.stdout(HELP);
    return command === undefined ? 2 : 0;
  }
  if (command === '--version' || command === '-v' || command === 'version') {
    io.stdout(`distill ${cliVersion()}\n`);
    return 0;
  }
  if (rest.includes('--help') || rest.includes('-h')) {
    io.stdout(HELP);
    return 0;
  }
  const paths = statePaths(io.env.DISTILL_STATE_DIR ?? path.join(io.env.HOME ?? os.homedir(), "Library", "Application Support", "Distill"));
  const api = async (out: Output) =>
    connect({ paths, env: io.env, spawner: io.spawner, onStart: (m) => (out.json ? undefined : out.info(m)) });

  switch (command) {
    case 'ask':
      return ask(rest, io, api);
    case 'note':
      return note(rest, io, api);
    case 'history':
      return history(rest, io, api);
    case 'status':
      return status(rest, io, api);
    case 'actions':
      return actions(rest, io, api);
    case 'serve':
      return serve(rest, io, paths);
    case 'plugin':
      return plugin(rest, io);
    default:
      throw usageError(`unknown command "${command}"`);
  }
}

type ApiFactory = (out: Output) => ReturnType<typeof connect>;

// ───────────────────────────── ask ─────────────────────────────

async function ask(args: string[], io: CliIO, api: ApiFactory): Promise<number> {
  const { values, positionals } = parse(args, {
    label: { type: 'string', multiple: true },
    source: { type: 'string', multiple: true },
    runner: { type: 'string' },
    model: { type: 'string' },
    effort: { type: 'string' },
    conversation: { type: 'string' },
    vault: { type: 'string' },
    match: { type: 'string' },
    unconfirmed: { type: 'string' },
  });
  const out = new Output(io, values.json === true);
  const match = str(values.match);
  if (match !== undefined && match !== 'any' && match !== 'all') throw usageError('--match must be "any" or "all"');
  const unconfirmed = str(values.unconfirmed);
  if (unconfirmed !== undefined && unconfirmed !== 'include' && unconfirmed !== 'exclude') {
    throw usageError('--unconfirmed must be "include" or "exclude"');
  }
  let question = positionals.join(' ').trim();
  if (question === '-') question = (await io.readStdin()).trim();
  if (!question) throw usageError('ask needs a question, e.g. distill ask "How hot for sencha?"');

  const req: AskRequest = { question };
  const labels = labelArgs(values.label);
  const sources = strs(values.source);
  if (labels.length) req.labels = labels;
  if (sources.length) req.sources = sources;
  // Omitted flags leave the fields out so the server applies the user's Ask settings.
  if (match) req.labelMatch = match;
  if (unconfirmed) req.includeUnconfirmed = unconfirmed === 'include';
  const conversation = str(values.conversation);
  if (conversation) req.conversationID = conversation;
  const vault = str(values.vault);
  if (vault) req.vaultPath = path.resolve(io.cwd, vault);

  const client = await api(out);
  const runner = str(values.runner);
  const model = str(values.model);
  const effort = str(values.effort);
  if (runner || model || effort) {
    const settings = await client.request<Settings>('GET', '/v1/settings');
    const base: ModelSelection = settings.taskDefaults?.ask ?? { runnerID: 'claude-code', model: settings.model };
    if (runner && runner !== base.runnerID && !model) {
      throw usageError(`--model is required with --runner ${runner} (the default model belongs to ${base.runnerID})`);
    }
    req.selection = {
      runnerID: runner ?? base.runnerID,
      model: model ?? base.model,
      ...(effort ? { effort } : base.effort !== undefined ? { effort: base.effort } : {}),
    };
  }

  // A new chat gets its id up front, so Ctrl-C can stop the turn (POST /v1/conversations/:id/cancel).
  req.conversationID ??= randomUUID();
  const conversationID = req.conversationID;
  const status = io.isTTY && !out.json ? new StatusLine(io, `ask:${conversationID}`) : undefined;
  let events: EventStream | undefined;
  if (status) events = await client.events((e) => (e.type === 'progress' ? status.update(e.progress) : undefined)).catch(() => undefined);
  let stopping = false;
  const removeInterrupt = (io.onInterrupt ?? (() => () => undefined))(() => {
    if (stopping) return;
    stopping = true;
    status?.stopping();
    if (!status) io.stderr('Stopping…\n');
    void client.request('POST', `/v1/conversations/${encodeURIComponent(conversationID)}/cancel`).catch(() => undefined);
  });
  let res: AskResponse;
  try {
    res = await client.request<AskResponse>('POST', '/v1/ask', req);
  } catch (err) {
    if (stopping && err instanceof CliError && err.code === 'invalid_state') throw new CliError('Stopped. Your question was not saved.', 'stopped', 130);
    throw err;
  } finally {
    removeInterrupt();
    events?.close();
    status?.clear();
  }
  out.result(res, () => {
    const lines = (res.notices ?? []).map((n) => `Note: ${n}`);
    if (lines.length) lines.push('');
    lines.push(...formatAnswer(res));
    const sel = `${res.selection.runnerID} · ${res.selection.model}${res.selection.effort ? ` · ${res.selection.effort}` : ''}`;
    lines.push(`(${sel} · $${res.costUSD.toFixed(4)} · follow up with --conversation ${res.conversationID})`);
    return lines.join('\n') + '\n';
  });
  return 0;
}

/** One self-rewriting stderr line for an Ask turn: what it is doing, which model, elapsed time after 3 s. */
class StatusLine {
  private progress: Progress | undefined;
  private timer: NodeJS.Timeout | undefined;
  private frame = 0;
  private note: string | undefined;
  private shown = false;

  constructor(
    private io: CliIO,
    private key: string,
  ) {
    this.timer = setInterval(() => this.render(), 1000);
    this.timer.unref();
    this.render();
  }

  update(p: Progress): void {
    if (p.key !== this.key) return;
    this.progress = p.finished ? undefined : p;
    if (p.finished) this.clear();
    else this.render();
  }

  stopping(): void {
    this.note = 'Stopping…';
    this.render();
  }

  clear(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    if (this.shown) this.io.stderr('\r\x1b[2K');
    this.shown = false;
  }

  private render(): void {
    if (!this.timer) return;
    const p = this.progress;
    const spinner = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'[this.frame++ % 10];
    const parts = [this.note ?? `${p?.message ?? 'Asking'}…`];
    if (p?.model) parts.push(p.runnerID ? `${p.runnerID} · ${p.model}` : p.model);
    if (p) {
      const secs = Math.max(0, Math.floor((Date.now() - Date.parse(p.startedAt)) / 1000));
      if (secs >= 3) parts.push(`${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`);
      if (secs >= 60 && !this.note) parts[0] = `Still working: ${parts[0]}`;
    }
    parts.push('Ctrl-C to stop');
    this.io.stderr(`\r\x1b[2K${spinner} ${parts.join(' · ')}`);
    this.shown = true;
  }
}

function formatAnswer(res: AskResponse): string[] {
  const lines = [res.answer.trimEnd(), ''];
  if (res.citations.length) {
    lines.push('Sources:');
    for (const c of res.citations) lines.push(`  [${c.n}] ${c.title} (${c.path})`);
    lines.push('');
  }
  if (res.gaps.length) {
    lines.push('Not covered by your notes:');
    for (const g of res.gaps) lines.push(`  - ${g}`);
    lines.push('');
  }
  return lines;
}

/** --label values: a leading "#" dropped, empty ones rejected, duplicates removed. */
function labelArgs(v: Values[string]): string[] {
  const out: string[] = [];
  for (const raw of strs(v)) {
    const name = raw.trim().replace(/^#/, '').trim();
    if (!name) throw usageError('--label needs a name');
    if (!out.includes(name)) out.push(name);
  }
  return out;
}

// ───────────────────────────── note add ─────────────────────────────

export function parseImage(spec: string, cwd: string): NoteImage {
  let file = spec;
  let mode: NoteImage['mode'] = 'keep';
  const m = /^(.*):(extract|keep)$/.exec(spec);
  if (m) {
    file = m[1]!;
    mode = m[2] as NoteImage['mode'];
  }
  if (!file) throw usageError(`--image needs a path, got "${spec}"`);
  const abs = path.resolve(cwd, file);
  let stat: fs.Stats;
  try {
    stat = fs.statSync(abs);
  } catch {
    throw new CliError(`image not found: ${abs}`, 'file_not_found');
  }
  if (!stat.isFile()) throw new CliError(`image is not a file: ${abs}`, 'file_not_found');
  return { path: abs, mode };
}

async function note(args: string[], io: CliIO, api: ApiFactory): Promise<number> {
  const [sub, ...rest] = args;
  if (sub === 'label') return noteLabel(rest, io, api);
  if (sub !== 'add') {
    throw usageError(sub ? `unknown note command "${sub}" (use "note add" or "note label")` : 'usage: distill note add --title T ... | distill note label <request-id> --label L');
  }
  const { values, positionals } = parse(rest, {
    title: { type: 'string' },
    text: { type: 'string' },
    file: { type: 'string' },
    image: { type: 'string', multiple: true },
    source: { type: 'string' },
    ref: { type: 'string' },
    vault: { type: 'string' },
    label: { type: 'string', multiple: true },
    'no-suggest': { type: 'boolean' },
  });
  const out = new Output(io, values.json === true);
  const title = str(values.title)?.trim();
  if (!title) throw usageError('note add needs --title');
  const stdin = positionals.length === 1 && positionals[0] === '-';
  if (positionals.length > 0 && !stdin) throw usageError(`unexpected argument "${positionals[0]}" (use --text, --file or -)`);
  const textSources = [values.text !== undefined, values.file !== undefined, stdin].filter(Boolean).length;
  if (textSources > 1) throw usageError('give the text once: --text, --file or - (stdin)');

  let text = str(values.text) ?? '';
  const file = str(values.file);
  if (file) {
    const abs = path.resolve(io.cwd, file);
    try {
      text = fs.readFileSync(abs, 'utf8');
    } catch {
      throw new CliError(`cannot read ${abs}`, 'file_not_found');
    }
  }
  if (stdin) text = await io.readStdin();

  const images = strs(values.image).map((s) => parseImage(s, io.cwd));
  if (!text.trim() && images.length === 0) throw usageError('a note needs text (--text, --file or -) or at least one --image');

  const req: AddNoteRequest = { title, text };
  if (images.length) req.images = images;
  const source = str(values.source);
  const ref = str(values.ref);
  const vault = str(values.vault);
  if (source) req.source = source;
  if (ref) req.sourceRef = ref;
  if (vault) req.vaultPath = path.resolve(io.cwd, vault);
  const labels = labelArgs(values.label);
  req.origin = 'cli';
  if (labels.length) {
    req.labels = labels;
    req.suggest = 'none';
  } else {
    req.suggest = values['no-suggest'] === true ? 'none' : 'wait';
  }

  const client = await api(out);
  const res = await client.request<AddNoteResult>('POST', '/v1/notes', req);
  out.result(res, () => {
    const kept = images.filter((i) => i.mode === 'keep').length;
    const extracted = images.length - kept;
    const parts = [kept ? `${kept} image${kept > 1 ? 's' : ''} kept` : '', extracted ? `${extracted} read as text` : ''].filter(Boolean);
    const lines = [`Queued "${title}"${parts.length ? ` (${parts.join(', ')})` : ''}: ${res.notePath}`, `Request ID: ${res.requestID}`];
    const label = (names: string[]) => ['distill', 'note', 'label', res.requestID, ...names.flatMap((n) => ['--label', n])].map(shellQuote).join(' ');
    if (labels.length) {
      lines.push(`Labels: ${labels.join(', ')}`);
    } else if (res.suggestedLabels?.length) {
      lines.push(`Suggested labels: ${res.suggestedLabels.map((l) => (l.existing ? l.name : `${l.name} (new)`)).join(', ')}`);
      lines.push(`Keep them (edit the list as you like): ${label(res.suggestedLabels.map((l) => l.name))}`);
    } else {
      if (res.suggestError) lines.push(`No label suggestions: ${res.suggestError}`);
      else if (req.suggest === 'wait') lines.push('No label suggestions.');
      lines.push(`Set labels: ${label([])} --label <label>`);
    }
    lines.push('Distill will ingest it in the next batch; the vault changes only after you approve them in the Distill app.');
    return lines.join('\n') + '\n';
  });
  return 0;
}

async function noteLabel(args: string[], io: CliIO, api: ApiFactory): Promise<number> {
  const { values, positionals } = parse(args, { label: { type: 'string', multiple: true } });
  const out = new Output(io, values.json === true);
  const [requestID, extra] = positionals;
  if (!requestID?.trim()) throw usageError('usage: distill note label <request-id> --label L...');
  if (extra !== undefined) throw usageError(`unexpected argument "${extra}"`);
  const labels = labelArgs(values.label);
  if (!labels.length) throw usageError('note label needs at least one --label');
  const client = await api(out);
  const res = await client.request<{ notePath: string; labels: string[] }>(
    'POST',
    `/v1/notes/${encodeURIComponent(requestID.trim())}/labels`,
    { labels },
  );
  out.result(res, () => `Labels for ${res.notePath}: ${res.labels.join(', ')}\nThey apply when Distill ingests the note (after you approve it in the Distill app).\n`);
  return 0;
}

// ───────────────────────────── history ─────────────────────────────

async function history(args: string[], io: CliIO, api: ApiFactory): Promise<number> {
  const sub = args[0] === 'show' || args[0] === 'rm' ? args[0] : undefined;
  const { values, positionals } = parse(sub ? args.slice(1) : args, {});
  const out = new Output(io, values.json === true);
  if (!sub) {
    if (positionals.length) throw usageError(`unknown history command "${positionals[0]}" (use "history", "history show ID" or "history rm ID")`);
    const client = await api(out);
    const res = await client.request<{ conversations: AskConversationSummary[] }>('GET', '/v1/conversations');
    out.result(res, () => {
      if (!res.conversations.length) return 'No saved Ask conversations.\n';
      const lines = res.conversations.map(
        (c) => `${c.id}  ${c.updatedAt}  ${c.turnCount} question${c.turnCount === 1 ? '' : 's'}${c.pinned ? '  pinned' : ''}  ${c.title}`,
      );
      lines.push('', 'Show one: distill history show <id>   Continue: distill ask "..." --conversation <id>');
      return lines.join('\n') + '\n';
    });
    return 0;
  }
  const [id, extra] = positionals;
  if (!id?.trim()) throw usageError(`usage: distill history ${sub} <conversation-id>`);
  if (extra !== undefined) throw usageError(`unexpected argument "${extra}"`);
  const client = await api(out);
  const p = `/v1/conversations/${encodeURIComponent(id.trim())}`;
  if (sub === 'rm') {
    const res = await client.request<{ id: string; deleted: boolean }>('DELETE', p);
    out.result(res, () => `Deleted conversation ${res.id}.\n`);
    return 0;
  }
  const c = await client.request<AskConversation>('GET', p);
  out.result(c, () => {
    const lines = [`${c.title}`, `${c.id} · ${c.vaultPath} · ${c.createdAt} → ${c.updatedAt}${c.pinned ? ' · pinned' : ''}`, ''];
    c.turns.forEach((t, i) => {
      lines.push(`Q${i + 1} (${t.askedAt}): ${t.request.question}`, '');
      lines.push(...formatAnswer(t.response));
    });
    lines.push(`Continue: distill ask "..." --conversation ${shellQuote(c.id)}`);
    return lines.join('\n') + '\n';
  });
  return 0;
}

// ───────────────────────────── actions ─────────────────────────────

async function actions(args: string[], io: CliIO, api: ApiFactory): Promise<number> {
  const [sub, ...rest] = args;
  if (sub === 'list') {
    const { values, positionals } = parse(rest, { type: { type: 'string' }, history: { type: 'boolean' } });
    if (positionals.length) throw usageError(`unexpected argument "${positionals[0]}"`);
    const out = new Output(io, values.json === true);
    const query = new URLSearchParams();
    const type = str(values.type);
    if (type) query.set('type', type);
    if (values.history === true) query.set('history', '1');
    const client = await api(out);
    const qs = query.toString();
    const res = await client.request<{ actions: ActionItem[] }>('GET', `/v1/actions${qs ? `?${qs}` : ''}`);
    out.result(res, () => {
      if (!res.actions.length) return type ? `No ${type} actions.\n` : 'No actions.\n';
      const lines = res.actions.map((a) => {
        const due = a.fields.due ? `  due ${a.fields.due}` : '';
        const where = a.source.kind === 'note' && a.source.notePath ? `  (${a.source.notePath})` : a.source.kind === 'ask' ? '  (Ask)' : '';
        return `${a.id}  ${a.type}  ${a.status === 'pending' ? 'to confirm' : a.status}  ${a.title}${due}${where}`;
      });
      return lines.join('\n') + '\n';
    });
    return 0;
  }
  if (sub === 'add') {
    const { values, positionals } = parse(rest, {
      type: { type: 'string' },
      body: { type: 'string' },
      why: { type: 'string' },
      due: { type: 'string' },
      vault: { type: 'string' },
    });
    const [title, extra] = positionals;
    if (!title?.trim()) throw usageError('usage: distill actions add "<title>" [--type todo] [--body "..."] [--due YYYY-MM-DD]');
    if (extra !== undefined) throw usageError(`unexpected argument "${extra}"`);
    const due = str(values.due);
    if (due !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(due)) throw usageError('--due must be a date like 2026-10-05');
    const out = new Output(io, values.json === true);
    const body: Record<string, unknown> = { type: str(values.type) ?? 'todo', title: title.trim(), source: { kind: 'manual', by: 'agent' } };
    if (str(values.body) !== undefined) body.body = str(values.body);
    if (str(values.why) !== undefined) body.why = str(values.why);
    if (due) body.fields = { due };
    if (str(values.vault)) body.vaultPath = path.resolve(io.cwd, str(values.vault)!);
    const client = await api(out);
    const item = await client.request<ActionItem>('POST', '/v1/actions', body);
    out.result(item, () => `Added ${item.type === 'todo' ? 'to-do' : item.type} ${item.id}: ${item.title}\nComplete, send or remove it in the Distill app (Actions).\n`);
    return 0;
  }
  throw usageError(sub ? `unknown actions command "${sub}" (use "actions list" or "actions add")` : 'usage: distill actions list | add "<title>"');
}

// ───────────────────────────── status ─────────────────────────────

async function status(args: string[], io: CliIO, api: ApiFactory): Promise<number> {
  const { values, positionals } = parse(args, {});
  if (positionals.length) throw usageError(`unexpected argument "${positionals[0]}"`);
  const out = new Output(io, values.json === true);
  const client = await api(out);
  const s = await client.request<StatusResponse>('GET', '/v1/status');
  const server: ServerLock = client.lock;
  out.result({ ...s, server }, () => formatStatus(s, server));
  return 0;
}

function formatStatus(s: StatusResponse, server: ServerLock): string {
  const lines = [`Distill ${s.version} · server pid ${server.pid} on 127.0.0.1:${server.port}`];
  lines.push(s.activeVault ? `Vault:   ${s.activeVault.path}\nQueue:   ${s.activeVault.queueDirectory}` : 'Vault:   none selected');
  lines.push(`Queued:  ${s.queueCount} file${s.queueCount === 1 ? '' : 's'}${s.nextBatchAt ? ` · next batch ${s.nextBatchAt}` : ''}`);
  lines.push(`Jobs:    ${s.runningJobs} running · ${s.pendingApprovals} waiting for review${s.pendingApprovals ? ' (review in the Distill app)' : ''}`);
  for (const r of s.runners) {
    lines.push(`Runner:  ${r.displayName} (${r.id})${r.enabled ? '' : ' disabled'}${r.problems.length ? ` · ${r.problems.length} problem(s)` : ''}`);
  }
  const problems = [...s.problems, ...s.runners.flatMap((r) => r.problems)];
  if (problems.length) {
    lines.push('Problems:');
    for (const p of problems) lines.push(`  - ${p.message} [${p.code}]`);
  }
  return lines.join('\n') + '\n';
}

// ───────────────────────────── serve ─────────────────────────────

async function serve(args: string[], io: CliIO, paths: ReturnType<typeof statePaths>): Promise<number> {
  const { values, positionals } = parse(args, { port: { type: 'string' } });
  if (positionals.length) throw usageError(`unexpected argument "${positionals[0]}"`);
  const portText = str(values.port);
  const port = portText === undefined ? 0 : Number(portText);
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw usageError(`invalid --port "${portText}"`);
  try {
    const handle = await runServer({ paths, port, log: (m) => io.stderr(`distill serve: ${m}\n`) });
    await handle.done;
    return 0;
  } catch (err) {
    if (err instanceof ServerAlreadyRunningError) throw new CliError(err.message, err.code);
    throw new CliError(`cannot start the server: ${(err as Error).message}`, 'server_start_failed');
  }
}

// ───────────────────────────── plugin install ─────────────────────────────

async function plugin(args: string[], io: CliIO): Promise<number> {
  const [sub, ...rest] = args;
  if (sub !== 'install') throw usageError(sub ? `unknown plugin command "${sub}" (only "plugin install")` : 'usage: distill plugin install --target claude|codex');
  const { values, positionals } = parse(rest, {
    target: { type: 'string' },
    'dry-run': { type: 'boolean' },
    copy: { type: 'boolean' },
    force: { type: 'boolean' },
  });
  if (positionals.length) throw usageError(`unexpected argument "${positionals[0]}"`);
  const target = str(values.target);
  if (target !== 'claude' && target !== 'codex') throw usageError('--target must be "claude" or "codex"');
  const out = new Output(io, values.json === true);
  const dryRun = values['dry-run'] === true;
  if (target === 'claude' && !dryRun && !out.json) {
    out.info('Running the claude plugin commands:');
  }
  const res = installPlugin({
    target,
    dryRun,
    copy: values.copy === true,
    force: values.force === true,
    home: io.env.HOME ?? os.homedir(),
    pluginDir: defaultPluginDir(io.env),
    run: io.runCommand,
  });
  out.result(res, () => formatInstall(res));
  return 0;
}

function formatInstall(res: PluginInstallResult): string {
  const lines: string[] = [];
  const prefix = res.dryRun ? '[dry-run] ' : '';
  for (const a of res.actions) {
    switch (a.action) {
      case 'run':
        lines.push(`${prefix}${res.dryRun ? 'would run' : 'ran'}: ${a.command!.map(shellQuote).join(' ')}`);
        break;
      case 'unchanged':
        lines.push(`${prefix}${a.skill}: already linked at ${a.destination}`);
        break;
      case 'conflict':
        lines.push(`${prefix}${a.skill}: ${a.destination} exists and is not this skill (use --force to replace)`);
        break;
      default:
        lines.push(`${prefix}${res.dryRun ? 'would ' : ''}${a.action} ${a.skill}: ${a.source} -> ${a.destination}`);
    }
  }
  for (const n of res.notes) lines.push(n);
  return lines.join('\n') + '\n';
}

function shellQuote(s: string): string {
  return /^[\w@%+=:,./-]+$/.test(s) ? s : `'${s.replace(/'/g, `'\\''`)}'`;
}
