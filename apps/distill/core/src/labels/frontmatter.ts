/**
 * Flat-YAML frontmatter for labels: a dependency-free reader (same subset as
 * ask/frontmatter.ts, copied so the two owners stay independent) and an editor
 * that rewrites only the label properties (`tags`, `labels_by`,
 * `labels_reviewed`, `labels_origin`) and keeps every other byte of the page.
 */

export type FrontmatterValue = string | string[];
export type Frontmatter = Record<string, FrontmatterValue>;

const KEY_LINE = /^([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*:(?:\s+(.*))?$/;
const LIST_ITEM = /^\s*-(?:\s+(.*)|$)/;
const BOM = '﻿';

/** Strip matching quotes; drop a trailing ` # comment` from an unquoted value. */
export function unquote(raw: string): string {
  const value = raw.trim();
  if (value.length >= 2) {
    const first = value[0];
    if ((first === '"' || first === "'") && value.endsWith(first)) {
      const inner = value.slice(1, -1);
      return first === "'" ? inner.replace(/''/g, "'") : inner.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
  }
  return value.replace(/\s+#.*$/, '').trim();
}

function splitFlowList(inner: string): string[] {
  const items: string[] = [];
  let current = '';
  let quote: string | null = null;
  for (const ch of inner) {
    if (quote) {
      current += ch;
      if (ch === quote) quote = null;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      current += ch;
    } else if (ch === ',') {
      items.push(current);
      current = '';
    } else {
      current += ch;
    }
  }
  items.push(current);
  return items.map(unquote).filter((item) => item.length > 0);
}

/** Lines of the text with their terminators kept, so joining them gives the text back. */
function splitKeepingEnds(text: string): string[] {
  return text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
}

const stripEnd = (line: string) => line.replace(/\r?\n$/, '');

interface Block {
  /** Index of the opening `---` line. */
  open: number;
  /** Index of the closing `---`/`...` line. */
  close: number;
}

function findBlock(lines: string[]): Block | undefined {
  if (lines.length === 0 || stripEnd(lines[0]!).trimEnd() !== '---') return undefined;
  for (let i = 1; i < lines.length; i++) {
    const l = stripEnd(lines[i]!).trimEnd();
    if (l === '---' || l === '...') return { open: 0, close: i };
  }
  return undefined;
}

export function parseFrontmatter(text: string): Frontmatter {
  const lines = splitKeepingEnds(text.startsWith(BOM) ? text.slice(1) : text);
  const block = findBlock(lines);
  const result: Frontmatter = {};
  if (!block) return result;
  let listKey: string | null = null;
  for (const raw of lines.slice(block.open + 1, block.close)) {
    const line = stripEnd(raw);
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue;
    const item = LIST_ITEM.exec(line);
    if (item && listKey !== null) {
      const value = unquote(item[1] ?? '');
      const list = result[listKey];
      if (Array.isArray(list) && value.length > 0) list.push(value);
      continue;
    }
    if (/^\s/.test(line)) continue;
    listKey = null;
    const match = KEY_LINE.exec(line);
    if (!match) continue;
    const key = match[1]!;
    const value = (match[2] ?? '').trim();
    if (value === '') {
      result[key] = [];
      listKey = key;
    } else if (value.startsWith('[') && value.endsWith(']')) {
      result[key] = splitFlowList(value.slice(1, -1));
    } else {
      result[key] = unquote(value);
    }
  }
  return result;
}

export function listValue(fm: Frontmatter, key: string): string[] {
  const value = fm[key];
  if (value === undefined) return [];
  return Array.isArray(value) ? value : value === '' ? [] : [value];
}

export function scalarValue(fm: Frontmatter, key: string): string | undefined {
  const value = fm[key];
  if (Array.isArray(value)) return value[0];
  return value === '' ? undefined : value;
}

/** The text after the frontmatter block (the whole text when there is none). */
export function bodyOf(text: string): string {
  const t = text.startsWith(BOM) ? text.slice(1) : text;
  const lines = splitKeepingEnds(t);
  const block = findBlock(lines);
  return block ? lines.slice(block.close + 1).join('') : t;
}

// ───────────── editing ─────────────

export const LABEL_KEYS = ['tags', 'labels_by', 'labels_reviewed', 'labels_origin'] as const;

/** What the label properties should become. Every LABEL_KEYS key not set here is removed. */
export interface LabelProperties {
  /** Empty = no `tags` property. */
  tags: string[];
  labels_by?: 'ai' | 'user';
  /** Only `false` is ever written (absent = confirmed). */
  labels_reviewed?: false;
  labels_origin?: string;
}

const YAML_RESERVED = /^(?:true|false|yes|no|on|off|null|y|n|~)$/i;

/** A tag as a YAML scalar: plain when safe, otherwise a JSON (= YAML double-quoted) string. */
export function yamlScalar(value: string): string {
  const plain =
    /^[\p{L}\p{N}_][\p{L}\p{N}_\-/.]*$/u.test(value) && !YAML_RESERVED.test(value) && !/^[-+]?[\d.]+(?:e[-+]?\d+)?$/i.test(value);
  return plain ? value : JSON.stringify(value);
}

function propertyLines(props: LabelProperties, eol: string): string[] {
  const out: string[] = [];
  if (props.tags.length > 0) {
    out.push('tags:' + eol);
    for (const tag of props.tags) out.push(`  - ${yamlScalar(tag)}` + eol);
  }
  if (props.labels_by) out.push(`labels_by: ${props.labels_by}` + eol);
  if (props.labels_reviewed === false) out.push('labels_reviewed: false' + eol);
  if (props.labels_origin) out.push(`labels_origin: ${yamlScalar(props.labels_origin)}` + eol);
  return out;
}

/**
 * Replace the label properties in a Markdown page. Other frontmatter lines,
 * the body, the BOM and line endings are kept exactly; the new properties go
 * where `tags` was (else where the first label property was, else at the end
 * of the block). A page without frontmatter gets a new block; a block left
 * empty is removed.
 */
export function setLabelProperties(text: string, props: LabelProperties): string {
  const bom = text.startsWith(BOM) ? BOM : '';
  const t = bom ? text.slice(1) : text;
  const lines = splitKeepingEnds(t);
  const block = findBlock(lines);
  const eol = /\r\n/.test(lines[0] ?? '') ? '\r\n' : '\n';
  const added = propertyLines(props, eol);

  if (!block) {
    if (added.length === 0) return text;
    return bom + ['---' + eol, ...added, '---' + eol].join('') + t;
  }

  const inner = lines.slice(block.open + 1, block.close);
  const kept: string[] = [];
  let insertAt = -1;
  let tagsAt = -1;
  let dropping = false;
  for (const raw of inner) {
    const line = stripEnd(raw);
    if (dropping) {
      // Continuation of a removed property: indented lines and unindented `- item`s.
      if (line.trim() !== '' && (/^\s/.test(line) || LIST_ITEM.test(line))) continue;
      dropping = false;
    }
    const match = /^\s/.test(line) ? null : KEY_LINE.exec(line);
    const key = match?.[1];
    if (key && (LABEL_KEYS as readonly string[]).includes(key)) {
      if (insertAt < 0) insertAt = kept.length;
      if (key === 'tags' && tagsAt < 0) tagsAt = kept.length;
      dropping = true;
      continue;
    }
    kept.push(raw);
  }
  let at = tagsAt >= 0 ? tagsAt : insertAt >= 0 ? insertAt : kept.length;
  // A last line without a terminator (the closing line must still start on its own line).
  if (at === kept.length && kept.length > 0 && !kept[kept.length - 1]!.endsWith('\n')) {
    kept[kept.length - 1] += eol;
  }
  const next = [...kept.slice(0, at), ...added, ...kept.slice(at)];
  if (next.every((l) => l.trim() === '')) {
    // Nothing left: drop the block (an empty `---\n---\n` is not valid frontmatter for the core).
    return bom + lines.slice(block.close + 1).join('');
  }
  return bom + [lines[block.open]!, ...next, ...lines.slice(block.close)].join('');
}
