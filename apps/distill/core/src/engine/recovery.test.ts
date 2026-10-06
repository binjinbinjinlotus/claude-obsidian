import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { PermissionDenial } from '../contracts.js';
import { denialAnswer, denialLine, denialPaths, denialSummary, friendlyPath, recoveryFor } from './recovery.js';

const VAULT = '/Users/me/Vault';
const JOB = `${VAULT}/.vault-meta/worker/job-20261005-1`;
const where = { vaultPath: VAULT, jobDir: JOB };
/** The command the owner was shown on 2026-10-05. */
const DIFF: PermissionDenial = {
  toolName: 'Bash',
  input: {
    command:
      `diff <(python3 -c "import json;d=json.load(open('${VAULT}/wiki/meta/ledgers/claim-ledger.json'));print(json.dumps(d,indent=1,sort_keys=True))") ` +
      `<(python3 -c "import json;d=json.load(open('${JOB}/wiki/meta/ledgers/claim-ledger.json'));print(json.dumps(d))")`,
  },
};

test('the answer names Read, Grep and Glob and the files, inside the vault or the job only', () => {
  const extra: PermissionDenial = { toolName: 'Bash', input: { command: 'cat /etc/passwd /Users/me/Vault/wiki/log.md' } };
  const text = denialAnswer([DIFF, extra], where);
  assert.match(text, /Read, Grep or Glob/);
  assert.match(text, /claim-ledger\.json/);
  assert.match(text, /\/Users\/me\/Vault\/wiki\/log\.md/);
  assert.doesNotMatch(text, /\/etc\/passwd`/, 'paths outside the vault and job are never listed');
  assert.match(text, /Don't run shell commands or python/);
  assert.deepEqual(denialPaths([DIFF], VAULT, JOB), [`${VAULT}/wiki/meta/ledgers/claim-ledger.json`, `${JOB}/wiki/meta/ledgers/claim-ledger.json`]);
  assert.ok(denialLine(DIFF).length <= 200);
});

test("the owner's sentence is plain words, never the command", () => {
  const s = denialSummary([DIFF], { ...where, answers: 2 });
  assert.equal(s, "Claude wanted to compare the claim ledger with this batch's copy. Distill couldn't let it run that, and told it to read the files instead (twice).");
  for (const bad of ['python3', '<(', '-c', '/Users/']) assert.ok(!s.includes(bad), bad);
  assert.equal(
    denialSummary([{ toolName: 'Bash', input: { command: `rm ${VAULT}/wiki/concepts/retry-policy.md` } }], { ...where, answers: 0 }),
    "Claude wanted to change “retry policy”. Distill couldn't let it run that.",
  );
  assert.equal(
    denialSummary([{ toolName: 'WebFetch', input: { url: 'https://example.com' } }], { ...where, answers: 1 }),
    "Claude wanted to look up something online (WebFetch). Distill couldn't let it run that, and told it to read the files instead (once).",
  );
  assert.equal(friendlyPath(`${VAULT}/wiki/hot.md`, where), 'the hot cache');
  assert.equal(friendlyPath(`${VAULT}/notes/x.txt`, where), 'x.txt');
});

test('a recovery for the same signature carries on; another signature starts fresh', () => {
  const running = { state: 'running' as const, signature: 'denial' as const, attempts: [], denialAnswers: 1 };
  assert.equal(recoveryFor(running, 'denial'), running);
  assert.equal(recoveryFor(running, 'lock').denialAnswers, 0);
  assert.equal(recoveryFor({ ...running, state: 'fixed' }, 'denial').denialAnswers, 0);
});
