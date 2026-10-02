import path from 'node:path';
import type { DistillCore, StatePaths } from './contracts.js';
import { createEngine, type EngineOptions } from './engine/index.js';
import { createAskService } from './ask/index.js';
import { createRunnerAdmin } from './runners/admin.js';
import { statePaths } from './store/paths.js';

export * from './contracts.js';
export { statePaths } from './store/paths.js';

export interface CoreOptions extends Partial<Omit<EngineOptions, 'paths'>> {
  paths?: StatePaths;
}

/** Compose the engine and Ask into the single DistillCore the server exposes. */
export function createCore(opts: CoreOptions = {}): DistillCore {
  const paths = opts.paths ?? statePaths();
  const engine = createEngine({ ...opts, paths });
  const ask = createAskService({
    getSettings: () => engine.getSettings(),
    runners: engine.runners,
    stateDir: path.join(paths.dir, 'ask'),
  });
  const admin = createRunnerAdmin({ runners: engine.runners, getSettings: () => engine.getSettings() });
  return {
    ...engine,
    ask: (req) => ask.ask(req),
    listConversations: () => ask.listConversations(),
    getConversation: (id) => ask.getConversation(id),
    deleteConversation: (id) => ask.deleteConversation(id),
    setConversationPinned: (id, pinned) => ask.setConversationPinned(id, pinned),
    listRunners: () => admin.listRunners(),
    setRunnerSecret: (id, name, value) => admin.setRunnerSecret(id, name, value),
  };
}
