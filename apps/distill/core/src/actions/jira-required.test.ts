/**
 * Jira required fields, the pure part (actions.md, "Jira required fields"): a field's kind from its
 * schema, allowed values with ids, the payload per kind, the check before Create and the note prefill.
 * No Jira, no store: plain values in, plain values out.
 */
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { JiraField } from '../contracts.js';
import {
  asked, checkRequired, defaultsKey, extraFields, fieldKey, fieldKind, fromKey, fromNote, isEmptyValue, optionsOf, payloadValue, readField,
  STANDARD_JIRA_FIELDS, valueFor,
} from './jira-required.js';
import { markdownToADF } from './markdown.js';

const field = (id: string, o: Partial<JiraField> = {}): JiraField => ({ id, name: id.toUpperCase(), required: false, ...o });
const TEAMS = [{ id: '1', name: 'Platform' }, { id: '2', name: 'Payments' }];

describe('keys', () => {
  test('a value under jira.<id>, its source under jira.<id>:from; defaults by "PROJECT|Type"', () => {
    assert.equal(fieldKey('customfield_1'), 'jira.customfield_1');
    assert.equal(fromKey('customfield_1'), 'jira.customfield_1:from');
    assert.equal(defaultsKey('  tls ', '  Task '), 'TLS|Task');
  });

  test('the standard fields are the ones the ticket fills itself', () => {
    assert.deepEqual([...STANDARD_JIRA_FIELDS].sort(), ['assignee', 'attachment', 'description', 'issuelinks', 'issuetype', 'labels', 'parent', 'priority', 'project', 'reporter', 'summary']);
  });
});

describe('fieldKind', () => {
  test('each schema type maps to its control', () => {
    const cases: [JiraField['schema'], string][] = [
      [undefined, 'unsupported'],
      [null, 'unsupported'],
      [{ type: 'option' }, 'option'],
      [{ type: 'component' }, 'option'],
      [{ type: 'version' }, 'option'],
      [{ type: 'array', items: 'option' }, 'options'],
      [{ type: 'array', items: 'component' }, 'options'],
      [{ type: 'array', items: 'version' }, 'options'],
      [{ type: 'array', items: 'string' }, 'unsupported'],
      [{ type: 'array', items: 'user' }, 'unsupported'],
      [{ type: 'array' }, 'unsupported'],
      [{ type: 'array', items: null }, 'unsupported'],
      [{ type: 'string' }, 'text'],
      [{ type: 'string', custom: null }, 'text'],
      [{ type: 'string', custom: 'com.atlassian.jira.plugin.system.customfieldtypes:textfield' }, 'text'],
      [{ type: 'string', custom: 'com.atlassian.jira.plugin.system.customfieldtypes:textarea' }, 'textarea'],
      [{ type: 'string', system: 'environment' }, 'textarea'],
      [{ type: 'string', system: 'summary' }, 'text'],
      [{ type: 'number' }, 'number'],
      [{ type: 'date' }, 'date'],
      [{ type: 'datetime' }, 'unsupported'],
      [{ type: 'user' }, 'user'],
      [{ type: 'option-with-child' }, 'cascading'],
      [{ type: 'any' }, 'unsupported'],
      [{ type: '' }, 'unsupported'],
    ];
    for (const [schema, kind] of cases) assert.equal(fieldKind(schema), kind, JSON.stringify(schema));
  });
});

