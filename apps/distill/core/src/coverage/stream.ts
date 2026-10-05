/**
 * What a turn read and wrote, from Claude Code's stream-json (full-read.md, section 3). Numbers and
 * paths only: never what a file says or what a tool returned.
 *
 * - A Read is credited with the lines the tool RETURNED: the top-level `tool_use_result.file`
 *   {filePath, startLine, numLines, totalLines} on the user event (verified on CLI 2.1.289), or, on
 *   an older CLI, the first and last line numbers in the result text. A failed read credits nothing.
 * - Steps of a subagent (`parent_tool_use_id`) are left out.
 * - A compaction is a `compact_boundary` system event, or the context shrinking: a main-thread
 *   assistant message whose context (input + cache read + cache creation) is under 60% of the one
 *   before, within the session (`prevContext` carries it across turns). Messages with no usage
 *   are skipped.
 */

export type StreamEvent =
  | { t: 'read'; seq: number; path: string; from: number; to: number; total?: number; cut?: boolean; whole?: boolean }
  | { t: 'write'; seq: number; path: string }
  | { t: 'compact'; seq: number };

export interface ParsedTurn {
  events: StreamEvent[];
  nextSeq: number;
  /** The last main-thread context size seen (tokens), for the next turn's comparison. */
  lastContext: number;
  /** contextWindow from the result event's modelUsage, by model id. */
  contextWindows: Record<string, number>;
}

export const COMPACTION_RATIO = 0.6;

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

function num(v: unknown): number | undefined {
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined;
}

/** First and last line numbers of a Read result's text (`   12→…` or `12\t…`). */
export function lineSpanOfText(text: string): { from: number; to: number } | undefined {
  let from: number | undefined;
  let to: number | undefined;
  for (const line of text.split('\n')) {
    const m = /^\s*(\d+)(?:→|\t)/.exec(line);
    if (!m) continue;
    const n = Number(m[1]);
    if (from === undefined) from = n;
    to = n;
  }
  return from !== undefined && to !== undefined && to >= from ? { from, to } : undefined;
}

function resultText(c: Record<string, unknown>): string {
  const content = c.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((x) => (isObj(x) && typeof x.text === 'string' ? x.text : '')).join('\n');
  return '';
}

const WRITE_TOOLS = new Set(['Write', 'Edit', 'MultiEdit', 'NotebookEdit']);

export function parseTurn(raw: string, startSeq = 0, prevContext = 0): ParsedTurn {
  const events: StreamEvent[] = [];
  const calls = new Map<string, { name: string; input: Record<string, unknown> }>();
  let seq = startSeq;
  let last = prevContext;
  const contextWindows: Record<string, number> = {};
  for (const line of raw.split('\n')) {
    const t = line.trim();
    if (!t.startsWith('{')) continue;
    let obj: unknown;
    try {
      obj = JSON.parse(t);
    } catch {
      continue;
    }
    if (!isObj(obj)) continue;
    if (obj.type === 'system' && obj.subtype === 'compact_boundary') {
      events.push({ t: 'compact', seq: ++seq });
      last = 0;
      continue;
    }
    if (obj.type === 'result' && isObj(obj.modelUsage)) {
      for (const [model, u] of Object.entries(obj.modelUsage)) {
        const w = isObj(u) ? num(u.contextWindow) : undefined;
        if (w) contextWindows[model] = w;
      }
      continue;
    }
    if (typeof obj.parent_tool_use_id === 'string') continue;
    const msg = obj.message;
    if (!isObj(msg)) continue;
    if (obj.type === 'assistant') {
      const u = msg.usage;
      if (isObj(u)) {
        const ctx = (num(u.input_tokens) ?? 0) + (num(u.cache_read_input_tokens) ?? 0) + (num(u.cache_creation_input_tokens) ?? 0);
        if (ctx > 0) {
          if (last > 0 && ctx < last * COMPACTION_RATIO) events.push({ t: 'compact', seq: ++seq });
          last = ctx;
        }
      }
      if (!Array.isArray(msg.content)) continue;
      for (const c of msg.content) {
        if (!isObj(c) || c.type !== 'tool_use' || typeof c.id !== 'string' || typeof c.name !== 'string') continue;
        const input = isObj(c.input) ? c.input : {};
        calls.set(c.id, { name: c.name, input });
        if (WRITE_TOOLS.has(c.name)) {
          const p = typeof input.file_path === 'string' ? input.file_path : typeof input.notebook_path === 'string' ? input.notebook_path : '';
          if (p) events.push({ t: 'write', seq: ++seq, path: p });
        }
      }
      continue;
    }
    if (obj.type !== 'user' || !Array.isArray(msg.content)) continue;
    const results = msg.content.filter((c) => isObj(c) && c.type === 'tool_result').length;
    // The event-level result describes its one tool result; with several, each falls back to its text.
    const meta = results !== 1 ? undefined : isObj(obj.tool_use_result) ? obj.tool_use_result : isObj(obj.toolUseResult) ? obj.toolUseResult : undefined;
    for (const c of msg.content) {
      if (!isObj(c) || c.type !== 'tool_result' || typeof c.tool_use_id !== 'string') continue;
      const call = calls.get(c.tool_use_id);
      if (!call || call.name !== 'Read' || c.is_error === true) continue;
      const asked = typeof call.input.file_path === 'string' ? call.input.file_path : '';
      const file = meta && isObj(meta.file) ? meta.file : undefined;
      const cut = meta?.truncatedByTokenCap === true || file?.truncatedByTokenCap === true;
      const p = (file && typeof file.filePath === 'string' ? file.filePath : '') || asked;
      if (!p) continue;
      const start = file ? num(file.startLine) : undefined;
      const count = file ? num(file.numLines) : undefined;
      const total = file ? num(file.totalLines) : undefined;
      if (start !== undefined && count !== undefined) {
        if (count > 0) events.push({ t: 'read', seq: ++seq, path: p, from: start, to: start + count - 1, ...(total !== undefined ? { total } : {}), ...(cut ? { cut } : {}) });
        continue;
      }
      const span = lineSpanOfText(resultText(c));
      if (span) events.push({ t: 'read', seq: ++seq, path: p, from: span.from, to: span.to, ...(cut ? { cut } : {}) });
      // A PDF or image read: no line numbers; one successful read counts for the whole file.
      else events.push({ t: 'read', seq: ++seq, path: p, from: 1, to: 1, whole: true });
    }
  }
  return { events, nextSeq: seq, lastContext: last, contextWindows };
}
