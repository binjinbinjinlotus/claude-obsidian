import { runnerSupports, type AITask, type AgentRunner, type RunnerRegistry, type Settings } from '../contracts.js';
import { AiSdkRunner } from './ai-sdk.js';
import { ClaudeCodeRunner } from './claude-code.js';
import { CodexRunner } from './codex.js';
import type { FetchLike } from './model-api.js';
import { OpenAIRunner } from './openai.js';
import { OpenRouterRunner } from './openrouter.js';
import type { ProcessOutput, RunProcessOptions } from './process.js';
import { defaultSecretStore, type SecretStore } from './secrets.js';

/** A registry over a fixed runner list. Add new backends to `defaultRunners()`. */
export function createRunnerRegistry(runners: AgentRunner[]): RunnerRegistry {
  return {
    all: () => [...runners],
    get: (id) => runners.find((r) => r.id === id),
    candidates: (task: AITask, settings: Settings) =>
      runners.filter((r) => settings.enabledRunners.includes(r.id) && runnerSupports(r, task)),
  };
}

export interface RunnerDeps {
  secrets?: SecretStore;
  fetch?: FetchLike;
  launch?: (opts: RunProcessOptions) => Promise<ProcessOutput>;
}

/** Every backend, Claude Code first. Runners stay off until listed in settings.enabledRunners. */
export function defaultRunners(deps: RunnerDeps = {}): AgentRunner[] {
  const secrets = deps.secrets ?? defaultSecretStore();
  return [
    new ClaudeCodeRunner(deps.launch),
    new CodexRunner(deps.launch),
    new OpenAIRunner(secrets, deps.fetch),
    new OpenRouterRunner(secrets, deps.fetch),
    new AiSdkRunner(secrets, deps.launch),
  ];
}

export function defaultRegistry(deps: RunnerDeps = {}): RunnerRegistry {
  return createRunnerRegistry(defaultRunners(deps));
}
