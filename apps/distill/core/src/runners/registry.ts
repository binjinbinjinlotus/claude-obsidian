import { runnerSupports, type AITask, type AgentRunner, type RunnerRegistry, type Settings } from '../contracts.js';
import { ClaudeCodeRunner } from './claude-code.js';

/** A registry over a fixed runner list. Add new backends to `defaultRunners()`. */
export function createRunnerRegistry(runners: AgentRunner[]): RunnerRegistry {
  return {
    all: () => [...runners],
    get: (id) => runners.find((r) => r.id === id),
    candidates: (task: AITask, settings: Settings) =>
      runners.filter((r) => settings.enabledRunners.includes(r.id) && runnerSupports(r, task)),
  };
}

export function defaultRunners(): AgentRunner[] {
  return [new ClaudeCodeRunner()];
}

export function defaultRegistry(): RunnerRegistry {
  return createRunnerRegistry(defaultRunners());
}
