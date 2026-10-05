/**
 * Redaction for the activity log. Entries are built from names, ids, counts and paths,
 * never from secrets or script bodies; this is the second line of defence for anything
 * user-typed (titles, error messages, settings values) that might hold a credential.
 */

export const REDACTED = '[redacted]';

/** Keys whose values are never logged, at any depth. */
const SECRET_KEY = /(pass(word|wd|phrase)?|secret|token|api[-_]?key|apikey|auth(orization)?|credential|private[-_]?key|cookie|session[-_]?key|bearer|signature)/i;

type Replacer = (match: string, ...groups: string[]) => string;
const whole: Replacer = () => REDACTED;

const PATTERNS: [RegExp, Replacer][] = [
  // key=value / key: value pairs with a secret-looking key ("token=abc", "Authorization: Bearer x", "password: hunter2")
  [
    /\b([A-Za-z0-9_-]*?(?:pass(?:word|wd|phrase)?|secret|token|api[-_]?key|apikey|authorization|credential|private[-_]?key|cookie))(["']?\s*[:=]\s*["']?)(?:Bearer\s+|Basic\s+)?[^\s"',;&]+/gi,
    (_m, key, sep) => `${key}${sep}${REDACTED}`,
  ],
  // Bearer / Basic credentials
  [/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/g, (_m, scheme) => `${scheme} ${REDACTED}`],
  // URLs with credentials: https://user:pass@host
  [/\b([a-z][a-z0-9+.-]*:\/\/)[^\s/:@]+:[^\s/@]+@/gi, (_m, scheme) => `${scheme}${REDACTED}@`],
  // Well-known token shapes
  [/\bsk-(?:ant-|proj-|or-)?[A-Za-z0-9_-]{16,}/g, whole], // Anthropic, OpenAI, OpenRouter
  [/\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}/g, whole], // GitHub
  [/\bxox[abposr]-[A-Za-z0-9-]{10,}/g, whole], // Slack
  [/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g, whole], // AWS access key id
  [/\bAIza[0-9A-Za-z_-]{30,}/g, whole], // Google API key
  [/\bya29\.[0-9A-Za-z_-]{20,}/g, whole], // Google OAuth access token
  [/\b1\/\/0[0-9A-Za-z_-]{30,}/g, whole], // Google refresh token
  [/\bATATT[0-9A-Za-z_=-]{20,}/g, whole], // Atlassian API token
  [/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g, whole], // JWT
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g, whole],
  // Long opaque strings: 32+ hex, or 40+ base64-ish characters mixing upper, lower and digits
  [/\b[0-9a-f]{32,}\b/gi, whole],
  [/(?=[A-Za-z0-9+/_-]*[0-9])(?=[A-Za-z0-9+/_-]*[a-z])(?=[A-Za-z0-9+/_-]*[A-Z])\b[A-Za-z0-9+/_-]{40,}={0,2}/g, whole],
];

/** Replace anything that looks like a secret in a string. */
export function redactText(text: string): string {
  let out = text;
  for (const [re, replace] of PATTERNS) out = out.replace(re, replace as (m: string, ...g: string[]) => string);
  return out;
}

/** Shorten to `max` characters (with an ellipsis), after redaction. */
export function clip(text: string, max: number): string {
  const flat = redactText(text).replace(/\s+/g, ' ').trim();
  return flat.length <= max ? flat : `${flat.slice(0, max - 1).trimEnd()}…`;
}

export function isSecretKey(key: string): boolean {
  return SECRET_KEY.test(key);
}

type DetailValue = string | number | boolean | null | string[];

/** Flat details: secret-looking keys dropped to [redacted], strings redacted and clipped, lists capped. */
export function redactDetails(details: Record<string, unknown> | undefined): Record<string, DetailValue> | undefined {
  if (!details) return undefined;
  const out: Record<string, DetailValue> = {};
  for (const [key, value] of Object.entries(details)) {
    if (value === undefined) continue;
    if (isSecretKey(key)) {
      out[key] = REDACTED;
      continue;
    }
    if (value === null || typeof value === 'boolean') out[key] = value;
    else if (typeof value === 'number') out[key] = Number.isFinite(value) ? value : null;
    else if (typeof value === 'string') out[key] = clip(value, 300);
    else if (Array.isArray(value)) {
      const list = value.filter((v) => v !== undefined && v !== null).map((v) => clip(String(v), 200));
      out[key] = list.length > 20 ? [...list.slice(0, 20), `… ${list.length - 20} more`] : list;
    } else out[key] = clip(JSON.stringify(value) ?? '', 300);
  }
  return out;
}
