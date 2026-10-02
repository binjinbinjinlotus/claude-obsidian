import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, it } from 'node:test';
import { statePaths } from '../store/paths.js';
import type { StatePaths } from '../contracts.js';
import { createFakeCore } from './fake-core.js';
import { runServer } from './index.js';
import {
  ServerAlreadyRunningError,
  assertNoLiveServer,
  ensureToken,
  isPidAlive,
  liveServer,
  readLock,
  releaseLock,
  writeLock,
} from './lifecycle.js';

async function deadPid(): Promise<number> {
  const child = spawn(process.execPath, ['-e', '0'], { stdio: 'ignore' });
  const pid = child.pid!;
  await new Promise((r) => child.on('exit', r));
  return pid;
}

describe('server lifecycle', () => {
  let dir: string;
  let paths: StatePaths;

  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-lifecycle-'));
    paths = statePaths(path.join(dir, 'state'));
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  it('creates a 64-hex token with mode 0600 and reuses it', () => {
    const token = ensureToken(paths);
    assert.match(token, /^[0-9a-f]{64}$/);
    assert.equal(fs.readFileSync(paths.token, 'utf8'), token); // no trailing newline
    assert.equal(fs.statSync(paths.token).mode & 0o777, 0o600);
    assert.equal(ensureToken(paths), token);
  });

  it('tightens an existing token file to 0600', () => {
    fs.mkdirSync(paths.dir, { recursive: true });
    fs.writeFileSync(paths.token, 'c'.repeat(64), { mode: 0o644 });
    fs.chmodSync(paths.token, 0o644);
    assert.equal(ensureToken(paths), 'c'.repeat(64));
    assert.equal(fs.statSync(paths.token).mode & 0o777, 0o600);
  });

  it('isPidAlive: self and parent alive, exited child dead', async () => {
    assert.equal(isPidAlive(process.pid), true);
    assert.equal(isPidAlive(process.ppid), true);
    assert.equal(isPidAlive(await deadPid()), false);
    assert.equal(isPidAlive(0), false);
  });

  it('writes, reads and releases the lock', () => {
    const lock = writeLock(paths, { port: 1234, startedAt: '2026-10-01T00:00:00Z', version: '0.1.0' });
    assert.deepEqual(readLock(paths), lock);
    assert.equal(lock.pid, process.pid);
    assert.deepEqual(liveServer(paths), lock);
    assert.equal(fs.readdirSync(paths.dir).filter((f) => f.endsWith('.tmp')).length, 0);
    releaseLock(paths);
    assert.equal(fs.existsSync(paths.serverLock), false);
  });

  it('does not release a lock owned by another pid', () => {
    writeLock(paths, { pid: process.ppid, port: 1, startedAt: '', version: '' });
    releaseLock(paths);
    assert.equal(fs.existsSync(paths.serverLock), true);
  });

  it('replaces a stale lock (dead pid) and a malformed lock', async () => {
    writeLock(paths, { pid: await deadPid(), port: 1, startedAt: '', version: '' });
    assert.equal(liveServer(paths), null);
    assert.doesNotThrow(() => assertNoLiveServer(paths));
    assert.equal(fs.existsSync(paths.serverLock), false);

    writeLock(paths, { pid: await deadPid(), port: 1, startedAt: '', version: '' });
    const lock = writeLock(paths, { port: 2, startedAt: '', version: '' });
    assert.equal(readLock(paths)?.pid, process.pid);
    assert.equal(lock.port, 2);

    fs.writeFileSync(paths.serverLock, '{garbage');
    assert.doesNotThrow(() => assertNoLiveServer(paths));
    assert.equal(fs.existsSync(paths.serverLock), false);
  });

  it('refuses to claim the lock when a live server holds it', () => {
    writeLock(paths, { pid: process.ppid, port: 9, startedAt: '', version: '' });
    assert.throws(() => assertNoLiveServer(paths), ServerAlreadyRunningError);
    assert.throws(() => writeLock(paths, { port: 2, startedAt: '', version: '' }), ServerAlreadyRunningError);
    assert.equal(readLock(paths)?.pid, process.ppid);
  });

  it('runServer writes server.json after listening, refuses a second server, cleans up on shutdown', async () => {
    const core = createFakeCore();
    const handle = await runServer({ paths, createCore: () => core, handleSignals: false, log: () => undefined });
    const lock = readLock(paths);
    assert.equal(lock?.pid, process.pid);
    assert.equal(lock?.port, handle.port);
    assert.ok(handle.port > 0);
    assert.match(lock?.version ?? '', /^\d+\.\d+\.\d+/);
    assert.ok(core.calls.some((c) => c.method === 'start'));

    const token = fs.readFileSync(paths.token, 'utf8').trim();
    const res = await fetch(`http://127.0.0.1:${handle.port}/v1/status`, { headers: { authorization: `Bearer ${token}` } });
    assert.equal(res.status, 200);

    // Second server in another process: the lock holder (this process) is alive.
    writeLockAsOther();
    await assert.rejects(
      runServer({ paths, createCore: () => createFakeCore(), handleSignals: false, log: () => undefined }),
      ServerAlreadyRunningError,
    );
    restoreOwnLock(handle.port);

    await handle.shutdown();
    await handle.done;
    assert.equal(fs.existsSync(paths.serverLock), false);
    assert.ok(core.calls.some((c) => c.method === 'stop'));

    function writeLockAsOther() {
      fs.writeFileSync(paths.serverLock, JSON.stringify({ pid: process.ppid, port: handle.port, startedAt: '', version: '' }));
    }
    function restoreOwnLock(port: number) {
      fs.writeFileSync(paths.serverLock, JSON.stringify({ pid: process.pid, port, startedAt: '', version: '' }));
    }
  });

  it('runServer leaves no server.json when the core fails to start', async () => {
    await assert.rejects(
      runServer({
        paths,
        createCore: () => {
          throw new Error('engine: not implemented');
        },
        handleSignals: false,
        log: () => undefined,
      }),
      /not implemented/,
    );
    assert.equal(fs.existsSync(paths.serverLock), false);
  });
});
