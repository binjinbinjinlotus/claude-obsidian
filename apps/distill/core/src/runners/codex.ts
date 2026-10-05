import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { AgentRunner, ModelOption, RunRequest, RunResult, RunnerCapability, SessionStoreStatus, Settings, SetupProblem } from '../contracts.js';
import { codexHome, codexRolloutStatus, sessionNotFoundError } from './session.js';
import { runProcess, RunnerError, type ProcessOutput, type RunProcessOptions } from './process.js';
import { parseStructured, prepareSchema, runnerOption, type PreparedSchema } from './model-api.js';

export const CODEX_ID = 'codex';

export type ProcessLauncher = (opts: RunProcessOptions) => Promise<ProcessOutput>;

/** Where `codex` usually lives; settings.runnerOptions.codex.path overrides. */
export function codexCandidates(): string[] {
  const home = os.homedir();
  return [
    path.join(home, '.local', 'bin', 'codex'),
    '/opt/homebrew/bin/codex',
    '/usr/local/bin/codex',
    '/Applications/Codex.app/Contents/Resources/codex',
  ];
}

function isExecutable(p: string): boolean {
  try {
    fs.accessSync(p, fs.constants.X_OK);
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}

export function codexPath(settings: Settings): string | undefined {
  const configured = runnerOption(settings, CODEX_ID, 'path');
  if (configured) return configured;
  return codexCandidates().find(isExecutable);
}

const EDIT_DIR_RULE = /^Edit\(\/(\/.+)\/\*\*\)$/;

/**
 * Codex has no per-command allow-list; it confines writes by folder. The
 * writable folders are the directory-wide `Edit(//abs/**)` rules of the
 * request (the job directory for ingest). File-level Edit grants are skipped,
 * which is stricter than the rule, never looser.
 */
export function writableRoots(request: RunRequest): string[] {
  const roots: string[] = [];
  for (const rule of request.allowedTools) {
    const m = EDIT_DIR_RULE.exec(rule);
    if (m && !roots.includes(m[1]!)) roots.push(m[1]!);
  }
  return roots;
}

/**
 * The process cwd (Codex's workspace root, which is writable in
 * workspace-write mode). Never the vault itself. Prefer the job directory
 * under `<vault>/.vault-meta/worker/` so start and resume pick the same root
 * even after later grants add more Edit rules.
 */
export function codexWorkspace(request: RunRequest, roots: string[]): string {
  const jobs = path.join(request.workingDirectory, '.vault-meta', 'worker') + '/';
  return roots.find((r) => r.startsWith(jobs)) ?? roots[0] ?? request.workingDirectory;
}

export interface CodexInvocation {
  codexPath: string;
  cwd: string;
  sandbox: 'workspace-write' | 'read-only';
  writableRoots: string[];
  model: string;
  effort?: string | null;
  sessionResume?: string;
  outputSchemaFile?: string;
  images: string[];
}

const toml = (s: string) => JSON.stringify(s); // a JSON string is a valid TOML basic string

/**
 * argv for `codex exec` (first turn) or `codex exec resume` (later turns).
 * The prompt is always read from stdin (`-`). `--` ends options so the
 * variadic `--image` cannot swallow the positional arguments.
 *
 * `exec resume` accepts neither `-s`, `-C` nor `--add-dir`, so the sandbox is
 * set through `-c` config keys in both modes.
 */
export function codexArguments(inv: CodexInvocation): string[] {
  const args = ['exec'];
  if (inv.sessionResume !== undefined) args.push('resume');
  args.push('--json', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules');
  if (inv.sessionResume === undefined) args.push('-C', inv.cwd, '--sandbox', inv.sandbox);
  args.push('-m', inv.model);
  args.push('-c', `sandbox_mode=${toml(inv.sandbox)}`, '-c', 'approval_policy="never"');
  if (inv.sandbox === 'workspace-write') {
    args.push(
      '-c',
      `sandbox_workspace_write.writable_roots=[${inv.writableRoots.map(toml).join(',')}]`,
      '-c',
      'sandbox_workspace_write.network_access=false',
      '-c',
      'sandbox_workspace_write.exclude_slash_tmp=true',
      '-c',
      'sandbox_workspace_write.exclude_tmpdir_env_var=true',
    );
  }
  if (inv.effort) args.push('-c', `model_reasoning_effort=${toml(inv.effort)}`);
  if (inv.outputSchemaFile !== undefined) args.push('--output-schema', inv.outputSchemaFile);
  for (const img of inv.images) args.push('--image', img);
  args.push('--');
  if (inv.sessionResume !== undefined) args.push(inv.sessionResume);
  args.push('-');
  return args;
}

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

export interface CodexEvents {
  threadID?: string;
  lastMessage?: string;
  error?: string;
  turnCompleted: boolean;
}

/** Read `codex exec --json` JSONL events. Unknown events and non-JSON lines are ignored. */
export function parseCodexEvents(raw: string): CodexEvents {
  const out: CodexEvents = { turnCompleted: false };
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t.startsWith('{')) continue;
    let ev: unknown;
    try {
      ev = JSON.parse(t);
    } catch {
      continue;
    }
    if (!isObj(ev)) continue;
    switch (ev.type) {
      case 'thread.started':
        if (typeof ev.thread_id === 'string') out.threadID = ev.thread_id;
        break;
      case 'item.completed':
        if (isObj(ev.item) && ev.item.type === 'agent_message' && typeof ev.item.text === 'string') out.lastMessage = ev.item.text;
        break;
      case 'turn.completed':
        out.turnCompleted = true;
        break;
      case 'turn.failed':
        out.error = isObj(ev.error) && typeof ev.error.message === 'string' ? ev.error.message : 'Turn failed';
        break;
      case 'error':
        if (typeof ev.message === 'string') out.error = ev.message;
        break;
      default:
        break;
    }
  }
  return out;
}

