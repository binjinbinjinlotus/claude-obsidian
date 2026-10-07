/**
 * Whose items (actions-routing.md): the pure routing rules. The whole-service flows live in
 * actions.test.ts; these pin the table's edges one rule at a time.
 */
import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import type { ActionPerson, ActionPreferences } from '../contracts.js';
import { displayName, handlesFor, matchPerson, nudgeText, ownerInstruction, peopleOf, routeItem, routingOn, YOU_ID } from './routing.js';

const you = (name = 'Jin Liu', aliases: string[] = ['JL']): ActionPerson => ({ id: YOU_ID, name, aliases });
const aditya: ActionPerson = { id: 'p-aditya', name: 'Aditya Pradhan', aliases: ['Aditya', 'A'] };
const mei: ActionPerson = { id: 'p-mei', name: 'Mei Tanaka', aliases: ['@mei'] };
type Prefs = Pick<ActionPreferences, 'people' | 'types'>;
const prefs = (people: ActionPerson[] | undefined, types: Prefs['types'] = {}): Prefs => ({ people, types }) as Prefs;

describe('peopleOf and routingOn', () => {
  test('the user is always first; a list without the user gets an empty one', () => {
    assert.deepEqual(peopleOf({ people: [aditya, you(), mei] }).map((p) => p.id), [YOU_ID, 'p-aditya', 'p-mei']);
    assert.deepEqual(peopleOf({ people: [aditya] }), [{ id: YOU_ID, name: '', aliases: [] }, aditya]);
    assert.deepEqual(peopleOf({} as Prefs), [{ id: YOU_ID, name: '', aliases: [] }]);
  });

  test('entries without a string id are dropped', () => {
    const loose = [null, { name: 'x', aliases: [] }, { id: 7, name: 'y', aliases: [] }, mei] as unknown as ActionPerson[];
    assert.deepEqual(peopleOf({ people: loose }).map((p) => p.id), [YOU_ID, 'p-mei']);
  });

  test('routing is on once the user has a name or a non-blank alias', () => {
    assert.equal(routingOn({ people: [you('Jin', [])] }), true);
    assert.equal(routingOn({ people: [you('', ['JL'])] }), true);
    assert.equal(routingOn({ people: [you('   ', ['  ', ''])] }), false);
    assert.equal(routingOn({ people: [aditya] }), false, 'other people alone do not turn it on');
  });
});

describe('matchPerson', () => {
  const people = peopleOf({ people: [you(), aditya, mei] });

  test('the words for the user, in any case and spacing, are the user', () => {
    for (const w of ['me', ' Me ', 'I', 'the user', 'USER', 'you', 'myself']) assert.equal(matchPerson(w, people), YOU_ID, w);
  });

  test('a name or an alias matches exactly, trimmed and case-insensitive', () => {
    assert.equal(matchPerson('aditya pradhan', people), 'p-aditya');
    assert.equal(matchPerson('  A ', people), 'p-aditya');
    assert.equal(matchPerson('@MEI', people), 'p-mei');
    assert.equal(matchPerson('jl', people), YOU_ID, "the user's alias");
    assert.equal(matchPerson('Aditya P', people), undefined, 'no partial match');
    assert.equal(matchPerson('Mei', people), undefined, 'a first name is not the name');
  });

  test('empty is no match; a name that fits two people is ambiguous (null)', () => {
    assert.equal(matchPerson('', people), undefined);
    assert.equal(matchPerson('   ', people), undefined);
    assert.equal(matchPerson(null, people), undefined);
    assert.equal(matchPerson(undefined, people), undefined);
    const two = [...people, { id: 'p-a2', name: 'Ana', aliases: ['A'] }];
    assert.equal(matchPerson('a', two), null);
  });

  test('a blank alias never matches anything', () => {
    const blank = [{ id: 'p-b', name: 'Bo', aliases: ['', '  '] }];
    assert.equal(matchPerson('Bo', blank), 'p-b');
    assert.equal(matchPerson('x', blank), undefined);
  });
});

describe('handlesFor', () => {
  test('default is the user alone; a set keeps only known people', () => {
    const p = prefs([you(), aditya]);
    assert.deepEqual(handlesFor(p, 'todo'), [YOU_ID]);
    assert.deepEqual(handlesFor(prefs([you(), aditya], { todo: { handlesFor: ['p-aditya', 'p-gone', YOU_ID] } } as unknown as Prefs['types']), 'todo'), ['p-aditya', YOU_ID]);
    assert.deepEqual(handlesFor(prefs([you()], { todo: { handlesFor: [] } } as unknown as Prefs['types']), 'todo'), [], 'an empty set means nobody');
    assert.deepEqual(handlesFor(prefs([you()], { todo: { handlesFor: 'you' } } as unknown as Prefs['types']), 'todo'), [YOU_ID], 'not a list: the default');
    assert.deepEqual(handlesFor(prefs([you()], { slack: { handlesFor: [] } } as unknown as Prefs['types']), 'todo'), [YOU_ID], 'per type');
  });
});

