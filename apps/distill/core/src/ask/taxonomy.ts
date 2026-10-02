/**
 * Source taxonomy helpers (docs/specs/labels-and-sources.md). Notes store the
 * source id in their `source_type` property. The taxonomy comes from
 * `settings.sourceTaxonomy`, falling back to the contract default.
 */

import { DEFAULT_SOURCE_TAXONOMY, type Settings, type SourceGroup } from '../contracts.js';

export { DEFAULT_SOURCE_TAXONOMY };
export type { SourceDefinition, SourceGroup } from '../contracts.js';

export type SourceTaxonomy = SourceGroup[];

/** The taxonomy Ask filters with: the user's edited groups, else the default. */
export function taxonomyFrom(settings: Pick<Settings, 'sourceTaxonomy'>): SourceTaxonomy {
  return settings.sourceTaxonomy ?? DEFAULT_SOURCE_TAXONOMY;
}

/** Canonical form of a source id or label: "GitHub review" / "github_review" -> "github-review". */
export function normalizeSourceID(value: string): string {
  return value
    .trim()
    .toLowerCase()
    .replace(/[\s_]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '');
}

/**
 * Expand a source filter into the set of `source_type` ids it allows.
 * A group id (or label) expands to all its members, unless the filter also
 * names one of that group's members, which narrows it (Discussion + Slack =
 * Slack only). Unknown ids are kept as literal source types.
 */
export function expandSources(selected: string[], taxonomy: SourceTaxonomy = DEFAULT_SOURCE_TAXONOMY): Set<string> {
  const ids = selected.map(normalizeSourceID).filter((id) => id.length > 0);
  const chosen = new Set(ids);
  const result = new Set<string>();
  const groupFor = (id: string) =>
    taxonomy.find((group) => normalizeSourceID(group.id) === id || normalizeSourceID(group.label) === id);
  const memberID = (id: string): string | undefined => {
    for (const group of taxonomy) {
      const member = group.sources.find((s) => normalizeSourceID(s.id) === id || normalizeSourceID(s.label) === id);
      if (member) return normalizeSourceID(member.id);
    }
    return undefined;
  };

  for (const id of ids) {
    const group = groupFor(id);
    if (group) {
      const members = group.sources.map((s) => normalizeSourceID(s.id));
      const narrowed = group.sources.some(
        (s) => chosen.has(normalizeSourceID(s.id)) || chosen.has(normalizeSourceID(s.label)),
      );
      if (!narrowed) members.forEach((m) => result.add(m));
      continue;
    }
    result.add(memberID(id) ?? id);
  }
  return result;
}
