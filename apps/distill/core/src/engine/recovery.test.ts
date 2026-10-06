import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { PermissionDenial } from '../contracts.js';
import { denialAnswer, denialLine, denialPaths, denialSummary, friendlyPath, plainCause, recoveryFor } from './recovery.js';

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

test('a recovery for the same signature carries on; another signature carries the bounds while it works, else starts fresh', () => {
  const rule = { at: '2026-10-06T10:00:00Z', by: 'rule' as const, fix: 'rebuild_in_session' as const, result: 'running' as const, costUSD: 0 };
  const running = { state: 'running' as const, signature: 'denial' as const, attempts: [rule], denialAnswers: 1 };
  assert.equal(recoveryFor(running, 'denial'), running);
  const other = recoveryFor(running, 'plan-error');
  assert.equal(other.signature, 'plan-error');
  assert.equal(other.denialAnswers, 1);
  assert.deepEqual(other.attempts.map((a) => a.result), ['failed']);
  assert.deepEqual(recoveryFor({ ...running, state: 'gaveUp' }, 'lock').attempts, []);
  assert.equal(recoveryFor({ ...running, state: 'fixed' }, 'denial').denialAnswers, 0);
});

test('recovery answers: only known fixes for the problem, and never the apply or a tool rule', async () => {
  const { parseRecoveryAnswer, validateFix } = await import('./recovery.js');
  assert.equal(parseRecoveryAnswer({ fix: 'format_disk', diagnosis: 'x' }), 'The answer named no fix Distill knows.');
  const a = parseRecoveryAnswer({ fix: 'answer_denial', diagnosis: 'd', reason: 'r', guidance: 'Read the two files.' });
  assert.ok(typeof a !== 'string');
  assert.equal(validateFix(a, 'denial'), null);
  assert.match(validateFix({ ...a, guidance: 'Please allow the rule Bash(diff:*)' }, 'denial') ?? '', /only the owner can allow/);
  assert.match(validateFix({ ...a, guidance: 'x'.repeat(1201) }, 'denial') ?? '', /1200/);
  assert.match(validateFix({ ...a, fix: 'split_batch' }, 'denial') ?? '', /isn't a fix for this problem/);
});

test('the cause in the owner\'s sentence is plain words, never stderr, argv or a path', () => {
  assert.equal(plainCause('Exited 1: API Error: 529 {"type":"overloaded_error"}'), 'the AI service was busy');
  assert.equal(plainCause('Claude Code stopped: rate limit reached'), 'the AI service was busy');
  assert.equal(plainCause("Bundle /tmp/elsewhere/bundle.json is outside this job's directory; refusing to inspect it."), 'the plan was saved in the wrong place');
  assert.equal(plainCause('Unreadable runner output: {"type":"result","subtype":'), 'the AI’s answer couldn’t be read');
  assert.equal(plainCause('Exited 2: python3 /Users/me/x.py --flag'), '');
  assert.equal(plainCause(undefined), '');
});