describe('routeItem', () => {
  const p = prefs([you(), aditya, mei], { todo: { handlesFor: [YOU_ID, 'p-aditya'] } } as unknown as Prefs['types']);

  test('routing off: everything to your lists, never unclear', () => {
    assert.deepEqual(routeItem({ type: 'todo', owner: 'Vladan', owedTo: 'me' }, prefs([aditya])), { route: 'list', ownerID: null, owedToID: null, unclear: false });
  });

  test('no owner, or an ambiguous one, asks; owedTo is still read', () => {
    assert.deepEqual(routeItem({ type: 'todo', owedTo: 'me' }, p), { route: 'list', ownerID: null, owedToID: YOU_ID, unclear: true });
    assert.deepEqual(routeItem({ type: 'todo', owner: '  ' }, p), { route: 'list', ownerID: null, owedToID: null, unclear: true });
    const two = prefs([you(), aditya, { id: 'p-ana', name: 'Ana', aliases: ['A'] }]);
    assert.deepEqual(routeItem({ type: 'todo', owner: 'A' }, two), { route: 'list', ownerID: null, owedToID: null, unclear: true });
  });

  test('a promise to the user is Pending, even from someone you handle or no one in People', () => {
    assert.deepEqual(routeItem({ type: 'todo', owner: 'Aditya', owedTo: 'me' }, p), { route: 'waiting', ownerID: 'p-aditya', owedToID: YOU_ID, unclear: false });
    assert.deepEqual(routeItem({ type: 'todo', owner: 'Vladan', owedTo: 'I' }, p), { route: 'waiting', ownerID: null, owedToID: YOU_ID, unclear: false });
  });

  test('your own promise to yourself is yours', () => {
    assert.deepEqual(routeItem({ type: 'todo', owner: 'me', owedTo: 'me' }, p), { route: 'list', ownerID: YOU_ID, owedToID: YOU_ID, unclear: false });
  });

  test('owners you handle go to your lists; anyone else to Highlights', () => {
    assert.deepEqual(routeItem({ type: 'todo', owner: 'Aditya', owedTo: 'Mei Tanaka' }, p), { route: 'list', ownerID: 'p-aditya', owedToID: 'p-mei', unclear: false });
    assert.deepEqual(routeItem({ type: 'todo', owner: '@mei' }, p), { route: 'others', ownerID: 'p-mei', owedToID: null, unclear: false });
    assert.deepEqual(routeItem({ type: 'todo', owner: 'Vladan' }, p), { route: 'others', ownerID: null, owedToID: null, unclear: false });
    assert.equal(routeItem({ type: 'slack', owner: 'Aditya' }, p).route, 'others', 'handlesFor is per type');
    assert.equal(routeItem({ type: 'slack', owner: 'me' }, p).route, 'list');
  });
});

describe('displayName, nudgeText and the owner instruction', () => {
  const people = peopleOf({ people: [you('  Jin  '), aditya, { id: 'p-blank', name: ' ', aliases: [] }] });

  test('the People name when matched, else as written, else a fallback', () => {
    assert.equal(displayName('p-aditya', 'A', people), 'Aditya Pradhan');
    assert.equal(displayName(YOU_ID, 'me', people), 'Jin');
    assert.equal(displayName(YOU_ID, 'me', peopleOf({ people: [] })), 'You', 'the user without a name');
    assert.equal(displayName('p-blank', '  Bo ', people), 'Bo', 'a blank People name shows what was written');
    assert.equal(displayName(null, ' Vladan ', people), 'Vladan');
    assert.equal(displayName('p-gone', null, people), 'Someone');
    assert.equal(displayName(undefined, '   ', people), 'Someone');
  });

  test('a nudge greets by first name and names the thing', () => {
    assert.equal(nudgeText('  Aditya   Pradhan ', ' the ticket links '), 'Hi Aditya, any update on the ticket links?');
    assert.equal(nudgeText('', ''), 'Hi there, any update on this?');
  });

  test("the owner instruction quotes the user's names, and only when there are some", () => {
    const named = ownerInstruction({ people: [you('Jin Liu', [' JL ', ''])] });
    assert.match(named, /\(the notes call them "Jin Liu", "JL"\)/);
    assert.match(named, /Write "me" when it is the user/);
    const bare = ownerInstruction({ people: [] });
    assert.doesNotMatch(bare, /the notes call them/);
    assert.match(bare, /the person these notes belong to; "I'll…"/, 'nothing added between the sentence and its end');
  });
});
