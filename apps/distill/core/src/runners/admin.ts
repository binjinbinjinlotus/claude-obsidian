import {
  CoreError,
  runnerSupports,
  type AITask,
  type DistillCore,
  type RunnerInfo,
  type RunnerRegistry,
  type Settings,
  type SetupProblem,
} from '../contracts.js';
import type { RunnerAdminOwned } from '../engine/index.js';
import { defaultSecretStore, secretIsSet, type SecretStore } from './secrets.js';

export interface RunnerAdminDeps {
  runners: RunnerRegistry;
  getSettings(): Settings;
  /** Default: the process-wide store (macOS Keychain), shared with the runners. */
  secrets?: SecretStore;
  /** Default process.env; consulted for env-var fallbacks (OPENAI_API_KEY, ...). */
  env?: NodeJS.ProcessEnv;
}

export type RunnerAdmin = Pick<DistillCore, RunnerAdminOwned>;

const TASKS: AITask[] = ['ingest', 'ask', 'labelSuggest', 'imageText', 'actionFind', 'actionDraft', 'actionImprove', 'recovery'];

export function createRunnerAdmin(deps: RunnerAdminDeps): RunnerAdmin {
  const secrets = deps.secrets ?? defaultSecretStore();
  const env = deps.env ?? process.env;

  return {
    async listRunners(): Promise<RunnerInfo[]> {
      const settings = deps.getSettings();
      return deps.runners.all().map((r) => {
        let problems: SetupProblem[];
        try {
          problems = r.problems(settings);
        } catch (err) {
          problems = [{ code: 'runnerError', message: (err as Error).message }];
        }
        return {
          id: r.id,
          displayName: r.displayName,
          kind: r.kind ?? 'agent',
          enabled: settings.enabledRunners.includes(r.id),
          capabilities: [...r.capabilities],
          tasks: TASKS.filter((t) => runnerSupports(r, t)),
          models: r.models,
          effortLevels: r.effortLevels,
          defaultModel: r.defaultModel,
          problems,
          // An env-var fallback counts as set.
          secrets: (r.secrets ?? []).map((s) => ({ name: s.name, label: s.label, isSet: secretIsSet(secrets, r.id, s.name, env) })),
        };
      });
    },

    async setRunnerSecret(runnerID: string, name: string, value: string | null): Promise<void> {
      const runner = deps.runners.get(runnerID);
      if (!runner) throw new CoreError('not_found', `Unknown runner ${runnerID}`);
      if (!(runner.secrets ?? []).some((s) => s.name === name)) {
        throw new CoreError('invalid_request', `${runner.displayName} has no secret named ${name}`);
      }
      if (value !== null && value.trim().length === 0) {
        throw new CoreError('invalid_request', 'Secret value is empty; send null to clear it.');
      }
      await secrets.set(runnerID, name, value === null ? null : value.trim());
    },
  };
}
