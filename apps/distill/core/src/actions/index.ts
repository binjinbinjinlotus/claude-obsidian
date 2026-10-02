import type { CoreEvent, DistillCore, ModelSelection, Settings } from '../contracts.js';
import type { RunnerRegistry } from '../contracts.js';
import type { ActionsOwned } from '../engine/index.js';
import { notImplemented } from '../engine/errors.js';

export interface ActionsServiceOptions {
  emit: (event: CoreEvent) => void;
  getSettings: () => Settings;
  runners: RunnerRegistry;
  /** <stateDir>/actions.json */
  file: string;
  stateDir: string;
  /** Default selection for an action task when Settings has none. */
  defaultSelection?: (task: 'actionFind' | 'actionDraft' | 'actionImprove') => ModelSelection;
}

export type ActionsService = Pick<DistillCore, ActionsOwned>;

/** Owner: core-actions. Stub until implemented. */
export function createActionsService(_opts: ActionsServiceOptions): ActionsService {
  const ni = (name: string) => async () => notImplemented(name);
  return {
    listActionTypes: ni('listActionTypes'),
    listActions: ni('listActions'),
    getAction: ni('getAction'),
    createAction: ni('createAction'),
    updateAction: ni('updateAction'),
    confirmActions: ni('confirmActions'),
    dismissActions: ni('dismissActions'),
    draftAction: ni('draftAction'),
    improveAction: ni('improveAction'),
    undoImprove: ni('undoImprove'),
    performAction: ni('performAction'),
    sendActionTo: ni('sendActionTo'),
    removeAction: ni('removeAction'),
    restoreAction: ni('restoreAction'),
    deleteActionForever: ni('deleteActionForever'),
    detectAskActions: ni('detectAskActions'),
    listConnections: ni('listConnections'),
    connect: ni('connect'),
    signInURL: ni('signInURL'),
    disconnect: ni('disconnect'),
  } as ActionsService;
}
