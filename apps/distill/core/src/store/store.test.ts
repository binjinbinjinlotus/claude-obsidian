import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, test } from 'node:test';
import { isoDate } from './json.js';
import { encodeJob, JobStore, MAX_STORED_JOBS, newJob, RECOVERY_NOTE } from './jobs.js';
import { SettingsStore } from './settings.js';
import { statePaths } from './paths.js';

/** What Swift's JSONEncoder([.prettyPrinted, .sortedKeys], .iso8601) actually writes. */
const SWIFT_SETTINGS = `{
  "activeVaultPath" : "\\/Users\\/me\\/Vault",
  "autoProcessEnabled" : false,
  "batchIntervalMinutes" : 15,
  "claudePath" : "\\/Users\\/me\\/.local\\/bin\\/claude",
  "enabledRunners" : [
    "claude-code"
  ],
  "extraAllowedTools" : [
    "WebFetch(domain:example.com)"
  ],
  "futureFeature" : {
    "labels" : [
      "tea"
    ]
  },
  "model" : "opus",
  "productRoot" : "\\/Users\\/me\\/claude-obsidian",
  "pythonPath" : "\\/usr\\/bin\\/python3",
  "settleSeconds" : 5,
  "taskDefaults" : {
    "ask" : {
      "effort" : "high",
      "model" : "sonnet",
      "runnerID" : "claude-code"
    }
  },
  "vaults" : [
    {
      "path" : "\\/Users\\/me\\/Vault",
      "queueDirectory" : "\\/Users\\/me\\/Documents\\/Distill Queue\\/Vault"
    }
  ]
}`;

const SWIFT_JOBS = `[
  {
    "approval" : {
      "bundlePath" : "\\/Users\\/me\\/Vault\\/.vault-meta\\/worker\\/job-20261001-154200-ab12\\/bundle.json",
      "denials" : [
        {
          "input" : {
            "command" : "ls \\/"
          },
          "toolName" : "Bash"
        }
      ],
      "plan" : {
        "approval_sha256" : "abc123",
        "changed_paths" : [
          "wiki\\/a.md"
        ],
        "operation_id" : "op-1",
        "operation_type" : "ingest",
        "valid" : true
      },
      "questions" : [

      ],
      "skipped" : [

      ],
      "summary" : "Adds one page."
    },
    "changedPaths" : [

    ],
    "createdAt" : "2026-10-01T15:42:00Z",
    "files" : [
      "inbox\\/a.md"
    ],
    "grantedTools" : [

    ],
    "id" : "job-20261001-154200-ab12",
    "kind" : "ingest",
    "model" : "sonnet",
    "runnerID" : "claude-code",
    "sessionID" : "0b6c3d0e-1f1e-4c39-9e43-3c1f0f0e8a11",
    "state" : "awaitingApproval",
    "swiftOnlyField" : 42,
    "turns" : [
      {
        "author" : "app",
        "costUSD" : 0,
        "date" : "2026-10-01T15:42:00Z",
        "id" : "6E1C1B3A-9C59-4C8B-8D0B-0F8F2C1E4A10",
        "text" : "Batched 1 file(s):\\n- inbox\\/a.md"
      },
      {
        "author" : "worker",
        "costUSD" : 0.0213,
        "date" : "2026-10-01T15:43:10Z",
        "id" : "7E1C1B3A-9C59-4C8B-8D0B-0F8F2C1E4A10",
        "text" : "Adds one page."
      }
    ],
    "updatedAt" : "2026-10-01T15:43:10Z",
    "vaultPath" : "\\/Users\\/me\\/Vault"
  },
  {
    "changedPaths" : [],
    "createdAt" : "2026-09-30T10:00:00Z",
    "files" : ["inbox\\/b.md"],
    "grantedTools" : [],
    "id" : "job-20260930-100000-cd34",
    "kind" : "ingest",
    "model" : "haiku",
    "sessionID" : "s-2",
    "state" : "running",
    "turns" : [],
    "updatedAt" : "2026-09-30T10:00:00Z",
    "vaultPath" : "\\/Users\\/me\\/Vault"
  }
]`;

let tmp: string;
beforeEach(() => {
  tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'distill-store-')));
});
afterEach(() => fs.rmSync(tmp, { recursive: true, force: true }));

describe('statePaths', () => {
  test('honors an explicit directory', () => {
    const p = statePaths(tmp);
    assert.equal(p.settings, path.join(tmp, 'settings.json'));
    assert.equal(p.jobs, path.join(tmp, 'jobs.json'));
  });
});

