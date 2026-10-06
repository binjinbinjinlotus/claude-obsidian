/**
 * A note's Highlights (actions-routing.md). What the wiki source page already says (summary,
 * key points, decisions) is READ from the page, with its line numbers; Distill never extracts it.
 * The only thing Highlights adds to the wiki is the page's "Others' actions" section, and that
 * goes in through the next ingest batch (a transaction the user approves): this module only
 * builds the section's text and the batch's instruction. Nothing here writes a file.
 */
import { readLines } from './context.js';

export const OTHERS_HEADING = "## Others' actions";
const OTHERS_RE = /^##\s+Others['’] actions\s*$/i;
/** Pages one batch is asked to update (the rest wait for the next). */
export const MAX_OTHERS_PAGES = 10;

export interface PageFacts {
  title: string;
  date?: string;
  duration?: string;
  meeting: boolean;
  summary?: string;
  keyPoints: { text: string; line: number }[];
  decisions: { text: string; line: number }[];
  /** The Others' actions section's lines (without the heading), or undefined when there is none. */
  others?: string[];
}

const KEY_POINTS = /^(key (points|takeaways|ideas|facts)|highlights|main points|takeaways)$/i;
const DECISIONS = /^(decisions?( made)?|what was decided)$/i;
const SUMMARY = /^(summary|tl;?dr|overview|abstract)$/i;

