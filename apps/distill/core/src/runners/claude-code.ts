import fs from 'node:fs';
import type {
  AgentRunner,
  ModelOption,
  PermissionDenial,
  RunRequest,
  RunResult,
  RunSession,
  RunnerCapability,
  Settings,
  SetupProblem,
} from '../contracts.js';
import { runProcess, RunnerError, type ProcessOutput, type RunProcessOptions } from './process.js';

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
}

/**
 * The prompt goes over stdin so it never collides with variadic flags such
 * as `--allowedTools`. One argv entry per rule: a comma inside a rule must not split it.
 */
export function claudeArguments(inv: ClaudeInvocation): string[] {
  const args = ['-p', '--output-format', 'json', '--model', inv.model];
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

export type ProcessLauncher = (opts: RunProcessOptions) => Promise<ProcessOutput>;

/**
 * Claude Code (`claude -p`). Full agent: tools, enforceable permission rules,
 * session resume, JSON-schema output, effort, images.
 */
export class ClaudeCodeRunner implements AgentRunner {
  readonly id = CLAUDE_CODE_ID;
  readonly displayName = 'Claude Code';
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>([
    'agentTools',
    'toolPermissions',
    'sessionResume',
    'structuredOutput',
    'effort',
    'vision',
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

  constructor(private readonly launch: ProcessLauncher = runProcess) {}

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
    const output = await this.launch(opts);
    if (output.stdout.length === 0 && output.status !== 0) {
      throw new RunnerError(`Exited ${output.status}: ${output.stderr.toString('utf8').slice(-2000)}`, 'nonZeroExit');
    }
    return parseClaudeJSON(output.stdout.toString('utf8'));
  }

  resumeCommand(sessionID: string, model: string, settings: Settings): string[] {
    return [settings.claudePath, '--resume', sessionID, '--plugin-dir', settings.productRoot, '--model', model];
  }
}