describe('optionsOf', () => {
  test('not a list: undefined; an empty list: none', () => {
    assert.equal(optionsOf(undefined), undefined);
    assert.equal(optionsOf({ id: '1' }), undefined);
    assert.deepEqual(optionsOf([]), []);
  });

  test('ids as text or numbers; the value before the name; entries without both left out', () => {
    assert.deepEqual(
      optionsOf([null, 'x', { id: '1', value: 'Platform', name: 'ignored' }, { id: 2, name: 'Payments' }, { id: '3' }, { value: 'No id' }, { id: '', value: 'Empty id' }, { id: '4', value: '' }, { id: true, value: 'Odd id' }]),
      [{ id: '1', name: 'Platform' }, { id: '2', name: 'Payments' }],
    );
  });

  test('a cascading parent keeps its children (same rules); no children list: no key', () => {
    assert.deepEqual(
      optionsOf([
        { id: '10', value: 'Staging', children: [{ id: '11', value: 'us-east-1' }, { id: 12, name: 'eu-west-1' }, null, { id: '13' }, { value: 'no id' }, { id: false, value: 'odd' }] },
        { id: '20', value: 'Prod', children: [] },
        { id: '30', value: 'Dev', children: 'nope' },
      ]),
      [
        { id: '10', name: 'Staging', children: [{ id: '11', name: 'us-east-1' }, { id: '12', name: 'eu-west-1' }] },
        { id: '20', name: 'Prod', children: [] },
        { id: '30', name: 'Dev' },
      ],
    );
  });
});

describe('readField', () => {
  test('the full shape: schema, kind, allowed names, options with ids, a Jira default', () => {
    assert.deepEqual(
      readField({ fieldId: 'customfield_11063', key: 'other', name: 'Team', required: true, hasDefaultValue: true, schema: { type: 'option', custom: 'select', items: 7 }, allowedValues: [{ id: '1', value: 'Platform' }, { id: '2', name: 'Payments' }] }),
      {
        id: 'customfield_11063', name: 'Team', required: true,
        allowed: ['Platform', 'Payments'],
        schema: { type: 'option', items: null, custom: 'select', system: null },
        kind: 'option',
        options: [{ id: '1', name: 'Platform' }, { id: '2', name: 'Payments' }],
        hasDefault: true,
      },
    );
  });

  test('the key when there is no fieldId; a schema without a type; only `true` is required or a default; no options when none have ids', () => {
    assert.deepEqual(
      readField({ key: 'components', name: 'Components', required: 'yes', hasDefaultValue: 'yes', schema: { items: 'component', system: 'components' }, allowedValues: [{ name: 'API' }] }),
      { id: 'components', name: 'Components', required: false, allowed: ['API'], schema: { type: '', items: 'component', custom: null, system: 'components' }, kind: 'unsupported' },
    );
  });

  test('no schema: unsupported with no schema key; nothing named: empty strings', () => {
    assert.deepEqual(readField({ schema: 'string' }), { id: '', name: '', required: false, kind: 'unsupported' });
  });
});

describe('extraFields and asked', () => {
  const fields = [
    field('summary', { required: true }),
    field('cf_opt', {}),
    field('cf_team', { required: true }),
    field('', { required: true }),
    field('reporter', { required: true, hasDefault: true }),
    field('cf_defaulted', { required: true, hasDefault: true }),
    field('cf_env', { required: true }),
  ];

  test('standard and id-less fields left out; required without a default first, each group in screen order', () => {
    assert.deepEqual(extraFields(fields).map((f) => f.id), ['cf_team', 'cf_env', 'cf_opt', 'cf_defaulted']);
    assert.deepEqual(extraFields([]), []);
  });

  test('asked: required, no Jira default, not a standard field', () => {
    assert.deepEqual(fields.filter(asked).map((f) => f.id), ['cf_team', '', 'cf_env']);
  });
});

describe('isEmptyValue', () => {
  test('nothing, blank text, an empty list or object', () => {
    for (const v of [null, undefined, '', '   ', '[]', ' [] ', '{}', '\t{}\n']) assert.equal(isEmptyValue(v), true, JSON.stringify(v));
    for (const v of ['x', '0', '[""]', '{"a":1}', '[ ]']) assert.equal(isEmptyValue(v), false, JSON.stringify(v));
  });
});

