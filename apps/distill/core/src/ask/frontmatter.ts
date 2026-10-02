/**
 * Minimal reader for the flat YAML frontmatter subset claude-obsidian writes
 * (skills/wiki/references/frontmatter.md): top-level `key: scalar`, block
 * lists (`key:` then `  - item`), and flow lists (`key: [a, b]`). Nested
 * mappings and multi-line scalars are skipped, not interpreted. No YAML
 * dependency on purpose.
 */

export type FrontmatterValue = string | string[];
export type Frontmatter = Record<string, FrontmatterValue>;

const KEY_LINE = /^([A-Za-z0-9_][A-Za-z0-9_.-]*)\s*:(?:\s+(.*))?$/;
const LIST_ITEM = /^\s*-\s*(.*)$/;

/** Return the frontmatter block's lines, or undefined when the text has none. */
function frontmatterLines(text: string): string[] | undefined {
  const body = text.replace(/^﻿/, '');
  const lines = body.split(/\r?\n/);
  if (lines[0]?.trimEnd() !== '---') return undefined;
  const end = lines.findIndex((line, i) => i > 0 && (line.trimEnd() === '---' || line.trimEnd() === '...'));
  if (end < 0) return undefined;
  return lines.slice(1, end);
}

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

export function parseFrontmatter(text: string): Frontmatter {
  const lines = frontmatterLines(text);
  const result: Frontmatter = {};
  if (!lines) return result;

  let listKey: string | null = null;
  for (const line of lines) {
    if (line.trim() === '' || line.trimStart().startsWith('#')) continue;

    const indented = /^\s/.test(line);
    const item = LIST_ITEM.exec(line);
    if (item && listKey !== null) {
      const value = unquote(item[1] ?? '');
      const list = result[listKey];
      if (Array.isArray(list) && value.length > 0) list.push(value);
      continue;
    }
    if (indented) continue; // nested mapping or continuation: not part of the flat subset

    listKey = null;
    const match = KEY_LINE.exec(line);
    if (!match) continue;
    const key = match[1]!;
    const rawValue = (match[2] ?? '').trim();
    if (rawValue === '') {
      result[key] = [];
      listKey = key;
    } else if (rawValue.startsWith('[') && rawValue.endsWith(']')) {
      result[key] = splitFlowList(rawValue.slice(1, -1));
    } else {
      result[key] = unquote(rawValue);
    }
  }
  return result;
}

/** A property as a list: scalars become one item, missing becomes []. */
export function listValue(fm: Frontmatter, key: string): string[] {
  const value = fm[key];
  if (value === undefined) return [];
  return Array.isArray(value) ? value : value === '' ? [] : [value];
}

/** A property as a scalar: the first item of a list, or undefined. */
export function scalarValue(fm: Frontmatter, key: string): string | undefined {
  const value = fm[key];
  if (Array.isArray(value)) return value[0];
  return value === '' ? undefined : value;
}
