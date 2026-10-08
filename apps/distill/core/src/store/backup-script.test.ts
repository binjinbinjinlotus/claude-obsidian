/**
 * distill.sh backup (user-data.md): run against a temp DISTILL_STATE_DIR only. Remembered Slack names
 * and their set-aside copies are backed up.
 */
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../clients/macos/scripts/distill.sh');

test('backup copies actions/slack-people.json and its set-aside copies', () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-backup-'));
  try {
    fs.mkdirSync(path.join(state, 'actions'));
    fs.writeFileSync(path.join(state, 'settings.json'), '{}');
    fs.writeFileSync(path.join(state, 'actions', 'slack-people.json'), '{"version":1,"vaults":{}}');
    fs.writeFileSync(path.join(state, 'actions', 'slack-people.json.unreadable-20261006-120000'), '{ not json');
    fs.writeFileSync(path.join(state, 'actions', 'button-approvals.json'), '{}');
    execFileSync('zsh', [script, 'backup', 'test'], { env: { ...process.env, DISTILL_STATE_DIR: state, DISTILL_JOBS: path.join(state, 'jobs.json') }, stdio: 'pipe' });
    const backups = fs.readdirSync(path.join(state, 'backups'));
    assert.equal(backups.length, 1);
    const actions = fs.readdirSync(path.join(state, 'backups', backups[0]!, 'actions')).sort();
    assert.deepEqual(actions, ['slack-people.json', 'slack-people.json.unreadable-20261006-120000']);
    assert.equal(fs.readFileSync(path.join(state, 'backups', backups[0]!, 'actions', 'slack-people.json.unreadable-20261006-120000'), 'utf8'), '{ not json');
  } finally {
    fs.rmSync(state, { recursive: true, force: true });
  }
});