describe('payloadValue', () => {
  const opt = field('cf_team', { name: 'Team', kind: 'option', options: TEAMS });

  test('one choice: its id, by name ignoring case and spaces; outside the list: plain words', () => {
    assert.deepEqual(payloadValue(opt, ' platform '), { value: { id: '1' } });
    assert.deepEqual(payloadValue(opt, 'Juggling'), { problem: 'Juggling isn’t a choice for Team. Pick one.' });
    assert.deepEqual(payloadValue({ ...opt, options: undefined }, 'Platform'), { problem: 'Platform isn’t a choice for Team. Pick one.' });
    assert.deepEqual(payloadValue({ ...opt, options: [{ id: '9', name: ' Data  ' }] }, 'data'), { value: { id: '9' } }, 'Jira’s name is folded too');
  });

  test('the kind comes from the schema when the field has none', () => {
    assert.deepEqual(payloadValue(field('cf', { name: 'N', schema: { type: 'number' } }), '4'), { value: 4 });
    assert.deepEqual(payloadValue(field('cf', { name: 'N', schema: { type: 'number' }, kind: 'text' }), '4'), { value: '4' }, 'a kind given wins');
  });

  test('several choices: a JSON list (strings only) or comma text; each must be a choice', () => {
    const many = field('components', { name: 'Components', kind: 'options', options: TEAMS });
    assert.deepEqual(payloadValue(many, '["Platform", 3, "payments"]'), { value: [{ id: '1' }, { id: '2' }] });
    assert.deepEqual(payloadValue(many, ' Platform , ,Payments '), { value: [{ id: '1' }, { id: '2' }] });
    assert.deepEqual(payloadValue(many, '{"a":1}'), { problem: '{"a":1} isn’t a choice for Components. Pick one.' }, 'not a list: read as text');
    assert.deepEqual(payloadValue(many, '["Platform","Nope"]'), { problem: 'Nope isn’t a choice for Components. Pick one.' });
    assert.deepEqual(payloadValue(many, '[]'), { value: [] });
  });

  test('text trimmed; a text area as a document; a number; a day', () => {
    assert.deepEqual(payloadValue(field('t', { kind: 'text' }), '  hi  '), { value: 'hi' });
    assert.deepEqual(payloadValue(field('t', { kind: 'textarea' }), '# Plan\n\n- one'), { value: markdownToADF('# Plan\n\n- one') });
    assert.deepEqual(payloadValue(field('n', { name: 'Points', kind: 'number' }), ' 2.5 '), { value: 2.5 });
    assert.deepEqual(payloadValue(field('n', { name: 'Points', kind: 'number' }), 'three'), { problem: 'Points needs a number.' });
    assert.deepEqual(payloadValue(field('n', { name: 'Points', kind: 'number' }), 'Infinity'), { problem: 'Points needs a number.' });
    assert.deepEqual(payloadValue(field('d', { name: 'Due', kind: 'date' }), ' 2026-10-16 '), { value: '2026-10-16' });
    for (const bad of ['Oct 16', '2026-10-16T00:00', 'x2026-10-16', '26-10-16']) assert.deepEqual(payloadValue(field('d', { name: 'Due', kind: 'date' }), bad), { problem: 'Due needs a date.' }, bad);
  });

  test('a person: the account id from {accountId, name}; anything else asks to pick', () => {
    const user = field('u', { name: 'Reviewer', kind: 'user' });
    assert.deepEqual(payloadValue(user, '{"accountId":"acc-9","name":"Mei"}'), { value: { accountId: 'acc-9' } });
    for (const bad of ['Mei', '{"name":"Mei"}', '{"accountId":7}', '["acc-9"]']) assert.deepEqual(payloadValue(user, bad), { problem: 'Pick Reviewer from the people Jira knows.' }, bad);
  });

  test('cascading: parent, or parent and child, from a JSON pair or "parent › child"', () => {
    const env = field('cf_env', { name: 'Environment', kind: 'cascading', options: [{ id: '10', name: 'Staging', children: [{ id: '11', name: 'us-east-1' }] }, { id: '20', name: 'Prod' }] });
    assert.deepEqual(payloadValue(env, '["staging","US-EAST-1"]'), { value: { id: '10', child: { id: '11' } } });
    assert.deepEqual(payloadValue(env, 'Staging › us-east-1'), { value: { id: '10', child: { id: '11' } } });
    assert.deepEqual(payloadValue(env, '["Prod"]'), { value: { id: '20' } });
    assert.deepEqual(payloadValue(env, 'Prod'), { value: { id: '20' } });
    assert.deepEqual(payloadValue(env, 'Prod › eu'), { problem: 'eu isn’t a choice for Environment. Pick one.' }, 'a parent with no children');
    assert.deepEqual(payloadValue(env, 'Staging › eu'), { problem: 'eu isn’t a choice for Environment. Pick one.' });
    assert.deepEqual(payloadValue(env, 'Dev › x'), { problem: 'Dev isn’t a choice for Environment. Pick one.' });
    assert.deepEqual(payloadValue(env, '[]'), { problem: '[] isn’t a choice for Environment. Pick one.' }, 'no parent: the raw value is named');
  });

  test('an unsupported kind can only be filled in Jira', () => {
    assert.deepEqual(payloadValue(field('cf', { name: 'Rollout plan', kind: 'unsupported' }), 'x'), { problem: 'Rollout plan can only be filled in Jira' });
    assert.deepEqual(payloadValue(field('cf', { name: 'Rollout plan' }), 'x'), { problem: 'Rollout plan can only be filled in Jira' }, 'no kind and no schema');
  });
});

