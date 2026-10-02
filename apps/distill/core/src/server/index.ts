import type { DistillCore, StatePaths } from '../contracts.js';
import { createCore } from '../index.js';
import { statePaths } from '../store/paths.js';
import { startServer, type RunningServer } from './http.js';
import {
  assertNoLiveServer,
  coreVersion,
  ensureToken,
  releaseLock,
  writeLock,
  type ServerLock,
} from './lifecycle.js';

export { startServer, HttpError, apiJob, type ServerOptions, type RunningServer, type ServerCore, type ApiPermissionDenial } from './http.js';
export * from './lifecycle.js';
export { statePaths } from '../store/paths.js';
/** In-memory DistillCore for tests and client development. */
export { createFakeCore, sampleJob, sampleConversation, sampleAction, FAKE_SUGGESTIONS, type FakeCore } from './fake-core.js';

export interface RunServerOptions {
  paths?: StatePaths;
  port?: number;
  /** Override the core factory (tests). Default: createCore({paths}). */
  createCore?: (paths: StatePaths) => DistillCore;
  /** Install SIGINT/SIGTERM handlers (default true). */
  handleSignals?: boolean;
  log?: (message: string) => void;
}

export interface ServerHandle {
  port: number;
  lock: ServerLock;
  /** Stop HTTP, stop the core, remove server.json. Idempotent. */
  shutdown(): Promise<void>;
  /** Resolves once the server has shut down. */
  done: Promise<void>;
}

/**
 * `distill serve`: one server per state dir. Creates the token if needed,
 * starts the core and the HTTP API on 127.0.0.1, then writes server.json.
 * Throws ServerAlreadyRunningError when a live server holds the lock.
 */
export async function runServer(opts: RunServerOptions = {}): Promise<ServerHandle> {
  const paths = opts.paths ?? statePaths();
  const log = opts.log ?? ((m: string) => console.error(`distill serve: ${m}`));
  assertNoLiveServer(paths);
  const token = ensureToken(paths);

  const core = (opts.createCore ?? ((p: StatePaths) => createCore({ paths: p })))(paths);
  await core.start();

  let http: RunningServer;
  try {
    http = await startServer({ core, token, port: opts.port ?? 0 });
  } catch (err) {
    await core.stop().catch(() => undefined);
    throw err;
  }

  let lock: ServerLock;
  try {
    lock = writeLock(paths, { port: http.port, startedAt: new Date().toISOString(), version: coreVersion() });
  } catch (err) {
    await http.close();
    await core.stop().catch(() => undefined);
    throw err;
  }

  let resolveDone!: () => void;
  const done = new Promise<void>((resolve) => (resolveDone = resolve));
  const onExit = () => releaseLock(paths);
  process.on('exit', onExit);

  let stopping: Promise<void> | null = null;
  const shutdown = () => {
    stopping ??= (async () => {
      try {
        await http.close();
        await core.stop().catch((err: unknown) => log(`core stop failed: ${(err as Error).message}`));
      } finally {
        releaseLock(paths);
        process.off('exit', onExit);
        if (opts.handleSignals !== false) {
          process.off('SIGINT', onSignal);
          process.off('SIGTERM', onSignal);
        }
        resolveDone();
      }
    })();
    return stopping;
  };
  const onSignal = (signal: NodeJS.Signals) => {
    log(`received ${signal}, shutting down`);
    void shutdown();
  };
  if (opts.handleSignals !== false) {
    process.on('SIGINT', onSignal);
    process.on('SIGTERM', onSignal);
  }

  log(`listening on http://127.0.0.1:${http.port} (pid ${process.pid}, state ${paths.dir})`);
  return { port: http.port, lock, shutdown, done };
}
