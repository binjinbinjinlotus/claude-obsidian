/**
 * The three action AI tasks (actionFind, actionDraft, actionImprove): one
 * structured-output run each, with no tools, in an empty scratch directory
 * under the state dir (never the vault). Same checks as label suggestions.
 */
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { runnerSupports, type AITask, type ModelSelection, type RunRequest, type RunnerRegistry, type Settings } from '../contracts.js';
import { modelLabel } from '../engine/image-text.js';
import { isObject } from '../store/json.js';

export type ActionTask = Extract<AITask, 'actionFind' | 'actionDraft' | 'actionImprove'>;

const FIELDS_SCHEMA = {
  type: 'array',
  items: {
    type: 'object',
    additionalProperties: false,
    properties: { key: { type: 'string' }, value: { type: 'string' } },
    required: ['key', 'value'],
  },
};

export const FIND_SCHEMA = JSON.stringify({
  type: 'object',
  additionalProperties: false,
  properties: {
    items: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        properties: {
          type: { type: 'string' },
          title: { type: 'string' },
          // action-summary.md: what the action is about, 2–4 plain sentences.
          summary: { type: 'string' },
          body: { type: 'string' },
          fields: FIELDS_SCHEMA,
          why: { type: 'string' },
          quote: { type: 'string' },
          notePath: { type: 'string' },
          // v11 (action-context.md): the window's line numbers and the wiki sections it relates to.
          lines: { type: 'string' },
          wiki: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              properties: { path: { type: 'string' }, heading: { type: 'string' } },
              required: ['path', 'heading'],
            },
          },
        },
        required: ['type', 'title', 'summary', 'fields', 'why', 'quote'],
      },
    },
  },
  required: ['items'],
});

export const DRAFT_SCHEMA = JSON.stringify({
  type: 'object',
  additionalProperties: false,
  properties: { title: { type: 'string' }, body: { type: 'string' }, fields: FIELDS_SCHEMA },
  required: ['title', 'body', 'fields'],
});

export const SUMMARIZE_SCHEMA = JSON.stringify({
  type: 'object',
  additionalProperties: false,
  properties: { summary: { type: 'string' } },
  required: ['summary'],
});

export const IMPROVE_SCHEMA = JSON.stringify({
  type: 'object',
  additionalProperties: false,
  properties: { body: { type: 'string' } },
  required: ['body'],
});

export interface StructuredRun {
  value: Record<string, unknown>;
  costUSD: number;
  selection: ModelSelection;
  /** "Sonnet" */
  model: string;
}

export interface RunOptions {
  runners: RunnerRegistry;
  settings: Settings;
  task: ActionTask;
  selection: ModelSelection;
  prompt: string;
  schema: string;
  scratchRoot: string;
  signal?: AbortSignal;
}

export function modelName(runners: RunnerRegistry, selection: ModelSelection): string {
  const runner = runners.get(selection.runnerID);
  return modelLabel(runner?.models ?? [], selection.model);
}

/** Pick the structured value, or the first JSON object in the text (runners without schema support). */
function structuredFrom(structured: unknown, text: string): Record<string, unknown> | undefined {
  if (isObject(structured)) return structured;
  const match = /\{[\s\S]*\}/.exec(text);
  if (!match) return undefined;
  try {
    const parsed: unknown = JSON.parse(match[0]);
    return isObject(parsed) ? parsed : undefined;
  } catch {
    return undefined;
  }
}

export async function runStructured(opts: RunOptions): Promise<StructuredRun> {
  const { selection } = opts;
  const runner = opts.runners.get(selection.runnerID);
  if (!runner) throw new Error(`Unknown AI runner ${selection.runnerID}.`);
  if (!opts.settings.enabledRunners.includes(runner.id)) throw new Error(`${runner.displayName} is turned off in Settings.`);
  if (!runnerSupports(runner, opts.task)) throw new Error(`${runner.displayName} can't do this task.`);
  const problem = runner.problems(opts.settings)[0];
  if (problem) throw new Error(problem.message);
  const scratch = path.join(opts.scratchRoot, randomUUID().toLowerCase());
  fs.mkdirSync(scratch, { recursive: true });
  try {
    const request: RunRequest = {
      workingDirectory: scratch,
      prompt: opts.prompt,
      session: { start: randomUUID().toLowerCase() },
      selection,
      allowedTools: [],
      availableTools: [],
      readableDirectories: [],
      outputSchema: opts.schema,
    };
    if (opts.signal) request.signal = opts.signal;
    const result = await runner.run(request, opts.settings);
    if (opts.signal?.aborted) throw new Error('Cancelled.');
    if (result.isError) throw new Error(result.resultText || 'The AI run failed.');
    const value = structuredFrom(result.structured, result.resultText);
    if (!value) throw new Error('The AI returned no usable answer.');
    return { value, costUSD: result.costUSD, selection, model: modelLabel(runner.models, selection.model) };
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

/** [{key, value}] (or a plain object) → fields; empty values dropped. */
export function fieldsFrom(v: unknown): Record<string, string> {
  const out: Record<string, string> = {};
  if (Array.isArray(v)) {
    for (const e of v) {
      if (isObject(e) && typeof e.key === 'string' && typeof e.value === 'string' && e.value.trim() !== '') out[e.key.trim()] = e.value.trim();
    }
  } else if (isObject(v)) {
    for (const [k, x] of Object.entries(v)) if (typeof x === 'string' && x.trim() !== '') out[k] = x.trim();
  }
  return out;
}
