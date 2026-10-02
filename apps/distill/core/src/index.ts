import path from 'node:path';
import type { CoreEvent, DistillCore, Progress, StatePaths } from './contracts.js';
import { createEngine, type EngineOptions } from './engine/index.js';
import { createAskService } from './ask/index.js';
import { createRunnerAdmin } from './runners/admin.js';
import { createActionsService, type ActionsService } from './actions/index.js';
import type { FetchLike } from './runners/model-api.js';
import type { SecretStore } from './runners/secrets.js';
import { statePaths } from './store/paths.js';

export * from './contracts.js';
export { statePaths } from './store/paths.js';

export interface CoreOptions extends Partial<Omit<EngineOptions, 'paths'>> {
  paths?: StatePaths;
  /** Secret store for connections (default: the Keychain). Tests pass a MemorySecretStore. */
  secrets?: SecretStore;
  /** Network for connections (default: global fetch). Tests pass a fake. */
  fetch?: FetchLike;
}

/** Compose the engine and Ask into the single DistillCore the server exposes. */
export function createCore(opts: CoreOptions = {}): DistillCore {
  const paths = opts.paths ?? statePaths();
  // The actions service is created after the engine; the hook binds late.
  let actions: ActionsService | undefined;
  const engine = createEngine({
    ...opts,
    paths,
    onJobApplied: async (job) => {
      await opts.onJobApplied?.(job);
      await actions?.findInJob(job);
    },
  });
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
  actions = createActionsService({
    emit,
    getSettings: () => engine.getSettings(),
    runners: engine.runners,
    file: paths.actions ?? path.join(paths.dir, 'actions.json'),
    stateDir: paths.dir,
    ...(opts.secrets ? { secrets: opts.secrets } : {}),
    ...(opts.fetch ? { fetch: opts.fetch } : {}),
    ...(opts.now ? { now: opts.now } : {}),
    getConversation: (id) => ask.getConversation(id),
    setJobActions: (id, summary) => engine.setJobActions?.(id, summary),
  });
  const service = actions;
  const {
    findInJob: _findInJob,
    afterAsk: _afterAsk,
    sweepHistory: _sweepHistory,
    whenIdle: _actionsIdle,
    ...actionMethods
  } = service;
  return {
    ...engine,
    ...actionMethods,
    async ask(req) {
      const response = await ask.ask(req);
      // Finding actions in the answer runs in the background; it never delays the answer.
      void service.afterAsk(response.conversationID);
      return response;
    },
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