describe('valueFor', () => {
  const f = field('cf_team');
  test("the item's own value, else the saved one, else nothing", () => {
    assert.equal(valueFor(f, { 'jira.cf_team': ' Platform ' }, { cf_team: { name: 'Team', value: 'Payments' } }), ' Platform ');
    assert.equal(valueFor(f, { 'jira.cf_team': '  ' }, { cf_team: { name: 'Team', value: 'Payments' } }), 'Payments');
    assert.equal(valueFor(f, { 'jira.cf_team': null }, { cf_team: { name: 'Team', value: '[]' } }), undefined);
    assert.equal(valueFor(f, {}, { other: { name: 'Other', value: 'x' } }), undefined);
    assert.equal(valueFor(f, {}, undefined), undefined);
    assert.equal(valueFor(f, { cf_team: 'Platform' }, undefined), undefined, 'only under jira.<id>');
  });
});

describe('checkRequired', () => {
  const team = field('cf_team', { name: 'Team', required: true, kind: 'option', options: TEAMS });
  const points = field('cf_points', { name: 'Points', kind: 'number' });
  const plan = field('cf_plan', { name: 'Rollout plan', required: true, kind: 'unsupported' });

  test('every asked field filled: each value in Jira\'s shape; standard fields and empty optional ones stay out', () => {
    const r = checkRequired([field('summary', { required: true }), points, team], { 'jira.cf_team': 'platform', 'jira.cf_points': '3', 'jira.summary': 'x' }, undefined);
    assert.deepEqual(r, { payload: { cf_team: { id: '1' }, cf_points: 3 } });
    assert.deepEqual(checkRequired([points, team], { 'jira.cf_team': 'Payments' }, undefined), { payload: { cf_team: { id: '2' } } });
  });

  test('a saved value fills an empty field', () => {
    assert.deepEqual(checkRequired([team], {}, { cf_team: { name: 'Team', value: 'Payments' } }), { payload: { cf_team: { id: '2' } } });
  });

  test('an empty asked field refuses by name, with its jira.<id> key; required ones are checked first', () => {
    assert.deepEqual(checkRequired([points, team], { 'jira.cf_points': '3' }, undefined), { payload: {}, problem: { field: 'jira.cf_team', message: 'Fill in Team first' } });
  });

  test('a required field Jira fills itself is not asked', () => {
    assert.deepEqual(checkRequired([{ ...team, hasDefault: true }], {}, undefined), { payload: {} });
  });

  test('an asked field Distill cannot fill refuses even with a value; an optional one is left out', () => {
    assert.deepEqual(checkRequired([plan], { 'jira.cf_plan': 'Ship it' }, undefined), { payload: {}, problem: { field: 'jira.cf_plan', message: 'Rollout plan can only be filled in Jira' } });
    assert.deepEqual(checkRequired([plan], {}, undefined), { payload: {}, problem: { field: 'jira.cf_plan', message: 'Rollout plan can only be filled in Jira' } });
    assert.deepEqual(checkRequired([{ ...plan, required: false }, points], { 'jira.cf_plan': 'Ship it', 'jira.cf_points': '2' }, undefined), { payload: { cf_points: 2 } });
    assert.deepEqual(checkRequired([field('cf_x', { name: 'X', schema: { type: 'any' } })], { 'jira.cf_x': 'v' }, undefined), { payload: {} }, 'the kind from the schema');
  });

  test('a value Jira would refuse is refused here, with what was mapped so far', () => {
    assert.deepEqual(checkRequired([team, points], { 'jira.cf_team': 'Platform', 'jira.cf_points': 'lots' }, undefined), { payload: { cf_team: { id: '1' } }, problem: { field: 'jira.cf_points', message: 'Points needs a number.' } });
    assert.deepEqual(checkRequired([team], { 'jira.cf_team': 'Juggling' }, undefined), { payload: {}, problem: { field: 'jira.cf_team', message: 'Juggling isn’t a choice for Team. Pick one.' } });
  });
});

