import type { AskRequest, AskResponse, RunnerRegistry, Settings } from '../contracts.js';

export interface AskDeps {
  getSettings(): Settings;
  runners: RunnerRegistry;
  /** Directory for Ask conversation state (sessions), e.g. <stateDir>/ask. */
  stateDir: string;
}

export interface AskService {
  ask(req: AskRequest): Promise<AskResponse>;
}

// OWNER: ask teammate. Replace this stub.
export function createAskService(_deps: AskDeps): AskService {
  return {
    async ask() {
      throw new Error('ask: not implemented');
    },
  };
}
