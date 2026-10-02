import path from 'node:path';
import type { CoreEvent, DistillCore, Progress, StatePaths } from './contracts.js';
import { createEngine, type EngineOptions } from './engine/index.js';
import { createAskService } from './ask/index.js';
import { createRunnerAdmin } from './runners/admin.js';
import { createActionsService } from './actions/index.js';
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
  // Events from services outside the engine (Ask history) join the engine's stream.
  const extra = new Set<(e: CoreEvent) => void>();
  // Latest progress per key, from both streams, for clients that connect mid-run.
  const progress = new Map<string, Progress>();
  const track = (e: CoreEvent) => {
    if (e.type !== 'progress') return;
    if (e.progress.finished) progress.delete(e.progress.key);
    else progress.set(e.progress.key, e.progress);
  };
  engine.subscribe(track);
  const emit = (e: CoreEvent) => {
    track(e);
    for (const l of extra) l(e);
  };
  const ask = createAskService({
    emit,
    getSettings: () => engine.getSettings(),
    runners: engine.runners,
    stateDir: path.join(paths.dir, 'ask'),
  });
  const admin = createRunnerAdmin({ runners: engine.runners, getSettings: () => engine.getSettings() });
  const actions = createActionsService({
    emit,
    getSettings: () => engine.getSettings(),
    runners: engine.runners,
    file: paths.actions ?? path.join(paths.dir, 'actions.json'),
    stateDir: paths.dir,
  });
  return {
    ...engine,
    ...actions,
    ask: (req) => ask.ask(req),
    listConversations: () => ask.listConversations(),
    getConversation: (id) => ask.getConversation(id),
    deleteConversation: (id) => ask.deleteConversation(id),
    setConversationPinned: (id, pinned) => ask.setConversationPinned(id, pinned),
    cancelAsk: (id) => ask.cancelAsk(id),
    listProgress: async () => [...progress.values()],
    listRunners: () => admin.listRunners(),
    setRunnerSecret: (id, name, value) => admin.setRunnerSecret(id, name, value),
    subscribe(listener) {
      const off = engine.subscribe(listener);
      extra.add(listener);
      return () => {
        off();
        extra.delete(listener);
      };
    },
  };
}