/**
 * OpenAI Codex CLI (`codex exec`). An agent that reads files and runs
 * commands, confined by its sandbox rather than per-command rules: writes go
 * only to the job directory; the core runs the approved transaction itself
 * (`sandboxedWrites`). It cannot enforce `toolPermissions`, so Ask is not offered.
 */
export class CodexRunner implements AgentRunner {
  readonly id = CODEX_ID;
  readonly displayName = 'Codex';
  readonly kind = 'agent' as const;
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>([
    'agentTools',
    'sandboxedWrites',
    'sessionResume',
    'structuredOutput',
    'effort',
  ]);
  /** From `codex debug models` (codex-cli 0.155.0-alpha). */
  readonly models: ModelOption[] = [
    { id: 'gpt-5.5', label: 'GPT-5.5', note: 'Codex default' },
    { id: 'gpt-5.4', label: 'GPT-5.4' },
    { id: 'gpt-5.6-terra', label: 'GPT-5.6 Terra' },
    { id: 'gpt-5.6-sol', label: 'GPT-5.6 Sol', note: 'Any model id your Codex account can use works.' },
  ];
  /**
   * Passed as `-c model_reasoning_effort=…`. The levels every catalog model
   * accepts (`codex debug models`); some models also take max/ultra.
   */
  readonly effortLevels = ['low', 'medium', 'high', 'xhigh'];
  readonly defaultModel = 'gpt-5.5';

  constructor(
    private readonly launch: ProcessLauncher = runProcess,
    /** Codex home (tests); default CODEX_HOME or ~/.codex. */
    private readonly home?: string,
  ) {}

  problems(settings: Settings): SetupProblem[] {
    const p = codexPath(settings);
    if (p && isExecutable(p)) return [];
    return [{ code: 'missingCodex', message: p ? `codex CLI not found at ${p}.` : 'codex CLI not found (install it or set its path).' }];
  }