function frontmatter(lines: string[]): { end: number; fields: Record<string, string>; tags: string[] } {
  const fields: Record<string, string> = {};
  const tags: string[] = [];
  if (lines[0]?.trim() !== '---') return { end: 0, fields, tags };
  let k = 1;
  let inTags = false;
  for (; k < lines.length; k++) {
    const l = lines[k]!;
    if (l.trim() === '---') return { end: k + 1, fields, tags };
    const m = /^([A-Za-z_][\w-]*):\s*(.*)$/.exec(l);
    if (m) {
      const v = m[2]!.trim().replace(/^["']|["']$/g, '');
      fields[m[1]!.toLowerCase()] = v;
      inTags = m[1]!.toLowerCase() === 'tags';
      if (inTags && v.startsWith('[')) tags.push(...v.slice(1, -1).split(',').map((t) => t.trim().replace(/^["']|["']$/g, '')));
      continue;
    }
    const item = /^\s+-\s+(.+)$/.exec(l);
    if (inTags && item) tags.push(item[1]!.trim().replace(/^["']|["']$/g, ''));
  }
  return { end: 0, fields: {}, tags: [] };
}

/** Plain text of a Markdown line: links and emphasis kept as their words. */
export function plainLine(s: string): string {
  return s
    .replace(/!\[\[[^\]]*\]\]/g, '')
    .replace(/\[\[([^\]|]+)\|([^\]]+)\]\]/g, '$2')
    .replace(/\[\[([^\]]+)\]\]/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/(\*\*|__|\*|_|`)/g, '')
    .replace(/\s+\^[\w-]+$/, '')
    .trim();
}

const BULLET = /^(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s+)?(.+)$/;

/** Reads a wiki page's title, frontmatter facts, summary, key points, decisions and Others' actions section. */
export function pageFacts(text: string, fallbackTitle: string): PageFacts {
  const lines = text.split('\n');
  const fm = frontmatter(lines);
  const facts: PageFacts = { title: fm.fields.title || fallbackTitle, meeting: false, keyPoints: [], decisions: [] };
  const kind = [fm.fields.type, fm.fields.kind, fm.fields.source_type, fm.fields.source].map((v) => (v ?? '').toLowerCase());
  facts.meeting = kind.includes('meeting') || fm.tags.some((t) => /^(meeting|meetings)$/i.test(t.replace(/^#/, '')));
  const date = /^\d{4}-\d{2}-\d{2}/.exec(fm.fields.date ?? fm.fields.created ?? '')?.[0];
  if (date) facts.date = date;
  if (fm.fields.duration) facts.duration = fm.fields.duration;
  let section: string | null = null;
  let firstParagraph: string | undefined;
  let summarySection: string[] = [];
  let paragraph: string[] = [];
  const endParagraph = () => {
    if (paragraph.length > 0 && firstParagraph === undefined && section === null) firstParagraph = paragraph.join(' ');
    paragraph = [];
  };
  for (let k = fm.end; k < lines.length; k++) {
    const raw = lines[k]!;
    const line = raw.trim();
    const h = /^(#{1,6})\s+(.+?)\s*#*$/.exec(line);
    if (h) {
      endParagraph();
      if (h[1] === '#') {
        if (!fm.fields.title) facts.title = plainLine(h[2]!);
        section = null;
        continue;
      }
      section = plainLine(h[2]!);
      if (OTHERS_RE.test(line)) facts.others = [];
      continue;
    }
    if (section !== null && OTHERS_RE.test(`## ${section}`)) {
      if (line) facts.others!.push(raw.trimEnd());
      continue;
    }
    const bullet = /^\s{0,1}(?:[-*+]|\d+[.)])\s/.test(raw) ? BULLET.exec(line) : null;
    if (section !== null && bullet) {
      const text = plainLine(bullet[1]!);
      if (text && KEY_POINTS.test(section)) facts.keyPoints.push({ text, line: k + 1 });
      else if (text && DECISIONS.test(section)) facts.decisions.push({ text, line: k + 1 });
      continue;
    }
    if (section !== null && SUMMARY.test(section)) {
      if (line && !line.startsWith('>') && !bullet) summarySection.push(plainLine(line));
      else if (!line && summarySection.length > 0) section = `${section} (done)`;
      continue;
    }
    if (!line || line.startsWith('>') || line.startsWith('|') || line.startsWith('```') || /^(?:[-*+]|\d+[.)])\s/.test(line)) {
      endParagraph();
      continue;
    }
    if (section === null) paragraph.push(plainLine(line));
  }
  endParagraph();
  const summary = summarySection.length > 0 ? summarySection.join(' ') : firstParagraph;
  if (summary) facts.summary = summary.length > 600 ? `${summary.slice(0, 599)}…` : summary;
  return facts;
}

export function readPageFacts(vaultPath: string, page: string, fallbackTitle: string): PageFacts | undefined {
  const lines = readLines(vaultPath, page);
  return lines ? pageFacts(lines.join('\n'), fallbackTitle) : undefined;
}

export interface OthersLine {
  person: string;
  title: string;
  due?: string | null;
}

/** One line of the section: "- **Vladan Dimitrijevic**: Benchmark the Redis cache on staging (by 2026-10-08)". */
export function othersLine(o: OthersLine): string {
  const title = o.title.replace(/\s+/g, ' ').trim();
  return `- **${o.person.replace(/[*\n]/g, '').trim()}**: ${title}${o.due ? ` (by ${o.due})` : ''}`;
}

/** The section's lines as they should be (empty = no section). */
export function othersSectionLines(items: OthersLine[]): string[] {
  return items.map(othersLine);
}

/** The page's text with its Others' actions section set to these lines (added at the end, replaced, or removed when empty). */
export function withOthersSection(text: string, lines: string[]): string {
  const all = text.split('\n');
  const start = all.findIndex((l) => OTHERS_RE.test(l.trim()));
  const block = lines.length > 0 ? [OTHERS_HEADING, '', ...lines] : [];
  if (start < 0) {
    if (block.length === 0) return text;
    const body = text.replace(/\s+$/, '');
    return `${body}\n\n${block.join('\n')}\n`;
  }
  let end = start + 1;
  while (end < all.length && !/^#{1,2}\s/.test(all[end]!.trim())) end++;
  const before = all.slice(0, start);
  const after = all.slice(end);
  while (before.length > 0 && before.at(-1)!.trim() === '') before.pop();
  const out = [...before, ...(block.length > 0 ? ['', ...block] : []), ...(after.length > 0 ? ['', ...after] : [])].join('\n');
  return out.replace(/\s+$/, '') + '\n';
}

/** True when the page's section already says exactly these lines (in any order). */
export function sectionMatches(current: string[] | undefined, lines: string[]): boolean {
  const have = (current ?? []).map((l) => l.trim()).filter(Boolean).sort();
  const want = lines.map((l) => l.trim()).sort();
  return have.length === want.length && have.every((l, k) => l === want[k]);
}

/** What the next ingest batch is asked to do with these pages (empty when nothing is due). */
export function othersPrompt(pages: { path: string; lines: string[] }[]): string {
  if (pages.length === 0) return '';
  const blocks = pages.map((p) =>
    p.lines.length > 0
      ? `<page path="${p.path.replace(/"/g, "'")}">\n${OTHERS_HEADING}\n\n${p.lines.join('\n')}\n</page>`
      : `<page path="${p.path.replace(/"/g, "'")}" remove="true"></page>`,
  );
  return `

Also update these EXISTING wiki pages for the user's Actions (from the user, not from a source). \
On each page, replace the section "${OTHERS_HEADING}" with exactly the text given (heading \
included), or add it at the end of the page when the page has none; for a page marked \
remove="true", delete that section. Change nothing else on these pages and do not create \
pages for them. Add each one to the bundle as a \`replace\` write with its current SHA-256, and \
name them in your summary under "Others' actions".

${blocks.join('\n\n')}`;
}