describe('SettingsStore', () => {
  test('decodes a Swift-written settings.json', () => {
    const file = path.join(tmp, 'settings.json');
    fs.writeFileSync(file, SWIFT_SETTINGS);
    const s = new SettingsStore(file).load();
    assert.equal(s.activeVaultPath, '/Users/me/Vault');
    assert.equal(s.autoProcessEnabled, false);
    assert.equal(s.batchIntervalMinutes, 15);
    assert.equal(s.settleSeconds, 5);
    assert.equal(s.model, 'opus');
    assert.deepEqual(s.vaults, [{ path: '/Users/me/Vault', queueDirectory: '/Users/me/Documents/Distill Queue/Vault' }]);
    assert.deepEqual(s.taskDefaults.ask, { runnerID: 'claude-code', model: 'sonnet', effort: 'high' });
    assert.deepEqual(s.extraAllowedTools, ['WebFetch(domain:example.com)']);
  });

  test('missing and mistyped keys fall back to defaults', () => {
    const file = path.join(tmp, 'settings.json');
    fs.writeFileSync(file, '{"model":"haiku","settleSeconds":"soon"}');
    const s = new SettingsStore(file).load();
    assert.equal(s.model, 'haiku');
    assert.equal(s.settleSeconds, 10);
    assert.equal(s.batchIntervalMinutes, 10);
    assert.equal(s.autoProcessEnabled, true);
    assert.deepEqual(s.enabledRunners, ['claude-code']);
    assert.equal(s.pythonPath, '/usr/bin/python3');
    assert.equal(s.claudePath, path.join(os.homedir(), '.local/bin/claude'));
    assert.equal(s.activeVaultPath, undefined);
  });

  test('round-trip preserves unknown keys and omits nil optionals', () => {
    const file = path.join(tmp, 'settings.json');
    fs.writeFileSync(file, SWIFT_SETTINGS);
    const store = new SettingsStore(file);
    const s = store.load();
    s.model = 'haiku';
    delete s.activeVaultPath;
    store.save(s);
    const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
    assert.deepEqual(raw.futureFeature, { labels: ['tea'] });
    assert.equal(raw.model, 'haiku');
    assert.equal('activeVaultPath' in raw, false);
    assert.equal('nodePath' in raw, false);
    assert.deepEqual(Object.keys(raw), [...Object.keys(raw)].sort(), 'sorted keys like Swift');
    assert.deepEqual(fs.readdirSync(tmp), ['settings.json'], 'atomic write leaves no temp file');
  });

  test('missing file loads defaults', () => {
    const s = new SettingsStore(path.join(tmp, 'nope.json')).load();
    assert.deepEqual(s.vaults, []);
    assert.equal(s.model, 'sonnet');
  });
});

describe('JobStore', () => {
  test('decodes Swift-written jobs.json and recovers a running job', () => {
    const file = path.join(tmp, 'jobs.json');
    fs.writeFileSync(file, SWIFT_JOBS);
    const jobs = new JobStore(file).load();
    assert.equal(jobs.length, 2);
    const [a, b] = jobs;
    assert.equal(a!.state, 'awaitingApproval');
    assert.equal(a!.approval?.plan?.approval_sha256, 'abc123');
    assert.deepEqual(a!.approval?.denials, [{ toolName: 'Bash', input: { command: 'ls /' } }]);
    assert.equal(a!.turns[1]!.costUSD, 0.0213);
    assert.equal(a!.turns[0]!.text, 'Batched 1 file(s):\n- inbox/a.md');
    assert.equal(a!.vaultPath, '/Users/me/Vault');
    assert.equal(b!.runnerID, undefined);
    assert.equal(b!.state, 'awaitingApproval', 'running at load becomes awaitingApproval');
    assert.equal(b!.approval?.summary, RECOVERY_NOTE);
    assert.equal(b!.sessionID, 's-2', 'recovery keeps the session');
  });

  test('round-trip preserves unknown keys and writes every required key', () => {
    const file = path.join(tmp, 'jobs.json');
    fs.writeFileSync(file, SWIFT_JOBS);
    const store = new JobStore(file);
    const jobs = store.load();
    store.save(jobs);
    const raw = JSON.parse(fs.readFileSync(file, 'utf8')) as Record<string, unknown>[];
    assert.equal(raw[0]!.swiftOnlyField, 42);
    for (const key of ['id', 'kind', 'vaultPath', 'files', 'sessionID', 'model', 'state', 'createdAt', 'updatedAt', 'turns', 'grantedTools', 'changedPaths']) {
      assert.ok(key in raw[1]!, key);
    }
    assert.equal('runnerID' in raw[1]!, false, 'nil optionals are omitted, never null');
    assert.equal('error' in raw[0]!, false);
    const approval = raw[0]!.approval as Record<string, unknown>;
    for (const key of ['summary', 'questions', 'denials', 'skipped']) assert.ok(key in approval, key);
    assert.ok(!JSON.stringify(raw).includes('null'));
  });

  test('dates have no fractional seconds', () => {
    assert.equal(isoDate(new Date('2026-10-01T15:42:00.123Z')), '2026-10-01T15:42:00Z');
    const job = newJob({ id: 'j', kind: 'ingest', vaultPath: '/v', files: [], model: 'm', now: new Date('2026-10-01T15:42:00.999Z') });
    const enc = encodeJob(job);
    assert.equal(enc.createdAt, '2026-10-01T15:42:00Z');
    assert.match(job.sessionID, /^[0-9a-f-]{36}$/);
  });

  test('caps at 300 jobs, newest first', () => {
    const file = path.join(tmp, 'jobs.json');
    const store = new JobStore(file);
    const now = new Date();
    const jobs = Array.from({ length: MAX_STORED_JOBS + 5 }, (_, i) =>
      newJob({ id: `job-${i}`, kind: 'ingest', vaultPath: '/v', files: [], model: 'm', now }),
    );
    store.save(jobs);
    const back = store.load();
    assert.equal(back.length, MAX_STORED_JOBS);
    assert.equal(back[0]!.id, 'job-0');
  });

  test('skips undecodable entries instead of dropping the file', () => {
    const file = path.join(tmp, 'jobs.json');
    fs.writeFileSync(file, '[{"nope":true},{"id":"j","vaultPath":"/v","state":"completed"}]');
    const jobs = new JobStore(file).load();
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0]!.kind, 'ingest');
    assert.deepEqual(jobs[0]!.turns, []);
  });
});
