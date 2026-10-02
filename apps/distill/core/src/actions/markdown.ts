/**
 * Markdown (as Distill drafts it) → Jira's Atlassian Document Format and
 * Confluence's storage format. Covers what drafts use: headings, paragraphs,
 * bullet and numbered lists (one level of nesting), code blocks, quotes, and
 * inline bold / italic / code / links. Anything else is kept as plain text.
 */

export type Block =
  | { kind: 'heading'; level: number; text: string }
  | { kind: 'paragraph'; text: string }
  | { kind: 'list'; ordered: boolean; items: ListItem[] }
  | { kind: 'code'; language: string; text: string }
  | { kind: 'quote'; text: string }
  | { kind: 'rule' };

export interface ListItem {
  text: string;
  children?: { ordered: boolean; items: ListItem[] };
}

const BULLET = /^(\s*)([-*+•])\s+(.*)$/;
const NUMBERED = /^(\s*)(\d+)[.)]\s+(.*)$/;

export function parseBlocks(markdown: string): Block[] {
  const lines = markdown.replace(/\r\n?/g, '\n').split('\n');
  const blocks: Block[] = [];
  let para: string[] = [];
  const flush = () => {
    if (para.length > 0) blocks.push({ kind: 'paragraph', text: para.join(' ').trim() });
    para = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const fence = /^\s*```\s*([\w+-]*)\s*$/.exec(line);
    if (fence) {
      flush();
      const body: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i]!)) body.push(lines[i++]!);
      blocks.push({ kind: 'code', language: fence[1] ?? '', text: body.join('\n') });
      continue;
    }
    if (line.trim() === '') {
      flush();
      continue;
    }
    const heading = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line);
    if (heading) {
      flush();
      blocks.push({ kind: 'heading', level: heading[1]!.length, text: heading[2]! });
      continue;
    }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
      flush();
      blocks.push({ kind: 'rule' });
      continue;
    }
    if (/^\s*>/.test(line)) {
      flush();
      const quote: string[] = [];
      while (i < lines.length && /^\s*>/.test(lines[i]!)) quote.push(lines[i++]!.replace(/^\s*>\s?/, ''));
      i--;
      blocks.push({ kind: 'quote', text: quote.join(' ').trim() });
      continue;
    }
    const first = BULLET.exec(line) ?? NUMBERED.exec(line);
    if (first) {
      flush();
      const ordered = NUMBERED.test(line) && !BULLET.test(line);
      const baseIndent = first[1]!.length;
      const items: ListItem[] = [];
      while (i < lines.length) {
        const l = lines[i]!;
        const m = BULLET.exec(l) ?? NUMBERED.exec(l);
        if (!m) {
          // A continuation line of the last item.
          if (l.trim() !== '' && /^\s+/.test(l) && items.length > 0) {
            const last = items[items.length - 1]!;
            last.text = `${last.text} ${l.trim()}`;
            i++;
            continue;
          }
          break;
        }
        const indent = m[1]!.length;
        const isOrdered = NUMBERED.test(l) && !BULLET.test(l);
        // A different kind of list at the same level starts a new list.
        if (indent <= baseIndent && isOrdered !== ordered) break;
        if (indent > baseIndent && items.length > 0) {
          const parent = items[items.length - 1]!;
          const childOrdered = NUMBERED.test(l) && !BULLET.test(l);
          parent.children ??= { ordered: childOrdered, items: [] };
          parent.children.items.push({ text: m[3]! });
        } else {
          items.push({ text: m[3]! });
        }
        i++;
      }
      i--;
      blocks.push({ kind: 'list', ordered, items });
      continue;
    }
    para.push(line.trim());
  }
  flush();
  return blocks;
}

// ───────────── inline ─────────────

export interface Span {
  text: string;
  strong?: boolean;
  em?: boolean;
  code?: boolean;
  link?: string;
}

/** Inline Markdown → spans. Unclosed marks stay as literal text. */
export function parseInline(text: string): Span[] {
  const spans: Span[] = [];
  const re = /(`[^`]+`)|(\*\*[^*]+\*\*|__[^_]+__)|(\*[^*\s][^*]*\*|_[^_\s][^_]*_)|(\[[^\]]+\]\([^)\s]+\))/g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    if (m.index > last) spans.push({ text: text.slice(last, m.index) });
    const token = m[0];
    if (m[1]) spans.push({ text: token.slice(1, -1), code: true });
    else if (m[2]) spans.push({ text: token.slice(2, -2), strong: true });
    else if (m[3]) spans.push({ text: token.slice(1, -1), em: true });
    else if (m[4]) {
      const link = /^\[([^\]]+)\]\(([^)\s]+)\)$/.exec(token)!;
      spans.push({ text: link[1]!, link: link[2]! });
    }
    last = m.index + token.length;
  }
  if (last < text.length) spans.push({ text: text.slice(last) });
  return spans.filter((s) => s.text.length > 0);
}

