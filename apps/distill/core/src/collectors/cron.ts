/**
 * 5-field cron (minute hour day-of-month month day-of-week) in local time, for
 * collector schedules. Presets are shorthands; "@hourly" and "@daily" are the
 * only nicknames accepted. Seconds and "@reboot" are not.
 *
 * Day matching follows Vixie cron: when both day-of-month and day-of-week are
 * restricted (neither starts with "*"), a day matches if EITHER does.
 */
import type { ScheduleCheck, SchedulePreset } from '../contracts.js';
import { isoDate } from '../store/json.js';

export interface CronSpec {
  source: string;
  minutes: Set<number>;
  hours: Set<number>;
  days: Set<number>;
  months: Set<number>; // 1-12
  weekdays: Set<number>; // 0-6, Sunday = 0
  dayRestricted: boolean;
  weekdayRestricted: boolean;
}

export class CronError extends Error {}

const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const WEEKDAYS = ['sun', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat'];
const NICKNAMES: Record<string, string> = { '@hourly': '0 * * * *', '@daily': '0 0 * * *' };

interface FieldDef {
  name: string;
  min: number;
  max: number;
  names?: string[];
  /** Offset of names[0] (months start at 1). */
  nameBase?: number;
}

const FIELDS: FieldDef[] = [
  { name: 'minute', min: 0, max: 59 },
  { name: 'hour', min: 0, max: 23 },
  { name: 'day of month', min: 1, max: 31 },
  { name: 'month', min: 1, max: 12, names: MONTHS, nameBase: 1 },
  { name: 'day of week', min: 0, max: 7, names: WEEKDAYS, nameBase: 0 },
];

function parseValue(raw: string, f: FieldDef): number {
  const lower = raw.toLowerCase();
  if (f.names) {
    const i = f.names.indexOf(lower);
    if (i >= 0) return i + (f.nameBase ?? 0);
  }
  if (!/^\d+$/.test(raw)) throw new CronError(`"${raw}" is not a valid ${f.name}.`);
  const n = Number(raw);
  if (n < f.min || n > f.max) throw new CronError(`${f.name} ${n} is out of range (${f.min}–${f.max}).`);
  return n;
}

function parseField(text: string, f: FieldDef): Set<number> {
  const out = new Set<number>();
  for (const item of text.split(',')) {
    if (item === '') throw new CronError(`Empty item in the ${f.name} field.`);
    const [range, stepText, extra] = item.split('/');
    if (extra !== undefined || range === undefined || range === '') throw new CronError(`"${item}" is not a valid ${f.name}.`);
    let step = 1;
    if (stepText !== undefined) {
      if (!/^\d+$/.test(stepText) || Number(stepText) < 1) throw new CronError(`Step "${stepText}" in the ${f.name} field must be a positive number.`);
      step = Number(stepText);
    }
    let lo: number;
    let hi: number;
    if (range === '*') {
      lo = f.min;
      hi = f.max;
    } else if (range.includes('-')) {
      const [a, b, more] = range.split('-');
      if (more !== undefined || !a || !b) throw new CronError(`"${range}" is not a valid ${f.name} range.`);
      lo = parseValue(a, f);
      hi = parseValue(b, f);
      if (lo > hi) throw new CronError(`The ${f.name} range ${range} runs backwards.`);
    } else {
      lo = parseValue(range, f);
      hi = stepText !== undefined ? f.max : lo; // "5/15" = from 5 to the end, every 15
    }
    for (let v = lo; v <= hi; v += step) out.add(v);
  }
  return out;
}

/** Parse a cron expression; throws CronError with a short, user-facing message. */
export function parseCron(expression: string): CronSpec {
  const trimmed = expression.trim().replace(/\s+/g, ' ');
  if (trimmed === '') throw new CronError('The schedule is empty.');
  if (trimmed.startsWith('@')) {
    const expanded = NICKNAMES[trimmed.toLowerCase()];
    if (!expanded) throw new CronError(`${trimmed} is not supported; use a 5-field schedule, @hourly or @daily.`);
    return { ...parseCron(expanded), source: trimmed };
  }
  const parts = trimmed.split(' ');
  if (parts.length !== 5) {
    throw new CronError(`A schedule has 5 fields (minute hour day month weekday); this one has ${parts.length}.`);
  }
  const [m, h, dom, mon, dow] = parts.map((p, i) => parseField(p, FIELDS[i]!));
  const weekdays = new Set([...dow!].map((d) => d % 7)); // 7 = Sunday
  return {
    source: trimmed,
    minutes: m!,
    hours: h!,
    days: dom!,
    months: mon!,
    weekdays,
    dayRestricted: !parts[2]!.startsWith('*'),
    weekdayRestricted: !parts[4]!.startsWith('*'),
  };
}

function dayMatches(spec: CronSpec, d: Date): boolean {
  const dom = spec.days.has(d.getDate());
  const dow = spec.weekdays.has(d.getDay());
  if (spec.dayRestricted && spec.weekdayRestricted) return dom || dow;
  if (spec.dayRestricted) return dom;
  if (spec.weekdayRestricted) return dow;
  return true;
}

/** How far ahead nextRun looks before deciding a schedule never runs. */
const SEARCH_YEARS = 5;

/**
 * The first minute strictly after `after` that matches, in local time; undefined when
 * nothing matches within 5 years (e.g. "0 0 30 2 *"). A local time skipped by a DST
 * change (02:30 on the spring-forward day) is skipped, not moved.
 */
export function nextRun(spec: CronSpec, after: Date): Date | undefined {
  const d = new Date(after.getTime());
  d.setSeconds(0, 0);
  d.setMinutes(d.getMinutes() + 1);
  const limitYear = after.getFullYear() + SEARCH_YEARS;
  while (d.getFullYear() <= limitYear) {
    const before = d.getTime();
    if (!spec.months.has(d.getMonth() + 1)) {
      d.setMonth(d.getMonth() + 1, 1);
      d.setHours(0, 0, 0, 0);
    } else if (!dayMatches(spec, d)) {
      d.setDate(d.getDate() + 1);
      d.setHours(0, 0, 0, 0);
    } else if (!spec.hours.has(d.getHours())) {
      d.setHours(d.getHours() + 1, 0, 0, 0);
    } else if (!spec.minutes.has(d.getMinutes())) {
      d.setMinutes(d.getMinutes() + 1, 0, 0);
    } else {
      return d;
    }
    // Local-time arithmetic can stand still across a DST change; always move forward.
    if (d.getTime() <= before) d.setTime(before + 60_000);
  }
  return undefined;
}

/** The preset a cron is a shorthand of ("custom" when none). */
export function presetOf(expression: string): SchedulePreset {
  const s = expression.trim().replace(/\s+/g, ' ').toLowerCase();
  if (s === '*/15 * * * *') return 'every15';
  if (s === '0 * * * *' || s === '@hourly') return 'hourly';
  if (s === '@daily' || /^\d{1,2} \d{1,2} \* \* \*$/.test(s)) return 'daily';
  if (/^\d{1,2} \d{1,2} \* \* 1-5$/.test(s)) return 'weekdays';
  return 'custom';
}

/** Validate a cron and list the next runs (Save stays off while invalid). */
export function checkSchedule(cron: string, now: Date, count = 3): ScheduleCheck {
  let spec: CronSpec;
  try {
    spec = parseCron(cron);
  } catch (err) {
    return { cron, valid: false, error: (err as Error).message, nextRuns: [] };
  }
  const runs: string[] = [];
  let from = now;
  for (let i = 0; i < count; i++) {
    const next = nextRun(spec, from);
    if (!next) break;
    runs.push(isoDate(next));
    from = next;
  }
  if (runs.length === 0) return { cron, valid: false, error: 'This schedule never runs.', nextRuns: [] };
  return { cron, valid: true, preset: presetOf(cron), nextRuns: runs };
}
