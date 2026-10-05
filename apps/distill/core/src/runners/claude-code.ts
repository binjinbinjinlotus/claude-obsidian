import fs from 'node:fs';
import type {
  AgentRunner,
  ModelOption,
  PermissionDenial,
  RunRequest,
  RunResult,
  RunSession,
  RunnerCapability,
  RunnerStep,
  Settings,
  SessionStoreStatus,
  SetupProblem,
} from '../contracts.js';
import { runProcess, RunnerError, type ProcessOutput, type RunProcessOptions } from './process.js';
import { claudeConfigDir, claudeTranscriptStatus, sessionNotFoundError } from './session.js';

export const CLAUDE_CODE_ID = 'claude-code';

/** One `claude -p` invocation (Swift `ClaudeInvocation`). */
export interface ClaudeInvocation {
  claudePath: string;
  workingDirectory: string;
  prompt: string;
  session: RunSession;
  model: string;
  effort?: string | null;
  allowedTools: string[];
  availableTools?: string[];
  addDirectories: string[];
  pluginDirectory?: string;
  outputSchema?: string;
  appendSystemPrompt?: string;
  environment: Record<string, string>;
  /** v7: stream events (`--output-format stream-json --verbose`) for the live log. */
  stream?: boolean;
}

/**
 * The prompt goes over stdin so it never collides with variadic flags such
 * as `--allowedTools`. One argv entry per rule: a comma inside a rule must not split it.
 */
export function claudeArguments(inv: ClaudeInvocation): string[] {
  const args = inv.stream ? ['-p', '--output-format', 'stream-json', '--verbose'] : ['-p', '--output-format', 'json'];
  args.push('--model', inv.model);
  if (inv.effort) args.push('--effort', inv.effort);
  if ('start' in inv.session) args.push('--session-id', inv.session.start);
  else args.push('--resume', inv.session.resume);
  if (inv.pluginDirectory !== undefined) args.push('--plugin-dir', inv.pluginDirectory);
  for (const dir of inv.addDirectories) args.push('--add-dir', dir);
  if (inv.outputSchema !== undefined) args.push('--json-schema', inv.outputSchema);
  if (inv.appendSystemPrompt !== undefined) args.push('--append-system-prompt', inv.appendSystemPrompt);
  // Isolation: never load user/project/local settings or MCP servers, whose allow
  // rules would otherwise merge into Distill's gate.
  args.push('--setting-sources', '', '--strict-mcp-config');
  if (inv.availableTools !== undefined) args.push('--tools', inv.availableTools.join(','));
  if (inv.allowedTools.length > 0) args.push('--allowedTools', ...inv.allowedTools);
  return args;
}

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Claude Code's `--output-format json` envelope, decoded into a RunResult. */
export function parseClaudeJSON(raw: string): RunResult {
  let obj: unknown;
  try {
    obj = JSON.parse(raw);
  } catch {
    throw new RunnerError(`Unreadable runner output: ${raw.slice(0, 500)}`, 'malformedOutput');
  }
  if (!isObj(obj)) throw new RunnerError(`Unreadable runner output: ${raw.slice(0, 500)}`, 'malformedOutput');
  const denials: PermissionDenial[] = [];
  if (Array.isArray(obj.permission_denials)) {
    for (const d of obj.permission_denials) {
      if (!isObj(d) || typeof d.tool_name !== 'string') continue;
      denials.push({ toolName: d.tool_name, input: isObj(d.tool_input) ? d.tool_input : {} });
    }
  }
  const result: RunResult = {
    resultText: typeof obj.result === 'string' ? obj.result : '',
    isError: obj.is_error === true,
    costUSD: typeof obj.total_cost_usd === 'number' ? obj.total_cost_usd : 0,
    denials,
    raw,
  };
  if (typeof obj.session_id === 'string') result.sessionID = obj.session_id;
  if ('structured_output' in obj) result.structured = obj.structured_output;
  return result;
}

/**
 * `--output-format stream-json`: one JSON event per line. The last `result` event carries the same
 * fields as the `json` envelope (result, is_error, total_cost_usd, session_id, structured_output,
 * permission_denials), so it decodes through parseClaudeJSON. `raw` stays the whole stream.
 */
export function parseClaudeStream(raw: string): RunResult {
  let last: string | undefined;
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t.startsWith('{')) continue;
    try {
      const obj: unknown = JSON.parse(t);
      if (isObj(obj) && obj.type === 'result') last = t;
    } catch {
      /* a partial or foreign line */
    }
  }
  if (last === undefined) throw new RunnerError(`Unreadable runner output: ${raw.slice(-500)}`, 'malformedOutput');
  return { ...parseClaudeJSON(last), raw };
}

/** The steps in one stream-json line: tool calls and text from the assistant, tool results from the user. */
export function claudeStreamSteps(line: string): RunnerStep[] {
  let obj: unknown;
  try {
    obj = JSON.parse(line);
  } catch {
    return [];
  }
  if (!isObj(obj) || !isObj(obj.message) || !Array.isArray(obj.message.content)) return [];
  // Steps of a subagent (Task) carry parent_tool_use_id; the parent's own call already shows.
  if (typeof obj.parent_tool_use_id === 'string') return [];
  const steps: RunnerStep[] = [];
  for (const c of obj.message.content) {
    if (!isObj(c)) continue;
    if (obj.type === 'assistant' && c.type === 'tool_use' && typeof c.name === 'string') {
      steps.push({ kind: 'tool', tool: c.name, input: isObj(c.input) ? c.input : {}, ...(typeof c.id === 'string' ? { id: c.id } : {}) });
    } else if (obj.type === 'assistant' && c.type === 'text' && typeof c.text === 'string' && c.text.trim()) {
      steps.push({ kind: 'message', text: c.text });
    } else if (obj.type === 'user' && c.type === 'tool_result' && typeof c.tool_use_id === 'string') {
      steps.push({ kind: 'toolDone', id: c.tool_use_id, ...(c.is_error === true ? { isError: true } : {}) });
    }
  }
  return steps;
}

