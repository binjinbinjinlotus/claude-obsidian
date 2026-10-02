import type { DistillCore, RunnerRegistry, Settings, StatePaths } from '../contracts.js';

/** Everything in DistillCore except `ask`, plus what Ask needs from the engine. */
export type Engine = Omit<DistillCore, 'ask'> & {
  readonly runners: RunnerRegistry;
  readonly paths: StatePaths;
};

export interface EngineOptions {
  paths: StatePaths;
  /** Inject runners in tests; default is the real registry. */
  runners?: RunnerRegistry;
  /** Scheduler tick in ms (default 5000). */
  tickMs?: number;
  now?: () => Date;
}

// OWNER: core-engine teammate. Replace this stub.
export function createEngine(_opts: EngineOptions): Engine {
  throw new Error('engine: not implemented');
}

export type { Settings };
