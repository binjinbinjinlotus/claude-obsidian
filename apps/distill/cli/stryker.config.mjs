// Mutation testing for the CLI (npm run test:mutation; see core/stryker.config.mjs for the setup).
// `mutate` is cli.ts's argument checks (each command up to its first request) and its plain-words
// formatting, which cli-parse.test.ts covers. cli.test.ts stays out: its plugin tests resolve ../plugin,
// which a Stryker sandbox doesn't have. HOME and DISTILL_STATE_DIR point at throwaway dirs so no mutant can reach the owner's state.
import os from 'node:os';
import path from 'node:path';

const scratch = path.join(os.tmpdir(), 'distill-stryker-cli');
process.env.HOME = path.join(scratch, 'home');
process.env.DISTILL_STATE_DIR = path.join(scratch, 'state');

export default {
  packageManager: 'npm',
  testRunner: 'tap',
  plugins: ['@stryker-mutator/tap-runner'],
  tap: {
    testFiles: ['src/cli-parse.test.ts'],
    nodeArgs: ['--import', 'tsx', '--test-reporter=tap', '-r', '{{hookFile}}', '{{testFile}}'],
  },
  mutate: [
    'src/cli.ts:290-317',
    'src/cli.ts:333-391',
    'src/cli.ts:397-435',
    'src/cli.ts:568-656',
    'src/cli.ts:681-688',
    'src/cli.ts:701-706',
    'src/cli.ts:719-721',
    'src/cli.ts:744-753',
    'src/cli.ts:768-786',
    'src/cli.ts:792-798',
    'src/cli.ts:816-821',
    'src/cli.ts:833-838',
    'src/cli.ts:850-850',
    'src/cli.ts:855-882',
    'src/cli.ts:899-921',
    'src/cli.ts:929-972',
    'src/cli.ts:985-990',
    'src/cli.ts:996-1001',
    'src/cli.ts:1017-1025',
    'src/cli.ts:1031-1031',
    'src/cli.ts:1037-1101',
    'src/cli.ts:1121-1126',
    'src/cli.ts:1132-1137',
    'src/cli.ts:1148-1148',
    'src/cli.ts:1153-1156',
    'src/cli.ts:1165-1205',
    'src/cli.ts:1207-1212',
    'src/cli.ts:1225-1236',
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
