import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { decodeJob, encodeJob, newJob } from './jobs.js';
import { actionPreferences, decodeSettings, encodeSettings, selectionFor } from './settings.js';

describe('v3: actionPreferences and the job actions summary', () => {
  test('actionPreferences decode leniently, keep unknown keys, and default when absent', () => {
    assert.equal(decodeSettings({}).actionPreferences, undefined);
    const defaults = actionPreferences(decodeSettings({}));
    assert.equal(defaults.historyDays, 90);
    assert.equal(defaults.sources.notes.confirm, true);
    assert.equal(defaults.sources.ask.detectTypes, true);

    const s = decodeSettings({
      actionPreferences: {
        sources: { notes: { detectTodos: 'yes', confirm: false, disabledTypes: ['jira', 3], futureFlag: 1 } },
        types: {
          slack: { enabled: false, draftWhen: 'sometimes', draftPrompt: null, improvePrompt: 'Polish {body}', fieldDefaults: { to: '#x', n: 2 } },
          jira: 'nonsense',
        },
        findSelection: { runnerID: 'codex', model: 'gpt-5' },
        todo: { defaultSort: 'bogus', defaultGroup: 'note' },
        historyDays: 0,
        newerKey: { a: 1 },
      },
    });
    const ap = s.actionPreferences!;
    assert.equal(ap.sources!.notes.confirm, false);
    assert.equal('detectTodos' in ap.sources!.notes, false, 'a mistyped key takes its default');
    assert.deepEqual(ap.sources!.notes.disabledTypes, ['jira']);
    assert.equal((ap.sources!.notes as unknown as Record<string, unknown>).futureFlag, 1, 'unknown nested keys survive');
    assert.equal(ap.types!.slack!.enabled, false);
    assert.equal(ap.types!.slack!.draftWhen, undefined);
    assert.equal(ap.types!.slack!.draftPrompt, null, 'null = Reset to default');
    assert.deepEqual(ap.types!.slack!.fieldDefaults, { to: '#x' });
    assert.equal(ap.types!.jira, undefined);
    assert.deepEqual(ap.findSelection, { runnerID: 'codex', model: 'gpt-5' });
    assert.equal(ap.historyDays, 0, 'forever is not clamped');

    const merged = actionPreferences(s);
    assert.equal(merged.sources.notes.detectTodos, true);
    assert.equal(merged.sources.notes.confirm, false);
    assert.equal(merged.todo.defaultSort, 'due');
    assert.equal(merged.todo.defaultGroup, 'note');

    const encoded = encodeSettings(s);
    assert.deepEqual((encoded.actionPreferences as Record<string, unknown>).newerKey, { a: 1 });
    assert.deepEqual(decodeSettings(JSON.parse(JSON.stringify(encoded))).actionPreferences, ap);
    assert.equal('actionPreferences' in encodeSettings(decodeSettings({})), false, 'absent stays absent');
  });

  test('the action tasks default to Claude Code · Sonnet', () => {
    const s = decodeSettings({});
    for (const t of ['actionFind', 'actionDraft', 'actionImprove'] as const) {
      assert.deepEqual(selectionFor(s, t), { runnerID: 'claude-code', model: 'sonnet', effort: null });
    }
  });

  test('Job.actionsFound round-trips through jobs.json', () => {
    const job = newJob({ id: 'job-2', kind: 'ingest', files: ['a.md'], vaultPath: '/v', model: 'sonnet', now: new Date('2026-10-02T10:00:00Z') });
    job.actionsFound = { status: 'done', found: 3, pending: 3, added: 0, byType: { todo: 2, slack: 1 }, model: 'Sonnet' };
    const encoded = encodeJob(job);
    assert.deepEqual(decodeJob(JSON.parse(JSON.stringify(encoded)))!.actionsFound, job.actionsFound);
    assert.equal(decodeJob({ ...encoded, actionsFound: 'x' })!.actionsFound, undefined);
  });
});
