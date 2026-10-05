import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { writeFileAtomic } from '../store/json.js';

/**
 * The reading copy (full-read.md, section 1). Before the first turn the core makes, for every text
 * source, a copy in the job directory that the AI reads instead of the original:
 *
 * - copy line n is source line n, so line numbers stay true;
 * - a line that is only an embedded data-URI image becomes one placeholder line;
 * - a line over MAX_LINE characters keeps its first MAX_LINE characters in place, ends with
 *   `→ L<n>↪`, and its other pieces go after the last line, each prefixed `L<n>↪ `.
 *
 * A file that isn't UTF-8 text (bad bytes, NUL bytes, nothing readable) is unreadable: the core
 * decides that, never the AI. The copy is what the token estimate and the coverage are measured on.
 */

export const MAX_LINE = 1900;
/** Bytes of text per token, measured on the owner's transcripts (8 whole reads: 265,479 chars → 100,456 tokens). */
export const BYTES_PER_TOKEN = 2.6;
/** A planned section: at most this many lines and this many tokens. */
export const SECTION_LINES = 400;
export const SECTION_TOKENS = 8000;
const PDF_PAGE_TOKENS = 1500;
const IMAGE_TOKENS = 1600;

const TEXT_EXTENSIONS = new Set(['.md', '.markdown', '.txt', '.text', '.csv', '.tsv', '.json', '.html', '.htm', '.xml', '.yaml', '.yml', '.log', '.srt', '.vtt', '.rtf', '.org', '.rst', '']);
const DATA_IMAGE_LINE = /^\s*(\[[^\]]*\]:\s*<?data:([a-z]+\/[a-z0-9.+-]+);base64,|!\[[^\]]*\]\(data:([a-z]+\/[a-z0-9.+-]+);base64,)/i;

export type SourceKind = 'text' | 'pdf' | 'image' | 'other';

export function sourceKind(file: string): SourceKind {
  const ext = path.extname(file).toLowerCase();
  if (TEXT_EXTENSIONS.has(ext)) return 'text';
  if (ext === '.pdf') return 'pdf';
  if (['.png', '.jpg', '.jpeg', '.gif', '.webp', '.heic', '.tif', '.tiff', '.bmp'].includes(ext)) return 'image';
  return 'other';
}

export interface Section {
  from: number;
  to: number;
}

export interface ReadingCopy {
  /** The source, vault-relative (inbox/… or .raw/…). */
  file: string;
  kind: SourceKind;
  sha256: string;
  bytes: number;
  /** Text sources: the copy's path (absolute) and its line count (source lines plus appendix lines). */
  copy?: string;
  lines: number;
  /** Lines of the source itself (the copy's first `sourceLines` lines). */
  sourceLines: number;
  textBytes: number;
  estTokens: number;
  imageLines: number;
  imageAt?: number[];
  /** Source lines split because they were over MAX_LINE characters. */
  longLines: number;
  sections: Section[];
  /** Why the core can't read it as text; set = unreadable, no copy. */
  unreadable?: string;
}

const sha256 = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');

function pdfPages(buf: Buffer): number {
  const m = buf.toString('latin1').match(/\/Type\s*\/Page(?!s)/g);
  return Math.max(1, m?.length ?? 1);
}

/** The first line (1-based) of `buf` that isn't valid UTF-8, or undefined. */
function badUtf8Line(buf: Buffer): number | undefined {
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let start = 0;
  let line = 1;
  while (start <= buf.length) {
    let end = buf.indexOf(0x0a, start);
    if (end < 0) end = buf.length;
    try {
      decoder.decode(buf.subarray(start, end));
    } catch {
      return line;
    }
    start = end + 1;
    line += 1;
  }
  return undefined;
}

function lineOfByte(buf: Buffer, at: number): number {
  let n = 1;
  for (let i = 0; i < at; i++) if (buf[i] === 0x0a) n += 1;
  return n;
}