describe('fromNote', () => {
  const team = field('cf_team', { kind: 'option', options: [{ id: '1', name: 'API' }, { id: '2', name: 'Web app' }, { id: '3', name: 'C++' }] });

  test('one choice: the only option the note names, as whole words ignoring case', () => {
    assert.equal(fromNote(team, 'Fix the api layer'), 'API');
    assert.equal(fromNote(team, 'API'), 'API', 'at the start and end');
    assert.equal(fromNote(team, 'rapid fix'), undefined, 'not inside a word');
    assert.equal(fromNote(team, 'apis'), undefined);
    assert.equal(fromNote(team, 'the API_v2'), 'API', 'an underscore is not a letter or digit');
    assert.equal(fromNote(team, 'API2'), undefined, 'a digit joins the word');
    assert.equal(fromNote(team, 'éAPI'), undefined, 'a non-ASCII letter joins the word');
    assert.equal(fromNote(team, 'the web  app'), undefined, 'the name as written');
    assert.equal(fromNote(team, 'the WEB APP team'), 'Web app');
    assert.equal(fromNote(team, 'in C++ code'), 'C++', 'special characters are literal');
    assert.equal(fromNote(team, 'in C code'), undefined);
    assert.equal(fromNote(team, 'API and web app'), undefined, 'two names for one choice: nothing');
    assert.equal(fromNote(team, 'nothing here'), undefined);
  });

  test('several choices: every option named, as a JSON list; none: undefined', () => {
    const many = { ...team, kind: 'options' as const };
    assert.equal(fromNote(many, 'API and web app'), '["API","Web app"]');
    assert.equal(fromNote(many, 'nothing'), undefined);
  });

  test('a blank option name never matches; no options: nothing; the kind from the schema; other kinds: nothing', () => {
    for (const text of ['any text', '', 'a, b', 'x    y']) assert.equal(fromNote(field('x', { kind: 'option', options: [{ id: '1', name: '  ' }] }), text), undefined, JSON.stringify(text));
    assert.equal(fromNote(field('x', { kind: 'option', options: [{ id: '1', name: ' API ' }] }), 'Fix the API layer'), ' API ', 'a name with spaces around it is matched as its words');
    assert.equal(fromNote(field('x', { kind: 'option' }), 'API'), undefined);
    assert.equal(fromNote(field('x', { schema: { type: 'option' }, options: [{ id: '1', name: 'API' }] }), 'API'), 'API');
    assert.equal(fromNote(field('x', { schema: { type: 'array', items: 'option' }, options: [{ id: '1', name: 'API' }] }), 'API'), '["API"]');
    assert.equal(fromNote(field('x', { kind: 'text', options: [{ id: '1', name: 'API' }] }), 'API'), undefined);
  });
});