// ───────────── ADF (Jira Cloud REST v3) ─────────────

type AdfNode = Record<string, unknown>;

function adfText(text: string): AdfNode[] {
  return parseInline(text).map((s) => {
    const marks: AdfNode[] = [];
    if (s.code) marks.push({ type: 'code' });
    else {
      if (s.strong) marks.push({ type: 'strong' });
      if (s.em) marks.push({ type: 'em' });
      if (s.link) marks.push({ type: 'link', attrs: { href: s.link } });
    }
    return marks.length > 0 ? { type: 'text', text: s.text, marks } : { type: 'text', text: s.text };
  });
}

function adfParagraph(text: string): AdfNode {
  const content = adfText(text);
  return content.length > 0 ? { type: 'paragraph', content } : { type: 'paragraph' };
}

function adfList(ordered: boolean, items: ListItem[]): AdfNode {
  return {
    type: ordered ? 'orderedList' : 'bulletList',
    content: items.map((item) => ({
      type: 'listItem',
      content: [adfParagraph(item.text), ...(item.children ? [adfList(item.children.ordered, item.children.items)] : [])],
    })),
  };
}

export function markdownToADF(markdown: string): AdfNode {
  const content: AdfNode[] = parseBlocks(markdown).map((b): AdfNode => {
    switch (b.kind) {
      case 'heading':
        return { type: 'heading', attrs: { level: b.level }, content: adfText(b.text) };
      case 'paragraph':
        return adfParagraph(b.text);
      case 'list':
        return adfList(b.ordered, b.items);
      case 'code':
        return {
          type: 'codeBlock',
          ...(b.language ? { attrs: { language: b.language } } : {}),
          ...(b.text ? { content: [{ type: 'text', text: b.text }] } : {}),
        };
      case 'quote':
        return { type: 'blockquote', content: [adfParagraph(b.text)] };
      case 'rule':
        return { type: 'rule' };
    }
  });
  return { version: 1, type: 'doc', content };
}

// ───────────── Confluence storage format (XHTML) ─────────────

export function escapeXML(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function storageInline(text: string): string {
  return parseInline(text)
    .map((s) => {
      const t = escapeXML(s.text);
      if (s.code) return `<code>${t}</code>`;
      let out = t;
      if (s.em) out = `<em>${out}</em>`;
      if (s.strong) out = `<strong>${out}</strong>`;
      if (s.link) out = `<a href="${escapeXML(s.link)}">${out}</a>`;
      return out;
    })
    .join('');
}

function storageList(ordered: boolean, items: ListItem[]): string {
  const tag = ordered ? 'ol' : 'ul';
  const lis = items
    .map((i) => `<li>${storageInline(i.text)}${i.children ? storageList(i.children.ordered, i.children.items) : ''}</li>`)
    .join('');
  return `<${tag}>${lis}</${tag}>`;
}

export function markdownToStorage(markdown: string): string {
  return parseBlocks(markdown)
    .map((b) => {
      switch (b.kind) {
        case 'heading':
          return `<h${b.level}>${storageInline(b.text)}</h${b.level}>`;
        case 'paragraph':
          return `<p>${storageInline(b.text)}</p>`;
        case 'list':
          return storageList(b.ordered, b.items);
        case 'code': {
          const lang = b.language ? `<ac:parameter ac:name="language">${escapeXML(b.language)}</ac:parameter>` : '';
          // CDATA can't contain "]]>": split it across two sections.
          const body = b.text.split(']]>').join(']]]]><![CDATA[>');
          return `<ac:structured-macro ac:name="code">${lang}<ac:plain-text-body><![CDATA[${body}]]></ac:plain-text-body></ac:structured-macro>`;
        }
        case 'quote':
          return `<blockquote><p>${storageInline(b.text)}</p></blockquote>`;
        case 'rule':
          return '<hr />';
      }
    })
    .join('\n');
}
