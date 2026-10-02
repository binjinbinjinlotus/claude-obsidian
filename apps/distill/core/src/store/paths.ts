import os from 'node:os';
import path from 'node:path';
import type { StatePaths } from '../contracts.js';

/** State lives with the Swift app's: ~/Library/Application Support/Distill (override: DISTILL_STATE_DIR). */
export function statePaths(dir = process.env.DISTILL_STATE_DIR): StatePaths {
  const root = dir ?? path.join(os.homedir(), 'Library', 'Application Support', 'Distill');
  return {
    dir: root,
    settings: path.join(root, 'settings.json'),
    jobs: path.join(root, 'jobs.json'),
    serverLock: path.join(root, 'server.json'),
    token: path.join(root, 'token'),
    actions: path.join(root, 'actions.json'),
  };
}
