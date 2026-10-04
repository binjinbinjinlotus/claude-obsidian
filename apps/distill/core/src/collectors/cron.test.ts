import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import { checkSchedule, nextRun, parseCron, presetOf } from './cron.js';

// Expected values are built with local-time constructors, so these pass in any time zone.
const at = (y: number, mo: number, d: number, h = 0, mi = 0) => new Date(y, mo - 1, d, h, mi);
const next = (cron: string, after: Date) => nextRun(parseCron(cron), after);

describe('cron parsing', () => {
  test('rejects malformed expressions with a short reason', () => {
    for (const bad of ['', '* * * *', '* * * * * *', '60 * * * *', '* 24 * * *', '* * 0 * *', '* * * 13 *', '* * * * 8',
      '*/0 * * * *', '5-1 * * * *', 'a * * * *', '1,,2 * * * *', '@reboot', '@weekly', '1-2-3 * * * *', '*/x * * * *']) {
      assert.throws(() => parseCron(bad), (err: Error) => err.message.length > 0, bad);
    }
  });

  test('accepts lists, ranges, steps, names, @hourly and @daily', () => {
    const s = parseCron('0,30 9-17/2 * jan-mar mon-fri');
    assert.deepEqual([...s.minutes], [0, 30]);
    assert.deepEqual([...s.hours], [9, 11, 13, 15, 17]);
    assert.deepEqual([...s.months], [1, 2, 3]);
    assert.deepEqual([...s.weekdays], [1, 2, 3, 4, 5]);
    assert.deepEqual([...parseCron('5/20 * * * *').minutes], [5, 25, 45]);
    assert.deepEqual([...parseCron('@hourly').minutes], [0]);
    assert.deepEqual([...parseCron('@daily').hours], [0]);
    assert.deepEqual([...parseCron('0 0 * * 7').weekdays], [0], 'day of week 7 is Sunday');
    assert.equal(parseCron('  0   *  * * * ').source, '0 * * * *');
  });

  test('presets are shorthands', () => {
    assert.equal(presetOf('*/15 * * * *'), 'every15');
    assert.equal(presetOf('0 * * * *'), 'hourly');
    assert.equal(presetOf('@hourly'), 'hourly');
    assert.equal(presetOf('30 8 * * *'), 'daily');
    assert.equal(presetOf('@daily'), 'daily');
    assert.equal(presetOf('30 8 * * 1-5'), 'weekdays');
    assert.equal(presetOf('30 8 * * 1,3,5'), 'custom');
  });
});

describe('next run (local time)', () => {
  test('every 15 minutes and every hour, strictly after', () => {
    assert.deepEqual(next('*/15 * * * *', at(2026, 10, 4, 10, 7)), at(2026, 10, 4, 10, 15));
    assert.deepEqual(next('*/15 * * * *', at(2026, 10, 4, 10, 45)), at(2026, 10, 4, 11, 0));
    assert.deepEqual(next('0 * * * *', at(2026, 10, 4, 10, 0)), at(2026, 10, 4, 11, 0));
    const withSeconds = new Date(2026, 9, 4, 10, 59, 59, 999);
    assert.deepEqual(next('0 * * * *', withSeconds), at(2026, 10, 4, 11, 0));
  });

  test('daily, weekdays (Sunday Oct 4 2026 → Monday), month rollover and year rollover', () => {
    assert.deepEqual(next('30 8 * * *', at(2026, 10, 4, 9, 0)), at(2026, 10, 5, 8, 30));
    assert.deepEqual(next('30 8 * * 1-5', at(2026, 10, 2, 9, 0)), at(2026, 10, 5, 8, 30)); // Friday after 8:30 → Monday
    assert.deepEqual(next('0 0 1 * *', at(2026, 10, 4)), at(2026, 11, 1));
    assert.deepEqual(next('0 0 1 1 *', at(2026, 10, 4)), at(2027, 1, 1));
    assert.deepEqual(next('0 9 31 * *', at(2026, 10, 31, 10)), at(2026, 12, 31, 9)); // November has no 31st
  });

  test('day of month OR day of week when both are restricted', () => {
    // 13th of the month or any Friday: after Sun Oct 4 2026 the next is Fri Oct 9.
    assert.deepEqual(next('0 0 13 * 5', at(2026, 10, 4)), at(2026, 10, 9));
    // After Fri Oct 9: Tue Oct 13 comes before Fri Oct 16.
    assert.deepEqual(next('0 0 13 * 5', at(2026, 10, 9, 1)), at(2026, 10, 13));
    // Only one restricted: AND with "*" means just that one.
    assert.deepEqual(next('0 0 13 * *', at(2026, 10, 4)), at(2026, 10, 13));
    assert.deepEqual(next('0 0 * * 0', at(2026, 10, 4, 1)), at(2026, 10, 11));
    assert.deepEqual(next('0 0 * * 7', at(2026, 10, 4, 1)), at(2026, 10, 11));
  });

  test('Feb 29 is found in a leap year; an impossible date never runs and is invalid', () => {
    assert.deepEqual(next('0 0 29 2 *', at(2026, 10, 4)), at(2028, 2, 29));
    assert.equal(next('0 0 30 2 *', at(2026, 10, 4)), undefined);
    const check = checkSchedule('0 0 30 2 *', at(2026, 10, 4));
    assert.equal(check.valid, false);
    assert.match(check.error!, /never runs/);
  });

  test('checkSchedule lists the next three runs and the preset', () => {
    const c = checkSchedule('0 * * * *', at(2026, 10, 4, 10, 30));
    assert.equal(c.valid, true);
    assert.equal(c.preset, 'hourly');
    assert.deepEqual(c.nextRuns.map((r) => new Date(r).getTime()), [at(2026, 10, 4, 11), at(2026, 10, 4, 12), at(2026, 10, 4, 13)].map((d) => d.getTime()));
    const bad = checkSchedule('* * *', at(2026, 10, 4));
    assert.equal(bad.valid, false);
    assert.deepEqual(bad.nextRuns, []);
  });
});
