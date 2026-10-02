import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseArgs, type ParseArgsConfig } from 'node:util';
import type {
  AddNoteRequest,
  AddNoteResult,
  AskRequest,
  AskResponse,
  ModelSelection,
  NoteImage,
  Settings,
  StatusResponse,
} from '@distill/core/contracts';
import { ServerAlreadyRunningError, runServer, statePaths, type ServerLock } from '@distill/core/server';
import { CliError, connect, usageError, type ServerSpawner } from './client.js';
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
  distill ask "<question>" [--label L]... [--source S]... [--runner R] [--model M]
              [--effort E] [--conversation ID] [--vault PATH] [--json]
  distill note add --title T [--text "..." | --file PATH | -] [--image PATH[:extract|:keep]]...
              [--source S] [--ref "..."] [--vault PATH] [--json]
  distill status [--json]
  distill serve [--port N]
  distill plugin install --target claude|codex [--dry-run] [--copy] [--force] [--json]
  distill --help | --version

Commands:
  ask           Answer a question from your vault, with numbered citations and gaps.
                Read-only. Default scope is all notes; --label/--source narrow it.
                --runner/--model/--effort override the "ask" defaults from settings
                (effort: low | medium | high | xhigh | max). --conversation ID continues
                a previous answer's conversation. "-" as the question reads stdin.
  note add      Queue a written note (text, images, source) for Distill to ingest.
                Text comes from --text, --file PATH, or "-" (stdin). --image may repeat;
                ":keep" (default) stores the image in the vault, ":extract" reads its
                text into the note without storing it. Nothing is written to the vault
                until a person approves the change in the Distill app.
  status        Server, active vault, queue size, reviews waiting, runner problems.
  serve         Run the Distill core server in the foreground (one per user).
  plugin install
                Install the distill-ask and distill-note agent skills.
                --target claude: runs \`claude plugin marketplace add <plugin dir>\` and
                \`claude plugin install distill@distill-local\`.
                --target codex: links each skill into ~/.agents/skills/<name>
                (--copy copies instead; --force replaces existing entries).
                --dry-run prints the actions without doing them.

Approval stays with a person: this CLI has no approve, apply, reply or reject
commands. Review queued changes in the Distill app.

Other commands start the server in the background when it is not running
(log: <state dir>/server.log). State dir: ~/Library/Application Support/Distill,
or $DISTILL_STATE_DIR.

--json output (one JSON document on stdout):
  ask       {"conversationID", "answer", "citations": [{"n","path","title"}], "gaps": [..],
             "selection": {"runnerID","model","effort"}, "costUSD"}
  note add  {"notePath", "queued": [absolute paths]}
  status    {"version", "activeVault": {"path","queueDirectory"}|null, "problems": [{"code","message"}],
             "queueCount", "pendingApprovals", "runningJobs", "nextBatchAt",
             "runners": [{"id","displayName","enabled","problems"}],
             "server": {"pid","port","startedAt","version"}}
  plugin install
            {"target", "dryRun", "pluginDir", "actions": [{"action","skill","source","destination","command"}],
             "notes": [..]}
  errors    {"error": {"code", "message"}}  (also with exit code 1 or 2)

Exit codes: 0 success, 1 error, 2 usage error.
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
    case 'status':
      return status(rest, io, api);
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
  });
  const out = new Output(io, values.json === true);
  let question = positionals.join(' ').trim();
  if (question === '-') question = (await io.readStdin()).trim();
  if (!question) throw usageError('ask needs a question, e.g. distill ask "How hot for sencha?"');

  const req: AskRequest = { question };
  const labels = strs(values.label);
  const sources = strs(values.source);
  if (labels.length) req.labels = labels;
  if (sources.length) req.sources = sources;
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

  const res = await client.request<AskResponse>('POST', '/v1/ask', req);
  out.result(res, () => {
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
    const sel = `${res.selection.runnerID} · ${res.selection.model}${res.selection.effort ? ` · ${res.selection.effort}` : ''}`;
    lines.push(`(${sel} · $${res.costUSD.toFixed(4)} · follow up with --conversation ${res.conversationID})`);
    return lines.join('\n') + '\n';
  });
  return 0;
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
  if (sub !== 'add') throw usageError(sub ? `unknown note command "${sub}" (only "note add")` : 'usage: distill note add --title T ...');
  const { values, positionals } = parse(rest, {
    title: { type: 'string' },
    text: { type: 'string' },
    file: { type: 'string' },
    image: { type: 'string', multiple: true },
    source: { type: 'string' },
    ref: { type: 'string' },
    vault: { type: 'string' },
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

  const client = await api(out);
  const res = await client.request<AddNoteResult>('POST', '/v1/notes', req);
  out.result(res, () => {
    const kept = images.filter((i) => i.mode === 'keep').length;
    const extracted = images.length - kept;
    const parts = [kept ? `${kept} image${kept > 1 ? 's' : ''} kept` : '', extracted ? `${extracted} read as text` : ''].filter(Boolean);
    return (
      `Queued "${title}"${parts.length ? ` (${parts.join(', ')})` : ''}: ${res.notePath}\n` +
      'Distill will ingest it in the next batch; the vault changes only after you approve them in the Distill app.\n'
    );
  });
  return 0;
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
