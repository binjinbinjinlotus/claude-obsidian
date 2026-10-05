/**
 * The activity log and Distill's trash. Spec: apps/distill/docs/specs/activity-log.md
 */
import fs from 'node:fs';
import path from 'node:path';
import { CoreError, type ActivityApi, type ActivityQuery, type Collector, type CoreEvent, type RestoreResult } from '../contracts.js';
import { summaryOf, type ConversationRecord, isValidConversationID } from '../ask/conversations.js';
import { currentSource } from './context.js';
import { ActivityLog, type ActivityLogOptions } from './log.js';
import { Trash, type TrashOptions } from './trash.js';

export { ActivityLog, ACTIVITY_DEFAULTS, newActivityID } from './log.js';
export { Trash, TRASH_DEFAULTS } from './trash.js';
export { instrumentCore, createEventLogger, settingsChanges, jobName, classifiedMethods, type Specs } from './instrument.js';
export { runWithSource, asScheduler, currentSource, sourceFromHeaders, CLIENT_HEADER } from './context.js';
export { redactText, redactDetails, REDACTED } from './redact.js';

export interface ActivityServiceOptions {
  /** <state> */
  stateDir: string;
  /** <state>/ask */
  askDir: string;
  now?: () => Date;
  emit: (event: CoreEvent) => void;
  /** v6: `files` is the trash copy of the script collector's folder, when it has one. */
  restoreCollector: (record: unknown, files?: string) => Promise<Collector>;
  log?: Partial<Omit<ActivityLogOptions, 'dir' | 'now'>>;
  trash?: Partial<Omit<TrashOptions, 'dir' | 'now'>>;
}

export interface ActivityService extends ActivityApi {
  log: ActivityLog;
  trash: Trash;
}

export function createActivityService(opts: ActivityServiceOptions): ActivityService {
  const log = new ActivityLog({ dir: path.join(opts.stateDir, 'activity'), ...(opts.now ? { now: opts.now } : {}), ...opts.log });
  const trash = new Trash({ dir: path.join(opts.stateDir, 'trash'), ...(opts.now ? { now: opts.now } : {}), ...opts.trash });

  async function restoreFromTrash(id: string): Promise<RestoreResult> {
    let kept: ReturnType<Trash['get']>;
    try {
      kept = trash.get(id);
    } catch {
      kept = undefined;
    }
    if (!kept) throw new CoreError('not_found', `No trash item ${id} (it may have expired).`);
    const { item, payload } = kept;
    const source = currentSource();
    try {
      let result: RestoreResult;
      if (item.kind === 'chat') {
        const record = payload as ConversationRecord;
        if (!record || typeof record !== 'object' || !isValidConversationID(String(record.conversationID))) {
          throw new CoreError('invalid_request', "The trash copy isn't a chat this build can read.");
        }
        const file = path.join(opts.askDir, `${record.conversationID}.json`);
        fs.mkdirSync(opts.askDir, { recursive: true });
        // Retention counts from updatedAt: a restored chat starts its days again, so the next
        // sweep doesn't remove it within the hour (decision 2026-10-04).
        const restored: ConversationRecord = { ...record, updatedAt: (opts.now ? opts.now() : new Date()).toISOString() };
        const temp = `${file}.${process.pid}.restore.tmp`;
        fs.writeFileSync(temp, JSON.stringify(restored, null, 2) + '\n', { mode: 0o600 });
        try {
          // link() fails if the chat exists: an atomic create-only rename.
          fs.linkSync(temp, file);
        } catch (err) {
          if ((err as NodeJS.ErrnoException).code === 'EEXIST') throw new CoreError('conflict', `A chat with id ${record.conversationID} already exists.`);
          throw err;
        } finally {
          fs.rmSync(temp, { force: true });
        }
        opts.emit({ type: 'conversation', conversation: summaryOf(restored) });
        result = { item, objectID: record.conversationID };
      } else {
        const c = await opts.restoreCollector(payload, kept.files);
        result = { item, objectID: c.id, ...(c.kind === 'script' ? { note: 'The script collector is off; review and allow its script to turn it on.' } : {}) };
      }
      trash.remove(id);
      log.record({
        type: `${item.kind}.restored`,
        source,
        outcome: 'ok',
        object: { kind: item.kind, id: result.objectID, name: item.name },
        summary: `Restored the ${item.kind} “${item.name}” from Distill's trash${result.note ? ' (off until you allow its script)' : ''}`,
        details: { trashId: id, deletedAt: item.deletedAt, ...(result.objectID !== item.objectID ? { previousID: item.objectID } : {}) },
      });
      return result;
    } catch (err) {
      log.record({
        type: `${item.kind}.restored`,
        source,
        outcome: 'failed',
        object: { kind: item.kind, id: item.objectID, name: item.name },
        summary: `Couldn't restore the ${item.kind} “${item.name}”`,
        error: err instanceof Error ? err.message : String(err),
      });
      throw err;
    }
  }

  return {
    log,
    trash,
    async listActivity(query?: ActivityQuery) {
      return log.list(query);
    },
    async listTrash() {
      return trash.list();
    },
    restoreFromTrash,
  };
}