/** Splits `lines` (1-based numbering) into sections at good break points. */
export function planSections(lines: string[], maxLines = SECTION_LINES, maxTokens = SECTION_TOKENS): Section[] {
  const out: Section[] = [];
  const maxBytes = maxTokens * BYTES_PER_TOKEN;
  let from = 1;
  let bytes = 0;
  let lastBreak = 0;
  for (let i = 1; i <= lines.length; i++) {
    const l = lines[i - 1]!;
    bytes += Buffer.byteLength(l, 'utf8') + 1;
    if (/^\s*$/.test(l) || /^#{1,6}\s/.test(l) || /^#{0,6}\s*\**\d{1,2}:\d{2}(:\d{2})?\**\s*$/.test(l)) lastBreak = i;
    const full = i - from + 1 >= maxLines || bytes >= maxBytes;
    if (full && i < lines.length) {
      // Break at the last good line in the second half of the section, else here.
      const cut = lastBreak >= from + Math.floor((i - from) / 2) ? lastBreak : i;
      out.push({ from, to: cut });
      from = cut + 1;
      bytes = 0;
      for (let k = from; k <= i; k++) bytes += Buffer.byteLength(lines[k - 1]!, 'utf8') + 1;
    }
  }
  if (from <= lines.length) out.push({ from, to: lines.length });
  return out;
}

export interface CopyOptions {
  /** Halve the section size (a fresh session reading what a first one couldn't finish). */
  small?: boolean;
}

/**
 * Builds the reading copy of `file` (vault-relative) into `outDir/read/<n>.md` (text sources), or
 * the facts of a PDF or image. Never writes anywhere but `outDir`.
 */
export function makeReadingCopy(vaultPath: string, file: string, outDir: string, n: number, o: CopyOptions = {}): ReadingCopy {
  const kind = sourceKind(file);
  let buf: Buffer;
  try {
    buf = fs.readFileSync(path.join(vaultPath, file));
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    return empty(file, kind, '', 0, code === 'ENOENT' ? 'the file is gone' : 'the file can’t be opened');
  }
  const hash = sha256(buf);
  if (kind === 'pdf') {
    const pages = pdfPages(buf);
    return { file, kind, sha256: hash, bytes: buf.length, lines: pages, sourceLines: pages, textBytes: 0, estTokens: pages * PDF_PAGE_TOKENS, imageLines: 0, longLines: 0, sections: [] };
  }
  if (kind === 'image' || kind === 'other') {
    return { file, kind, sha256: hash, bytes: buf.length, lines: 1, sourceLines: 1, textBytes: 0, estTokens: kind === 'image' ? IMAGE_TOKENS : Math.ceil(buf.length / BYTES_PER_TOKEN), imageLines: 0, longLines: 0, sections: [] };
  }
  const nul = buf.indexOf(0);
  if (nul >= 0) return empty(file, kind, hash, buf.length, `it has a NUL byte on line ${lineOfByte(buf, nul)}, so it isn’t text`);
  const bad = badUtf8Line(buf);
  if (bad !== undefined) return empty(file, kind, hash, buf.length, `it isn’t valid UTF-8 text from line ${bad}`);
  let text = buf.toString('utf8');
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  const lines = text.split('\n').map((l) => (l.endsWith('\r') ? l.slice(0, -1) : l));
  if (lines.at(-1) === '') lines.pop();
  if (lines.every((l) => l.trim() === '')) return empty(file, kind, hash, buf.length, 'it has no text in it');
  const out: string[] = [];
  const appendix: string[] = [];
  let imageLines = 0;
  let longLines = 0;
  const imageAt: number[] = [];
  lines.forEach((l, i) => {
    const m = DATA_IMAGE_LINE.exec(l);
    if (m) {
      imageLines += 1;
      if (imageAt.length < 20) imageAt.push(i + 1);
      const name = /^\s*\[([^\]]*)\]/.exec(l)?.[1] ?? /^\s*!\[([^\]]*)\]/.exec(l)?.[1] ?? `image${imageLines}`;
      const type = (m[2] ?? m[3] ?? 'image').split('/')[1]?.toUpperCase() ?? 'IMAGE';
      out.push(`[${name || `image${imageLines}`}: embedded ${type}, ${Math.round(Buffer.byteLength(l, 'utf8') / 1024)} KB, not text]`);
      return;
    }
    if (l.length > MAX_LINE) {
      longLines += 1;
      out.push(`${l.slice(0, MAX_LINE)} → L${i + 1}↪`);
      for (let k = MAX_LINE; k < l.length; k += MAX_LINE) appendix.push(`L${i + 1}↪ ${l.slice(k, k + MAX_LINE)}`);
      return;
    }
    out.push(l);
  });
  const all = [...out, ...appendix];
  const body = all.join('\n') + '\n';
  const dir = path.join(outDir, 'read');
  fs.mkdirSync(dir, { recursive: true });
  const copy = path.join(dir, `${n}.md`);
  writeFileAtomic(copy, body);
  const textBytes = Buffer.byteLength(body, 'utf8');
  const sections = o.small ? planSections(all, SECTION_LINES / 2, SECTION_TOKENS / 2) : planSections(all);
  const rc: ReadingCopy = {
    file,
    kind,
    sha256: hash,
    bytes: buf.length,
    copy,
    lines: all.length,
    sourceLines: lines.length,
    textBytes,
    estTokens: Math.ceil(textBytes / BYTES_PER_TOKEN),
    imageLines,
    longLines,
    sections,
  };
  if (imageAt.length > 0) rc.imageAt = imageAt;
  return rc;
}

function empty(file: string, kind: SourceKind, hash: string, bytes: number, why: string): ReadingCopy {
  return { file, kind, sha256: hash, bytes, lines: 0, sourceLines: 0, textBytes: 0, estTokens: 0, imageLines: 0, longLines: 0, sections: [], unreadable: why };
}

/** Token estimate of a source without writing a copy (queue packing). */
export function estimateTokens(abs: string): number {
  const kind = sourceKind(abs);
  let buf: Buffer;
  try {
    buf = fs.readFileSync(abs);
  } catch {
    return 0;
  }
  if (kind === 'pdf') return pdfPages(buf) * PDF_PAGE_TOKENS;
  if (kind === 'image') return IMAGE_TOKENS;
  if (kind === 'other') return Math.ceil(buf.length / BYTES_PER_TOKEN);
  let bytes = 0;
  for (const l of buf.toString('utf8').split('\n')) {
    if (DATA_IMAGE_LINE.test(l)) bytes += 50;
    else bytes += Buffer.byteLength(l, 'utf8') + 1;
  }
  return Math.ceil(bytes / BYTES_PER_TOKEN);
}
