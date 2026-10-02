import { notImplemented, type DistillCore, type RunnerRegistry, type Settings } from '../contracts.js';
import type { RunnerAdminOwned } from '../engine/index.js';

export interface RunnerAdminDeps {
  runners: RunnerRegistry;
  getSettings(): Settings;
}

export type RunnerAdmin = Pick<DistillCore, RunnerAdminOwned>;

// OWNER: runners teammate. Replace these stubs.
export function createRunnerAdmin(_deps: RunnerAdminDeps): RunnerAdmin {
  return {
    listRunners: async () => notImplemented('listRunners'),
    setRunnerSecret: async () => notImplemented('setRunnerSecret'),
  };
}
