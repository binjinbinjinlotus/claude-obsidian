import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { PermissionDenial } from '../contracts.js';
import {
  denialAnswer, denialLine, denialPaths, denialSummary, friendlyPath, MAX_DENIAL_ANSWERS, parseRecoveryAnswer, plainCause, RECOVERY_FIXES, RECOVERY_SCHEMA,
  recoveryFacts, recoveryFor, recoveryPrompt, validateFix, whoApplies, type RecoveryAnswer,
} from './recovery.js';

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
  const { parseRecoveryAnswer } = await import('./recovery.js');
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

test('the new fixes are checked against the batch, never taken on the agent’s word', () => {
  const ctx = {
    vaultPath: '/v', paths: ['wiki/a.md', 'wiki/log.md'],
    others: [{ id: 'j2', vaultPath: '/v', paths: ['wiki/a.md'] }, { id: 'j3', vaultPath: '/w', paths: ['wiki/a.md'] }, { id: 'j4', vaultPath: '/v', paths: ['wiki/z.md'] }],
    sources: ['wiki/sources/a.md', 'wiki/sources/b.md'], rebuiltPart: false, approvedSha256: 'f'.repeat(64),
  };
  const a = (fix: string, extra: Record<string, unknown> = {}) => ({ diagnosis: 'd', reason: 'r', fix, ...extra }) as never;
  assert.equal(validateFix(a('reinspect_same_bundle'), 'lock', ctx), null);
  assert.match(validateFix(a('reinspect_same_bundle'), 'lock', { ...ctx, approvedSha256: undefined }) ?? '', /approved/);
  assert.match(validateFix(a('reinspect_same_bundle'), 'plan-error', ctx) ?? '', /isn't a fix/);
  assert.equal(validateFix(a('wait_then_retry', { waitFor: 'j2' }), 'lock', ctx), null);
  assert.match(validateFix(a('wait_then_retry', { waitFor: 'j3' }), 'lock', ctx) ?? '', /another vault/);
  assert.match(validateFix(a('wait_then_retry', { waitFor: 'j4' }), 'lock', ctx) ?? '', /same pages/);
  assert.match(validateFix(a('wait_then_retry', { waitFor: 'nope' }), 'lock', ctx) ?? '', /another batch/);
  assert.equal(validateFix(a('split_batch', { groups: [['wiki/sources/a.md'], ['wiki/sources/b.md']] }), 'stale-again', ctx), null);
  assert.match(validateFix(a('split_batch', { groups: [['wiki/sources/a.md', 'wiki/sources/b.md']] }), 'stale-again', ctx) ?? '', /two groups/);
  assert.match(validateFix(a('split_batch', { groups: [['wiki/sources/a.md'], ['wiki/sources/a.md']] }), 'stale-again', ctx) ?? '', /two groups/);
  assert.match(validateFix(a('split_batch', { groups: [['wiki/sources/a.md'], ['wiki/sources/c.md']] }), 'stale-again', ctx) ?? '', /every source/);
  assert.match(validateFix(a('discard_stale_part'), 'stale-again', ctx) ?? '', /no rebuilt part/);
  assert.equal(validateFix(a('discard_stale_part'), 'stale-again', { ...ctx, rebuiltPart: true }), null);
  assert.match(validateFix(a('split_batch', { groups: [['x'], ['y']] }), 'not-recorded', ctx) ?? '', /isn't a fix/);
});

// ───────────── unit: edges and bounds ─────────────

test('denialLine: the command, else file_path, else path, else the input as JSON; whitespace folded; cut at 200 with an ellipsis', () => {
  assert.equal(denialLine({ toolName: 'Bash', input: { command: '  ls \n  -la\t/x  ', file_path: '/f' } }), 'Bash: ls -la /x');
  assert.equal(denialLine({ toolName: 'Edit', input: { file_path: '/v/a.md', path: '/v/b.md' } }), 'Edit: /v/a.md');
  assert.equal(denialLine({ toolName: 'Glob', input: { path: '/v', command: 3 } }), 'Glob: /v');
  assert.equal(denialLine({ toolName: 'WebFetch', input: { url: 'https://e.x' } }), 'WebFetch: {"url":"https://e.x"}');
  assert.equal(denialLine({ toolName: 'X', input: undefined as never }), 'X: {}');
  const exact = { toolName: 'Bash', input: { command: 'a'.repeat(200 - 'Bash: '.length) } };
  assert.equal(denialLine(exact).length, 200);
  assert.ok(!denialLine(exact).endsWith('…'), 'exactly 200 characters is not cut');
  const long = denialLine({ toolName: 'Bash', input: { command: 'a'.repeat(300) } });
  assert.equal(long.length, 200);
  assert.ok(long.endsWith('a…'));
  assert.equal(denialLine({ toolName: 'Bash', input: { command: 'abcdef' } }, 8), 'Bash: a…');
});

test('denialPaths: only string inputs, de-duplicated, trailing dots and colons dropped, at most 8, no sibling-prefix escape', () => {
  const many = Array.from({ length: 12 }, (_, i) => `${VAULT}/wiki/p${i}.md`).join(' ');
  const got = denialPaths([{ toolName: 'Bash', input: { command: many } }], VAULT, JOB);
  assert.equal(got.length, 8);
  assert.equal(got[7], `${VAULT}/wiki/p7.md`);
  assert.deepEqual(
    denialPaths([{ toolName: 'Bash', input: { command: `cat ${VAULT}/a.md. ${VAULT}/a.md: ${VAULT}/a.md`, n: 5 as never } }], VAULT, JOB),
    [`${VAULT}/a.md`],
  );
  assert.deepEqual(denialPaths([{ toolName: 'Bash', input: { command: `cat ${VAULT}-other/x.md ${VAULT}` } }], VAULT, JOB), [], 'a sibling folder or the vault root itself is not inside');
  assert.deepEqual(denialPaths([{ toolName: 'Edit', input: { file_path: `${VAULT}/../etc/x.md` } }], VAULT, JOB), [], 'a .. that leaves the vault is resolved first');
  assert.deepEqual(denialPaths([{ toolName: 'Bash', input: undefined as never }], VAULT, JOB), []);
  assert.deepEqual(denialPaths([{ toolName: 'Read', input: { file_path: `${JOB}/bundle.json` } }], `${VAULT}/`, `${JOB}/`), [`${JOB}/bundle.json`], 'trailing slashes on the roots are fine');
});

test('denialAnswer: at most 3 calls quoted, no "For example" without paths, and who applies (queued or not)', () => {
  const d = (c: string): PermissionDenial => ({ toolName: 'Bash', input: { command: c } });
  const text = denialAnswer([d('one'), d('two'), d('three'), d('four')], where);
  assert.match(text, /`Bash: one`, `Bash: two`, `Bash: three`/);
  assert.doesNotMatch(text, /four/);
  assert.doesNotMatch(text, /For example/);
  assert.match(denialAnswer([d(`cat ${VAULT}/wiki/a.md`)], where), /For example: `\/Users\/me\/Vault\/wiki\/a\.md`\./);
  assert.match(text, /don't run inspect or apply yourself/);
  assert.doesNotMatch(text, /waits in Distill's queue/);
  assert.match(denialAnswer([d('x')], { ...where, queued: true }), /waits in Distill's queue/);
  assert.ok(whoApplies(true).startsWith(whoApplies(false)));
  assert.notEqual(whoApplies(true), whoApplies(false));
  assert.equal(whoApplies(), whoApplies(false));
});

test('friendlyPath: job copy, ledgers, hot/log/index only under wiki/, page titles, anything else by file name', () => {
  assert.equal(friendlyPath(`${JOB}/wiki/hot.md`, where), "this batch's copy");
  assert.equal(friendlyPath(`${JOB}`, where), 'job-20261005-1', 'the job directory itself is not inside it');
  assert.equal(friendlyPath(`${VAULT}/wiki/meta/ledgers/source-ledger.json`, where), 'the source ledger');
  assert.equal(friendlyPath(`/elsewhere/claim-ledger.json`, where), 'the claim ledger');
  assert.equal(friendlyPath(`${VAULT}/wiki/log.md`, where), 'the vault log');
  assert.equal(friendlyPath(`${VAULT}/wiki/index.md`, where), 'the wiki index');
  assert.equal(friendlyPath(`${VAULT}/log.md`, where), 'log.md', 'outside wiki/ it is only a file');
  assert.equal(friendlyPath(`${VAULT}/hot.md`, where), 'hot.md');
  assert.equal(friendlyPath(`${VAULT}/index.md`, where), 'index.md');
  assert.equal(friendlyPath(`${VAULT}/wiki/concepts/a_b--c.md`, where), '“a b c”');
  assert.equal(friendlyPath(`${VAULT}/wiki/concepts/data.json`, where), 'data.json');
  assert.equal(friendlyPath(`${VAULT}/notes/x.md`, where), 'x.md');
  assert.equal(friendlyPath(`/Users/me/wiki/x.md`, where), 'x.md', 'a wiki/ folder outside the vault is not a page');
});

test('denialSummary: the verb per command and tool, the names joined, the count of answers', () => {
  const bash = (command: string) => [{ toolName: 'Bash', input: { command } }];
  const s = (d: PermissionDenial[], answers = 0) => denialSummary(d, { ...where, answers });
  assert.equal(s(bash(`cmp ${VAULT}/wiki/a.md`)), "Claude wanted to compare “a”. Distill couldn't let it run that.");
  assert.equal(s(bash(`echo hi > ${VAULT}/wiki/a.md`)), "Claude wanted to change “a”. Distill couldn't let it run that.");
  assert.equal(s(bash(`echo hi >> ${VAULT}/wiki/a.md`)), "Claude wanted to change “a”. Distill couldn't let it run that.");
  assert.equal(s(bash(`python3 ${VAULT}/x.py`)), "Claude wanted to run a script on x.py. Distill couldn't let it run that.");
  assert.equal(s(bash(`node -e 1`)), "Claude wanted to run a script on some files. Distill couldn't let it run that.");
  assert.equal(s(bash(`ruby -e 'p 1'`)), "Claude wanted to run a script on some files. Distill couldn't let it run that.");
  assert.equal(s(bash(`grep x ${VAULT}/wiki/a.md`)), "Claude wanted to read “a”. Distill couldn't let it run that.");
  assert.equal(s(bash(`rmdir ${VAULT}/x`)), "Claude wanted to run a command on x. Distill couldn't let it run that.", '"rmdir" is not "rm"');
  assert.equal(s(bash('git status')), "Claude wanted to run a command on some files. Distill couldn't let it run that.");
  assert.equal(s([{ toolName: 'Bash', input: {} }]), "Claude wanted to run a command on some files. Distill couldn't let it run that.");
  assert.equal(s([{ toolName: 'MultiEdit', input: { file_path: `${VAULT}/wiki/a.md` } }]), "Claude wanted to change “a” (MultiEdit). Distill couldn't let it run that.");
  assert.equal(s([{ toolName: 'NotebookEdit', input: {} }]), "Claude wanted to change some files (NotebookEdit). Distill couldn't let it run that.");
  assert.equal(s([{ toolName: 'WebSearch', input: { query: 'x' } }]), "Claude wanted to look up something online (WebSearch). Distill couldn't let it run that.");
  assert.equal(s([{ toolName: 'Task', input: {} }]), "Claude wanted to run a command on some files (Task). Distill couldn't let it run that.");
  assert.equal(s([]), "Claude wanted to run a command on some files. Distill couldn't let it run that.");
  // Names: two joined by "and" (not compare), three listed, a fourth dropped, duplicates once.
  const two = `cat ${VAULT}/wiki/a.md ${VAULT}/wiki/b.md`;
  assert.equal(s(bash(two)), "Claude wanted to read “a” and “b”. Distill couldn't let it run that.");
  assert.equal(s(bash(`cat ${VAULT}/wiki/a.md ${VAULT}/wiki/b.md ${VAULT}/wiki/c.md ${VAULT}/wiki/d.md`)), "Claude wanted to read “a”, “b” and “c”. Distill couldn't let it run that.");
  assert.equal(s(bash(`diff ${VAULT}/wiki/a.md ${VAULT}/wiki/b.md ${VAULT}/wiki/c.md`)), "Claude wanted to compare “a”, “b” and “c”. Distill couldn't let it run that.");
  assert.equal(s(bash(`cat ${VAULT}/notes/a.md ${VAULT}/other/a.md`)), "Claude wanted to read a.md. Distill couldn't let it run that.");
  assert.match(s(bash('ls'), 3), /\(3 times\)\.$/);
  assert.match(s(bash('ls'), 2), /\(twice\)\.$/);
  assert.match(s(bash('ls'), 1), /\(once\)\.$/);
});

test('recoveryFor: a waiting recovery carries over too; a missing denialAnswers counts as 0; no current starts fresh', () => {
  const att = (result: 'running' | 'failed' | 'fixed') => ({ at: 't', by: 'agent' as const, fix: 'give_up' as const, result: result as never, costUSD: 0 });
  const waiting = { state: 'waiting' as const, signature: 'lock' as const, attempts: [att('running'), att('fixed')] };
  const next = recoveryFor(waiting, 'stale-again');
  assert.deepEqual(next, { state: 'running', signature: 'stale-again', attempts: [{ ...att('failed') }, att('fixed')], denialAnswers: 0 });
  assert.equal(waiting.attempts[0]!.result, 'running', 'the old state is not changed in place');
  assert.deepEqual(recoveryFor(undefined, 'denial'), { state: 'running', signature: 'denial', attempts: [], denialAnswers: 0 });
  assert.deepEqual(recoveryFor(null, 'lock'), { state: 'running', signature: 'lock', attempts: [], denialAnswers: 0 });
  const gaveUp = { state: 'gaveUp' as const, signature: 'lock' as const, attempts: [att('failed')], denialAnswers: 2 };
  assert.equal(recoveryFor(gaveUp, 'lock'), gaveUp, 'gave up on the same problem: kept as is');
});

test('plainCause: each busy wording', () => {
  for (const e of ['Overloaded', 'ratelimit', 'rate-limit hit', 'Too Many Requests', 'usage limit reached', 'HTTP 429']) assert.equal(plainCause(e), 'the AI service was busy', e);
  assert.equal(plainCause('code 4290'), '', 'a number that only contains 429 is not busy');
  assert.equal(plainCause("outside the job's directory"), 'the plan was saved in the wrong place');
  assert.equal(plainCause("couldn't parse the output"), 'the AI’s answer couldn’t be read');
  assert.equal(plainCause('unreadable output'), 'the AI’s answer couldn’t be read');
  assert.equal(plainCause(null), '');
});

test('parseRecoveryAnswer: limits, trims, optional fields and groups', () => {
  assert.equal(parseRecoveryAnswer({ diagnosis: 'd' }), 'The answer named no fix Distill knows.');
  assert.equal(parseRecoveryAnswer({ fix: 7, diagnosis: 'd' }), 'The answer named no fix Distill knows.');
  assert.equal(parseRecoveryAnswer({ fix: 'give_up', diagnosis: '   ' }), 'The answer had no diagnosis.');
  assert.equal(parseRecoveryAnswer({ fix: 'give_up', diagnosis: 5 }), 'The answer had no diagnosis.');
  for (const fix of RECOVERY_FIXES) assert.equal((parseRecoveryAnswer({ fix, diagnosis: 'd' }) as RecoveryAnswer).fix, fix);
  const a = parseRecoveryAnswer({
    fix: 'split_batch', diagnosis: ` ${'d'.repeat(500)} `, reason: ` ${'r'.repeat(400)} `, guidance: '  g  ', waitFor: ' j2 ',
    groups: [['a', 3, 'b'], 'x', []],
  }) as RecoveryAnswer;
  assert.equal(a.diagnosis, 'd'.repeat(400));
  assert.equal(a.reason, 'r'.repeat(300));
  assert.equal(a.guidance, 'g');
  assert.equal(a.waitFor, 'j2');
  assert.deepEqual(a.groups, [['a', 'b'], [], []]);
  assert.deepEqual(parseRecoveryAnswer({ fix: 'give_up', diagnosis: 'd', reason: 1, guidance: ' ', waitFor: '', groups: 'no' }), { diagnosis: 'd', fix: 'give_up', reason: '' });
});

test('validateFix: every fix allowed per problem, and only those', () => {
  const allowed: Record<string, string[]> = {
    denial: ['answer_denial', 'new_session', 'give_up'],
    'stale-again': ['rebuild_in_session', 'wait_then_retry', 'split_batch', 'discard_stale_part', 'new_session', 'give_up'],
    lock: ['reinspect_same_bundle', 'wait_then_retry', 'give_up'],
    'plan-error': ['rebuild_in_session', 'split_batch', 'new_session', 'give_up'],
    'not-recorded': ['give_up'],
    'full-read-stop': ['give_up'],
    'session-gone': ['new_session', 'give_up'],
    'runner-failed': ['rebuild_in_session', 'new_session', 'give_up'],
  };
  for (const [sig, fixes] of Object.entries(allowed)) {
    for (const fix of RECOVERY_FIXES) {
      const why = validateFix({ diagnosis: 'd', reason: 'r', fix }, sig as never);
      assert.equal(why === `${fix} isn't a fix for this problem.`, !fixes.includes(fix), `${sig} ${fix}: ${why}`);
    }
  }
});

test('validateFix: the checks behind each fix', () => {
  const a = (fix: RecoveryAnswer['fix'], extra: Partial<RecoveryAnswer> = {}): RecoveryAnswer => ({ diagnosis: 'd', reason: 'r', fix, ...extra });
  const ctx = { vaultPath: '/v', paths: ['wiki/a.md'], others: [], sources: ['s1', 's2'], rebuiltPart: true, approvedSha256: 'f'.repeat(64) };
  assert.match(validateFix(a('wait_then_retry', { waitFor: 'j' }), 'lock') ?? '', /needs a plan you approved/, 'no context: no approved plan');
  assert.match(validateFix(a('reinspect_same_bundle'), 'lock', { ...ctx, approvedSha256: '' }) ?? '', /needs a plan you approved/);
  assert.match(validateFix(a('wait_then_retry'), 'lock', ctx) ?? '', /another batch to wait for/);
  assert.match(validateFix(a('split_batch', { groups: [['s1'], ['s2']] }), 'plan-error') ?? '', /at least two groups/, 'no context: refused');
  assert.match(validateFix(a('split_batch'), 'plan-error', ctx) ?? '', /at least two groups/);
  assert.match(validateFix(a('split_batch', { groups: [['s1'], [], ['s2']] }), 'plan-error', ctx) ?? 'ok', /^ok$/, 'empty groups are ignored');
  assert.equal(validateFix(a('split_batch', { groups: [['s1'], ['s2', 's1']] }), 'plan-error', ctx), 'A source is in two groups.');
  assert.match(validateFix(a('split_batch', { groups: [['s1'], ['s2'], ['s3']] }), 'plan-error', ctx) ?? '', /every source/, 'an extra source');
  assert.match(validateFix(a('split_batch', { groups: [['s1'], ['s3']] }), 'plan-error', { ...ctx, sources: ['s1', 's2'] }) ?? '', /every source/);
  assert.match(validateFix(a('discard_stale_part'), 'stale-again') ?? '', /no rebuilt part/);
  // Guidance: required for answer_denial, optional for rebuild_in_session, and checked whenever given.
  assert.equal(validateFix(a('answer_denial'), 'denial'), 'answer_denial needs guidance.');
  assert.equal(validateFix(a('rebuild_in_session'), 'plan-error'), null);
  assert.equal(validateFix(a('answer_denial', { guidance: 'x'.repeat(1200) }), 'denial'), null, '1200 characters is the limit');
  assert.match(validateFix(a('rebuild_in_session', { guidance: 'x'.repeat(1201) }), 'plan-error') ?? '', /1200/);
  for (const g of ['Run transaction  apply now', 'use --approved-plan-sha256 abc', 'TRANSACTION APPLY'])
    assert.match(validateFix(a('rebuild_in_session', { guidance: g }), 'plan-error') ?? '', /only your approval runs/, g);
  for (const g of ['add Bash(ls:*)', 'Edit(wiki/*)', 'Write(x)', 'try allowing the tool', 'Allow rule please', 'allow command'])
    assert.match(validateFix(a('answer_denial', { guidance: g }), 'denial') ?? '', /only the owner can allow/, g);
  assert.equal(validateFix(a('answer_denial', { guidance: 'Read both files with Read, then Edit the bundle.' }), 'denial'), null, 'naming a tool is fine; a rule is not');
  assert.equal(validateFix(a('new_session', { guidance: 'transaction apply' }), 'denial'), null, 'guidance is only checked where it is sent');
});

test('recoveryFacts: the sections that are there, the caps, and the newest 24 000 characters', () => {
  const base = { signature: 'lock' as const, turns: [], denials: [], answersSent: [], attempts: [], vaultPath: '/v', jobDir: '/v/j' };
  const bare = recoveryFacts(base);
  assert.match(bare, /^Problem: lock\./);
  assert.match(bare, /Vault: \/v\nJob directory: \/v\/j/);
  for (const absent of ['Blocked calls', 'What Distill already told', 'Earlier attempts', 'Pages this batch', 'rebuilt part']) assert.ok(!bare.includes(absent), absent);
  assert.ok(bare.endsWith('Conversation (newest last):\n'));

  const d = (n: number): PermissionDenial => ({ toolName: 'Bash', input: { command: `cmd${n}` } });
  const full = recoveryFacts({
    ...base,
    turns: Array.from({ length: 14 }, (_, i) => ({ author: i % 2 ? 'claude' : 'distill', text: `turn${i} ${'x'.repeat(i === 13 ? 2000 : 0)}` })),
    denials: Array.from({ length: 8 }, (_, i) => d(i)),
    answersSent: ['a1', 'a2', 'a3', `a4 ${'y'.repeat(700)}`],
    attempts: [
      { at: 't', by: 'rule', fix: 'answer_denial', result: 'failed', costUSD: 0 },
      { at: 't', by: 'agent', fix: 'give_up', result: 'gaveUp' as never, costUSD: 0, diagnosis: 'z'.repeat(300) },
    ] as never,
    context: {
      vaultPath: '/v', paths: Array.from({ length: 22 }, (_, i) => `wiki/p${i}.md`),
      others: [{ id: 'near', vaultPath: '/v', paths: ['wiki/p1.md', 'wiki/zz.md'] }, { id: 'far', vaultPath: '/w', paths: ['wiki/p1.md'] }, { id: 'apart', vaultPath: '/v', paths: ['wiki/q.md'] }],
      sources: ['s1', 's2'], rebuiltPart: true, approvedSha256: 'f',
    },
  });
  assert.match(full, /- Bash: cmd5\n/);
  assert.doesNotMatch(full, /cmd6/, 'at most 6 blocked calls');
  assert.doesNotMatch(full, /- a1\n/, 'the last 3 answers only');
  assert.match(full, /- a2\n- a3\n- a4 y+\n/);
  assert.ok(!full.includes('y'.repeat(600)), 'each answer cut to 600 characters');
  assert.match(full, /Pages this batch changes: wiki\/p0\.md, .*wiki\/p19\.md\n/);
  assert.doesNotMatch(full, /wiki\/p20\.md/, 'at most 20 pages');
  assert.match(full, /Other batches touching the same pages:\n- near: wiki\/p1\.md\n/);
  assert.doesNotMatch(full, /far|apart/);
  assert.match(full, /Source pages of this batch: s1, s2/);
  assert.match(full, /A rebuilt part is waiting for the owner\./);
  assert.match(full, /The owner approved this batch/);
  assert.match(full, /- rule answer_denial: failed\n- agent give_up: gaveUp \(z{200}\)\n/);
  assert.doesNotMatch(full, /turn1 /, 'the last 12 turns only');
  assert.match(full, /\[distill\] turn2 /);
  assert.match(full, /\[claude\] turn13 x{1493}$/, 'each turn cut to 1500 characters');

  const quiet = recoveryFacts({ ...base, context: { vaultPath: '/v', paths: [], others: [], sources: [], rebuiltPart: false } });
  assert.match(quiet, /No rebuilt part is waiting\.\nThe owner has not approved a plan/);
  assert.doesNotMatch(quiet, /Pages this batch|Other batches|Source pages/);

  const huge = recoveryFacts({ ...base, turns: Array.from({ length: 12 }, (_, i) => ({ author: 'c', text: `${i}`.padEnd(1500, '#') })), answersSent: ['q'.repeat(600)], vaultPath: 'V'.repeat(8000), jobDir: 'J'.repeat(8000) });
  assert.equal(huge.length, 24_000);
  assert.ok(huge.endsWith('#'), 'the newest end is kept');
  assert.ok(!huge.startsWith('Problem:'));
});

test('recoveryPrompt: the facts follow the instructions; the schema lists every fix and requires the three answers', () => {
  const p = recoveryPrompt('FACTS');
  assert.ok(p.endsWith('\n\nFACTS'));
  for (const fix of RECOVERY_FIXES) assert.ok(p.includes(fix), fix);
  assert.match(p, /Never suggest applying anything to the vault/);
  const schema = JSON.parse(RECOVERY_SCHEMA);
  assert.deepEqual(schema.properties.fix.enum, [...RECOVERY_FIXES]);
  assert.deepEqual(schema.required, ['diagnosis', 'fix', 'reason']);
  assert.equal(schema.additionalProperties, false);
  assert.equal(MAX_DENIAL_ANSWERS, 2);
});

test('denialPaths and denialAnswer: a sibling of the job directory is outside; trailing punctuation runs are dropped; paths joined with commas', () => {
  const job = '/work/jobs/j1';
  assert.deepEqual(denialPaths([{ toolName: 'Bash', input: { command: `cat ${job}-old/bundle.json ${job}/a.json.: ${job}/b.json` } }], VAULT, job), [`${job}/a.json`, `${job}/b.json`]);
  const text = denialAnswer([{ toolName: 'Bash', input: { command: `diff ${VAULT}/wiki/a.md ${VAULT}/wiki/b.md` } }], where);
  assert.match(text, /For example: `\/Users\/me\/Vault\/wiki\/a\.md`, `\/Users\/me\/Vault\/wiki\/b\.md`\. To compare two files, read both\./);
  const none = denialAnswer([{ toolName: 'Bash', input: { command: 'ls' } }], where);
  assert.match(none, /\(no shell commands or python here\)\. Use Read, Grep or Glob to inspect files instead\. To compare two files, read both\. Don't run/);
  assert.ok(none.endsWith(' Then continue the task and finish with the structured status.'));
  assert.match(whoApplies(false), /^Distill runs `transaction inspect` itself/);
});

test('denialSummary: the verb comes from the start of the command, not a later pipe; exact tool names only', () => {
  const s = (command: string) => denialSummary([{ toolName: 'Bash', input: { command } }], { ...where, answers: 0 });
  const verb = (command: string) => /^Claude wanted to (.+?) (?:some files|“a”|a\.py|x\.py)/.exec(s(command))?.[1];
  const A = `${VAULT}/wiki/a.md`;
  assert.equal(verb(`cat ${A} | diff - x`), 'read');
  assert.equal(verb(`grep rm ${A}`), 'read');
  assert.equal(verb(`cat ${A} | python3 -c 'x'`), 'read');
  assert.equal(verb(`cat ${A} | node`), 'read');
  assert.equal(verb(`git log ${A} | grep x`), 'run a command on');
  assert.equal(verb(`> ${A}`), 'change');
  assert.equal(verb(`echo x >${A}`), 'change');
  assert.equal(verb(`python ${VAULT}/x.py`), 'run a script on');
  assert.equal(verb(`   diff ${A}`), 'compare', 'leading blanks are ignored');
  assert.equal(denialSummary([{ toolName: 'Bash', input: undefined as never }], { ...where, answers: 0 }), "Claude wanted to run a command on some files. Distill couldn't let it run that.");
  const tool = (toolName: string) => /^Claude wanted to (.+?) (?:some|something)/.exec(denialSummary([{ toolName, input: {} }], { ...where, answers: 0 }))?.[1];
  assert.equal(tool('Edit'), 'change');
  assert.equal(tool('NotebookEditor'), 'run a command on');
  assert.equal(tool('mcp__fs__Edit'), 'run a command on');
  assert.equal(tool('WebFetch'), 'look up');
  assert.equal(tool('WebFetchTool'), 'run a command on');
  assert.equal(tool('mcp__x__WebSearch'), 'run a command on');
  assert.equal(friendlyPath(`${VAULT}/wiki/meta/ledgers/claim-ledger.json.bak`, where), 'claim-ledger.json.bak');
  assert.equal(friendlyPath(`${VAULT}/wiki/meta/ledgers/source-ledger.json.bak`, where), 'source-ledger.json.bak');
});

test('plainCause and validateFix: the looser wordings and spacing they accept', () => {
  assert.equal(plainCause('outside the jobs directory'), 'the plan was saved in the wrong place');
  assert.equal(plainCause('couldnt parse the output'), 'the AI’s answer couldn’t be read');
  const a = (g: string): RecoveryAnswer => ({ diagnosis: 'd', reason: 'r', fix: 'answer_denial', guidance: g });
  assert.match(validateFix(a('allow  the rule'), 'denial') ?? '', /only the owner can allow/);
  assert.match(validateFix(a('allow the  tool'), 'denial') ?? '', /only the owner can allow/);
  const ctx = { vaultPath: '/v', paths: ['wiki/a.md'], others: [{ id: 'j', vaultPath: '/v', paths: ['wiki/a.md', 'wiki/other.md'] }], sources: ['s1', 's2'], rebuiltPart: false, approvedSha256: 'f' };
  assert.equal(validateFix({ diagnosis: 'd', reason: 'r', fix: 'wait_then_retry', waitFor: 'j' }, 'lock', ctx), null, 'one shared page is enough');
  assert.match(validateFix({ diagnosis: 'd', reason: 'r', fix: 'split_batch', groups: [['s1', 's2'], []] }, 'plan-error', ctx) ?? '', /at least two groups/, 'an empty group is no group');
  assert.equal((parseRecoveryAnswer({ fix: 'give_up', diagnosis: 'd', waitFor: '   ' }) as RecoveryAnswer).waitFor, undefined);
});

test('recoveryFacts: headed sections, turns a blank line apart, other batches capped at 6 with at most 6 shared pages each', () => {
  const shared = Array.from({ length: 8 }, (_, i) => `wiki/s${i}.md`);
  const facts = recoveryFacts({
    signature: 'stale-again',
    turns: [{ author: 'distill', text: 'A' }, { author: 'claude', text: 'B' }],
    denials: [{ toolName: 'Bash', input: { command: 'ls' } }],
    answersSent: ['told'],
    attempts: [{ at: 't', by: 'rule', fix: 'answer_denial', result: 'failed', costUSD: 0 }] as never,
    vaultPath: '/v',
    jobDir: '/v/j',
    context: {
      vaultPath: '/v', paths: shared, sources: [], rebuiltPart: false,
      others: Array.from({ length: 7 }, (_, i) => ({ id: `o${i}`, vaultPath: '/v', paths: shared })),
    },
  });
  assert.match(facts, /\[distill\] A\n\n\[claude\] B$/);
  assert.match(facts, /\nBlocked calls in the last turn:\n- Bash: ls\n/);
  assert.match(facts, /\nWhat Distill already told the session:\n- told\n/);
  assert.match(facts, /\nEarlier attempts:\n- rule answer_denial: failed\n/);
  assert.match(facts, /\n- o5: wiki\/s0\.md, wiki\/s1\.md, wiki\/s2\.md, wiki\/s3\.md, wiki\/s4\.md, wiki\/s5\.md\n/);
  assert.doesNotMatch(facts, /- o6:/);
});

test('the recovery schema: each answer field is typed', () => {
  const schema = JSON.parse(RECOVERY_SCHEMA);
  assert.equal(schema.type, 'object');
  for (const k of ['diagnosis', 'fix', 'reason', 'guidance', 'waitFor']) assert.equal(schema.properties[k].type, 'string', k);
  assert.deepEqual({ ...schema.properties.groups, description: undefined }, { type: 'array', items: { type: 'array', items: { type: 'string' } }, description: undefined });
});
