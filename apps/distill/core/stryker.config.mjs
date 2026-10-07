// Mutation testing for the core's pure logic (npm run test:mutation; docs/specs/tooling.md).
// node:test has no native Stryker runner, so the tap runner runs each test file as its own node
// process (tsx loads the TypeScript) and Stryker maps coverage per test file. `mutate` names only
// the files and line ranges the focused unit tests below cover; never the whole repo.
// HOME and DISTILL_STATE_DIR point at throwaway dirs so no mutant can reach the owner's state.
import os from 'node:os';
import path from 'node:path';

const scratch = path.join(os.tmpdir(), 'distill-stryker');
process.env.HOME = path.join(scratch, 'home');
process.env.DISTILL_STATE_DIR = path.join(scratch, 'state');

export default {
  packageManager: 'npm',
  testRunner: 'tap',
  plugins: ['@stryker-mutator/tap-runner'],
  tap: {
    testFiles: [
      'src/engine/apply-queue.test.ts',
      'src/engine/recovery.test.ts',
      'src/engine/review-labels.unit.test.ts',
      'src/engine/validator.test.ts',
      'src/actions/routing.test.ts',
      'src/actions/highlights.test.ts',
      'src/actions/slack-target.test.ts',
      'src/actions/jira-meta.test.ts',
      'src/actions/prompts.test.ts',
      'src/store/json.test.ts',
      'src/store/jobs.test.ts',
      'src/store/settings.test.ts',
      'src/server/http-parse.test.ts',
    ],
    nodeArgs: ['--import', 'tsx', '--test-reporter=tap', '-r', '{{hookFile}}', '{{testFile}}'],
  },
  mutate: [
    'src/engine/apply-queue.ts',
    'src/engine/recovery.ts',
    'src/engine/review-labels.ts',
    'src/engine/validator.ts',
    'src/actions/routing.ts',
    'src/actions/highlights.ts',
    'src/actions/slack-target.ts',
    'src/actions/jira-meta.ts',
    'src/actions/prompts.ts',
    'src/store/json.ts',
    'src/store/jobs.ts',
    'src/store/settings.ts',
    // The request checks only (Host/Origin/token, bad() to parseCollectedFiles, coreErrorStatus), not the routes.
    'src/server/http.ts:92-127',
    'src/server/http.ts:205-674',
    'src/server/http.ts:695-716',
  ],
  ignorePatterns: ['.stryker-tmp*', 'reports', 'dist'],
  coverageAnalysis: 'perTest',
  incremental: true,
  incrementalFile: 'reports/stryker-incremental.json',
  timeoutMS: 10000,
  timeoutFactor: 2,
  concurrency: Math.max(2, Math.min(8, os.availableParallelism() - 2)),
  thresholds: { high: 80, low: 60, break: 50 },
  reporters: ['clear-text', 'progress', 'html', 'json'],
  htmlReporter: { fileName: 'reports/mutation/index.html' },
  jsonReporter: { fileName: 'reports/mutation/mutation.json' },
  tempDirName: '.stryker-tmp',
  cleanTempDir: 'always',
};