export type ProcessLauncher = (opts: RunProcessOptions) => Promise<ProcessOutput>;

/**
 * Claude Code (`claude -p`). Full agent: tools, enforceable permission rules,
 * session resume, JSON-schema output, effort, images.
 */
export class ClaudeCodeRunner implements AgentRunner {
  readonly id = CLAUDE_CODE_ID;
  readonly displayName = 'Claude Code';
  readonly kind = 'agent' as const;
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>([
    'agentTools',
    'toolPermissions',
    'sessionResume',
    'structuredOutput',
    'effort',
    'vision',
    // v10: stream-json carries each Read's returned line span (tool_use_result.file).
    'readCoverage',
  ]);
  readonly models: ModelOption[] = [
    { id: 'haiku', label: 'Haiku', note: 'Fastest and lightest' },
    { id: 'sonnet', label: 'Sonnet', note: 'Balanced, recommended' },
    { id: 'opus', label: 'Opus', note: 'Deepest synthesis' },
    { id: 'claude-opus-5-5', label: 'Claude Opus 5.5' },
    { id: 'claude-sonnet-5-5', label: 'Claude Sonnet 5.5' },
    { id: 'claude-haiku-4-5-20251001', label: 'Claude Haiku 4.5' },
    { id: 'claude-fable-5-1', label: 'Claude Fable 5.1' },
  ];
  readonly effortLevels = ['low', 'medium', 'high', 'xhigh', 'max'];
  readonly defaultModel = 'sonnet';

  constructor(
    private readonly launch: ProcessLauncher = runProcess,
    /** Where transcripts live (tests); default CLAUDE_CONFIG_DIR or ~/.claude. */
    private readonly configDir?: string,
  ) {}

  problems(settings: Settings): SetupProblem[] {
    try {
      fs.accessSync(settings.claudePath, fs.constants.X_OK);
      if (fs.statSync(settings.claudePath).isFile()) return [];
    } catch {
      /* fall through */
    }
    return [{ code: 'missingClaude', message: `claude CLI not found at ${settings.claudePath}.` }];
  }

  invocation(request: RunRequest, settings: Settings): ClaudeInvocation {
    const inv: ClaudeInvocation = {
      claudePath: settings.claudePath,
      workingDirectory: request.workingDirectory,
      prompt: request.prompt,
      session: request.session,
      model: request.selection.model,
      effort: request.selection.effort ?? null,
      allowedTools: request.allowedTools,
      ...(request.availableTools !== undefined ? { availableTools: request.availableTools } : {}),
      addDirectories: request.readableDirectories,
      environment: request.environment ?? {},
    };
    if (request.pluginDirectory !== undefined) inv.pluginDirectory = request.pluginDirectory;
    if (request.outputSchema !== undefined) inv.outputSchema = request.outputSchema;
    if (request.systemPrompt !== undefined) inv.appendSystemPrompt = request.systemPrompt;
    if (request.onStep) inv.stream = true;
    return inv;
  }

  async run(request: RunRequest, settings: Settings): Promise<RunResult> {
    const inv = this.invocation(request, settings);
    const opts: RunProcessOptions = {
      executable: inv.claudePath,
      args: claudeArguments(inv),
      cwd: inv.workingDirectory,
      stdin: inv.prompt,
      environment: inv.environment,
    };
    if (request.signal) opts.signal = request.signal;
    const onStep = request.onStep;
    if (onStep) {
      opts.onStdoutLine = (line) => {
        for (const step of claudeStreamSteps(line)) {
          try {
            onStep(step);
          } catch {
            /* the live log must never break a run */
          }
        }
      };
    }
    const output = await this.launch(opts);
    // A refused resume: exit 1 and "No conversation found with session ID: <id>" on stderr. With
    // stream-json, stdout also carries an error `result` event (verified 2026-10-05), so this is
    // checked before stdout is parsed.
    if (output.status !== 0 && 'resume' in inv.session) {
      const gone = sessionNotFoundError(output.stderr.toString('utf8'), inv.session.resume);
      if (gone) throw gone;
    }
    if (output.stdout.length === 0 && output.status !== 0) {
      throw new RunnerError(`Exited ${output.status}: ${output.stderr.toString('utf8').slice(-2000)}`, 'nonZeroExit');
    }
    const text = output.stdout.toString('utf8');
    return inv.stream ? parseClaudeStream(text) : parseClaudeJSON(text);
  }

  resumeCommand(sessionID: string, model: string, settings: Settings): string[] {
    return [settings.claudePath, '--resume', sessionID, '--plugin-dir', settings.productRoot, '--model', model];
  }

  /** A new interactive session whose first message is `prompt`. */
  newSessionCommand(prompt: string, model: string, settings: Settings): string[] {
    return [settings.claudePath, '--plugin-dir', settings.productRoot, '--model', model, prompt];
  }

  /** A transcript file named after the session under <CLAUDE_CONFIG_DIR or ~/.claude>/projects; `configDir` overrides (tests). */
  sessionStatus(sessionID: string, environment?: Record<string, string | undefined>): SessionStoreStatus {
    return claudeTranscriptStatus(sessionID, this.configDir ?? claudeConfigDir({ ...process.env, ...(environment ?? {}) }));
  }
}