  invocation(request: RunRequest, settings: Settings, outputSchemaFile?: string): CodexInvocation {
    const bin = codexPath(settings);
    if (!bin) throw new RunnerError('codex CLI not found.', 'launchFailed');
    const roots = writableRoots(request);
    const inv: CodexInvocation = {
      codexPath: bin,
      cwd: codexWorkspace(request, roots),
      sandbox: roots.length > 0 ? 'workspace-write' : 'read-only',
      writableRoots: roots,
      model: request.selection.model,
      effort: request.selection.effort ?? null,
      images: request.images ?? [],
    };
    if ('resume' in request.session) inv.sessionResume = request.session.resume;
    if (outputSchemaFile !== undefined) inv.outputSchemaFile = outputSchemaFile;
    return inv;
  }

  /** Codex has no system-prompt flag; the first turn carries it ahead of the prompt. */
  static prompt(request: RunRequest): string {
    if (!request.systemPrompt || 'resume' in request.session) return request.prompt;
    return `<instructions>\n${request.systemPrompt}\n</instructions>\n\n${request.prompt}`;
  }

  async run(request: RunRequest, settings: Settings): Promise<RunResult> {
    let schema: PreparedSchema | undefined;
    let tmp: string | undefined;
    try {
      let schemaFile: string | undefined;
      if (request.outputSchema !== undefined) {
        schema = prepareSchema(request.outputSchema);
        tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-codex-'));
        schemaFile = path.join(tmp, 'schema.json');
        fs.writeFileSync(schemaFile, JSON.stringify(schema.wire));
      }
      const inv = this.invocation(request, settings, schemaFile);
      if (inv.sandbox === 'workspace-write') fs.mkdirSync(inv.cwd, { recursive: true });
      const opts: RunProcessOptions = {
        executable: inv.codexPath,
        args: codexArguments(inv),
        cwd: inv.cwd,
        stdin: CodexRunner.prompt(request),
        environment: request.environment ?? {},
      };
      if (request.signal) opts.signal = request.signal;
      const output = await this.launch(opts);
      const raw = output.stdout.toString('utf8');
      const events = parseCodexEvents(raw);
      if (events.threadID === undefined && events.lastMessage === undefined && output.status !== 0) {
        if (inv.sessionResume !== undefined) {
          const gone = sessionNotFoundError(`${events.error ?? ''}\n${output.stderr.toString('utf8')}`, inv.sessionResume);
          if (gone) throw gone;
        }
        throw new RunnerError(`Exited ${output.status}: ${(events.error ?? output.stderr.toString('utf8')).slice(-2000)}`, 'nonZeroExit');
      }
      const result: RunResult = {
        resultText: events.lastMessage ?? events.error ?? '',
        isError: events.error !== undefined || output.status !== 0,
        // Codex reports tokens, not money.
        costUSD: 0,
        denials: [],
        raw,
      };
      const sid = events.threadID ?? inv.sessionResume;
      if (sid !== undefined) result.sessionID = sid;
      if (schema && events.lastMessage !== undefined && !result.isError) {
        try {
          result.structured = parseStructured(events.lastMessage, schema);
        } catch {
          /* missing structured output is handled by the engine (needs_input) */
        }
      }
      return result;
    } finally {
      if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
    }
  }

  resumeCommand(sessionID: string, model: string, settings: Settings): string[] | undefined {
    const bin = codexPath(settings);
    return bin ? [bin, 'resume', sessionID, '-m', model] : undefined;
  }

  /** A new interactive session whose first message is `prompt`. */
  newSessionCommand(prompt: string, model: string, settings: Settings): string[] | undefined {
    const bin = codexPath(settings);
    return bin ? [bin, '-m', model, prompt] : undefined;
  }

  /** A rollout file ending in the session id under <CODEX_HOME or ~/.codex>/sessions; `home` overrides (tests). */
  sessionStatus(sessionID: string, environment?: Record<string, string | undefined>): SessionStoreStatus {
    return codexRolloutStatus(sessionID, this.home ?? codexHome({ ...process.env, ...(environment ?? {}) }));
  }
}
