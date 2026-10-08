import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import type { AgentRunner, ModelOption, RunRequest, RunResult, RunnerCapability, Settings, SetupProblem } from '../contracts.js';
import { loadImages, parseSchema, runnerOption, sessionIDOf } from './model-api.js';
import { runProcess, RunnerError, type ProcessOutput, type RunProcessOptions } from './process.js';
import { defaultSecretStore, resolveSecret, type SecretStore } from './secrets.js';

export const AI_SDK_ID = 'ai-sdk';
export const AI_SDK_PROVIDERS: Record<string, string> = {
  openai: '@ai-sdk/openai',
  anthropic: '@ai-sdk/anthropic',
  google: '@ai-sdk/google',
  openrouter: '@openrouter/ai-sdk-provider',
};

export type ProcessLauncher = (opts: RunProcessOptions) => Promise<ProcessOutput>;

/**
 * The bridge script ships as source (tsc does not emit .mjs): next to this
 * module when run from src/, else back in src/ when run from dist/.
 */
export function bridgeScriptPath(): string | undefined {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [path.join(here, 'ai-sdk-bridge.mjs'), path.resolve(here, '..', '..', 'src', 'runners', 'ai-sdk-bridge.mjs')];
  return candidates.find((p) => fs.existsSync(p));
}

/** "provider:model" picks the provider per model; a bare id uses runnerOptions["ai-sdk"].provider (default openai). */
export function splitModel(model: string, settings: Settings): { provider: string; model: string } {
  const m = /^([a-z][a-z0-9-]*):(.+)$/.exec(model);
  if (m && m[1]! in AI_SDK_PROVIDERS) return { provider: m[1]!, model: m[2]! };
  return { provider: runnerOption(settings, AI_SDK_ID, 'provider') ?? 'openai', model };
}

function installed(packageDir: string, pkg: string): boolean {
  return fs.existsSync(path.join(packageDir, 'node_modules', ...pkg.split('/'), 'package.json'));
}

/**
 * Vercel AI SDK through a local Node bridge (ai-sdk-bridge.mjs). The user
 * installs `ai` and a provider package in runnerOptions["ai-sdk"].packageDir;
 * Distill adds no dependencies. Capabilities are conservative: JSON-schema
 * output only. Images are passed through when given, but vision is not
 * claimed because it depends on the provider and model.
 */
export class AiSdkRunner implements AgentRunner {
  readonly id = AI_SDK_ID;
  readonly displayName = 'Vercel AI SDK';
  readonly kind = 'modelAPI' as const;
  readonly secrets = [{ name: 'apiKey', label: 'Provider API key' }];
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['structuredOutput']);
  readonly models: ModelOption[] = [
    { id: 'openai:gpt-5-mini', label: 'OpenAI GPT-5 mini' },
    { id: 'anthropic:claude-haiku-4-5', label: 'Anthropic Claude Haiku 4.5' },
    { id: 'google:gemini-2.5-flash', label: 'Google Gemini 2.5 Flash', note: 'Use provider:model; any model id of an installed provider works.' },
  ];
  readonly effortLevels: string[] = [];
  readonly defaultModel = 'openai:gpt-5-mini';

  constructor(
    private readonly secretStore: SecretStore = defaultSecretStore(),
    private readonly launch: ProcessLauncher = runProcess,
  ) {}

  nodePath(settings: Settings): string {
    return settings.nodePath ?? process.execPath;
  }

  problems(settings: Settings): SetupProblem[] {
    const out: SetupProblem[] = [];
    const node = this.nodePath(settings);
    if (!fs.existsSync(node)) out.push({ code: 'missingNode', message: `node not found at ${node}.` });
    if (!bridgeScriptPath()) out.push({ code: 'missingBridge', message: 'ai-sdk-bridge.mjs is missing from this Distill install.' });
    const dir = runnerOption(settings, this.id, 'packageDir');
    if (!dir) {
      out.push({
        code: 'aiSdkNotConfigured',
        message: 'Set the AI SDK package folder (a folder where you ran `npm i ai @ai-sdk/<provider>`).',
      });
      return out;
    }
    if (!installed(dir, 'ai')) out.push({ code: 'missingAiSdk', message: `The "ai" package is not installed in ${dir} (run: npm i ai).` });
    const provider = runnerOption(settings, this.id, 'provider') ?? 'openai';
    const pkg = AI_SDK_PROVIDERS[provider];
    if (!pkg) out.push({ code: 'unknownAiSdkProvider', message: `Unknown AI SDK provider "${provider}" (${Object.keys(AI_SDK_PROVIDERS).join(', ')}).` });
    else if (!installed(dir, pkg)) out.push({ code: 'missingAiSdkProvider', message: `${pkg} is not installed in ${dir} (run: npm i ${pkg}).` });
    return out;
  }

  async run(request: RunRequest, settings: Settings): Promise<RunResult> {
    const dir = runnerOption(settings, this.id, 'packageDir');
    if (!dir) throw new RunnerError('AI SDK package folder is not set.', 'launchFailed');
    const bridge = bridgeScriptPath();
    if (!bridge) throw new RunnerError('ai-sdk-bridge.mjs is missing.', 'launchFailed');
    const { provider, model } = splitModel(request.selection.model, settings);
    const payload: Record<string, unknown> = {
      packageDir: dir,
      provider,
      model,
      prompt: request.prompt,
      images: loadImages(request).map((i) => i.dataURL),
    };
    if (request.systemPrompt) payload.system = request.systemPrompt;
    if (request.outputSchema !== undefined) payload.schema = parseSchema(request.outputSchema);
    // Optional: provider packages also read their own env vars (OPENAI_API_KEY, ...).
    const key = await resolveSecret(this.secretStore, this.id, 'apiKey');
    if (key) payload.apiKey = key;
    const baseURL = runnerOption(settings, this.id, 'baseURL');
    if (baseURL) payload.baseURL = baseURL;

    const opts: RunProcessOptions = {
      executable: this.nodePath(settings),
      args: [bridge],
      cwd: dir,
      stdin: JSON.stringify(payload),
      environment: request.environment ?? {},
    };
    if (request.signal) opts.signal = request.signal;
    const output = await this.launch(opts);
    const raw = output.stdout.toString('utf8');
    let obj: unknown;
    try {
      obj = JSON.parse(raw);
    } catch {
      throw new RunnerError(`AI SDK bridge exited ${output.status}: ${(raw || output.stderr.toString('utf8')).slice(-2000)}`, 'nonZeroExit');
    }
    const o = (typeof obj === 'object' && obj !== null ? obj : {}) as Record<string, unknown>;
    if (o.ok !== true) throw new RunnerError(`AI SDK: ${typeof o.error === 'string' ? o.error : 'unknown error'}`, 'apiError');
    const result: RunResult = {
      sessionID: sessionIDOf(request),
      resultText: typeof o.text === 'string' ? o.text : '',
      isError: false,
      costUSD: 0,
      denials: [],
      raw,
    };
    if (request.outputSchema !== undefined && 'object' in o) result.structured = o.object;
    return result;
  }
}
