import { promises as fs } from 'node:fs';
import path from 'node:path';
import type { LabelMatch } from '../contracts.js';
import { listValue, parseFrontmatter, scalarValue } from './frontmatter.js';
import { DEFAULT_SOURCE_TAXONOMY, expandSources, normalizeSourceID, type SourceTaxonomy } from './taxonomy.js';

export interface VaultPage {
  /** Vault-relative POSIX path, e.g. wiki/sources/tea.md */
  path: string;
  /** Absolute path (under the vault's real path). */
  absPath: string;
  title: string;
  /** Normalized tags (no '#', lower case). */
  tags: string[];
  /** Normalized `source_type` values. */
  sourceTypes: string[];
  /** Targets of `sources:` wikilinks, lower case, without alias/heading/extension. */
  sourceLinks: string[];
  /** `labels_reviewed: false`: the page's labels are AI labels not yet confirmed. */
  labelsUnconfirmed: boolean;
}

export interface PageFilter {
  labels?: string[];
  sources?: string[];
  /** any (default) = at least one label; all = every label. */
  labelMatch?: LabelMatch;
  /** Default true. false = labels on pages with `labels_reviewed: false` do not count. */
  includeUnconfirmed?: boolean;
}

/** Cap on how much of each page is read to find its frontmatter. */
const HEAD_BYTES = 64 * 1024;

async function readHead(file: string): Promise<string> {
  const handle = await fs.open(file, 'r');
  try {
    const buffer = Buffer.alloc(HEAD_BYTES);
    const { bytesRead } = await handle.read(buffer, 0, HEAD_BYTES, 0);
    return buffer.subarray(0, bytesRead).toString('utf8');
  } finally {
    await handle.close();
  }
}

/** Normalize a tag or label: trim, drop leading '#', lower case, trim slashes. */
export function normalizeTag(value: string): string {
  return value.trim().replace(/^#+/, '').trim().toLowerCase().replace(/^\/+|\/+$/g, '');
}

/** Obsidian-style match: label `a` matches tags `a` and `a/b`; label `a/b` matches `a/b` and `a/b/c`. */
export function tagMatches(label: string, tag: string): boolean {
  return tag === label || tag.startsWith(label + '/');
}

function wikilinkTarget(value: string): string | undefined {
  const match = /\[\[([^\]|#]+)/.exec(value);
  const target = (match?.[1] ?? value).trim();
  if (!target) return undefined;
  return path.posix.basename(target.replace(/\\/g, '/')).replace(/\.md$/i, '').toLowerCase();
}

function tagsOf(raw: string[]): string[] {
  // Legacy scalar form `tags: a, b` or `tags: a b` arrives as one item.
  return raw
    .flatMap((t) => t.split(/[,\s]+/))
    .map(normalizeTag)
    .filter((t) => t.length > 0);
}

/** Scan `wiki/**\/*.md` (no hidden dirs, no symlinks) and read each page's frontmatter. */
export async function scanVaultPages(vaultRealPath: string): Promise<VaultPage[]> {
  const root = path.join(vaultRealPath, 'wiki');
  const pages: VaultPage[] = [];

  async function walk(dir: string): Promise<void> {
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      if (entry.name.startsWith('.')) continue;
      const abs = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        await walk(abs);
      } else if (entry.isFile() && entry.name.toLowerCase().endsWith('.md')) {
        let text = '';
        try {
          text = await readHead(abs);
        } catch {
          continue;
        }
        const fm = parseFrontmatter(text);
        const rel = path.relative(vaultRealPath, abs).split(path.sep).join('/');
        pages.push({
          path: rel,
          absPath: abs,
          title: scalarValue(fm, 'title') ?? path.basename(entry.name, path.extname(entry.name)),
          tags: tagsOf(listValue(fm, 'tags')),
          sourceTypes: listValue(fm, 'source_type').map(normalizeSourceID).filter((s) => s.length > 0),
          sourceLinks: listValue(fm, 'sources')
            .map(wikilinkTarget)
            .filter((s): s is string => s !== undefined),
          labelsUnconfirmed: scalarValue(fm, 'labels_reviewed')?.trim().toLowerCase() === 'false',
        });
      }
    }
  }

  await walk(root);
  pages.sort((a, b) => a.path.localeCompare(b.path));
  return pages;
}

export function hasFilter(filter: PageFilter): boolean {
  return (filter.labels?.some((l) => normalizeTag(l)) ?? false) || (filter.sources?.some((s) => normalizeSourceID(s)) ?? false);
}

/**
 * Pages matching the filter. Within labels: OR (labelMatch any) or AND
 * (labelMatch all); a label also matches nested tags (`tea` matches
 * `tea/green`). With includeUnconfirmed false, a page whose labels are not
 * confirmed (`labels_reviewed: false`) has no labels for matching. Within sources: OR. Within sources: OR (groups
 * expanded). Labels AND sources. A page matches a source when its own
 * `source_type` does, or when any page it lists under `sources:` does (a
 * synthesized page matches if any of its sources match).
 */
export function filterPages(pages: VaultPage[], filter: PageFilter, taxonomy: SourceTaxonomy = DEFAULT_SOURCE_TAXONOMY): VaultPage[] {
  const labels = (filter.labels ?? []).map(normalizeTag).filter((l) => l.length > 0);
  const sources = expandSources(filter.sources ?? [], taxonomy);
  const wantSources = (filter.sources ?? []).some((s) => normalizeSourceID(s).length > 0);

  const byName = new Map<string, VaultPage>();
  for (const page of pages) {
    byName.set(path.posix.basename(page.path, '.md').toLowerCase(), page);
    if (!byName.has(page.title.toLowerCase())) byName.set(page.title.toLowerCase(), page);
  }

  const ownSourceMatch = (page: VaultPage) => page.sourceTypes.some((s) => sources.has(s));
  const sourceMatch = (page: VaultPage) =>
    ownSourceMatch(page) ||
    page.sourceLinks.some((link) => {
      const linked = byName.get(link);
      return linked !== undefined && linked !== page && ownSourceMatch(linked);
    });
  const includeUnconfirmed = filter.includeUnconfirmed ?? true;
  const every = filter.labelMatch === 'all';
  const labelMatch = (page: VaultPage) => {
    if (!includeUnconfirmed && page.labelsUnconfirmed) return false;
    const has = (label: string) => page.tags.some((tag) => tagMatches(label, tag));
    return every ? labels.every(has) : labels.some(has);
  };

  return pages.filter((page) => (labels.length === 0 || labelMatch(page)) && (!wantSources || sourceMatch(page)));
}

/** Claude Code permission rule that allows reading exactly one absolute path. */
export function readRule(absPath: string): string {
  return `Read(/${absPath})`;
}
