/**
 * Whose items Distill handles (actions-routing.md). Pure: decides where a found item goes from
 * its owner (who has to do it) and, for a promise, who it is owed to.
 *
 *   owner unclear                         → your lists, To confirm asks "Whose is this?"
 *   someone else owes the user something  → Pending (waiting), whoever it is
 *   owner is one of the type's people     → your lists ("for Aditya" when not you)
 *   anything else                         → the note's Highlights, Others' actions
 *
 * Names match the People list exactly (trimmed, case-insensitive) on a name or an alias; "me"
 * is the user. Until the user has a name or an alias, routing is off and every item goes to
 * your lists, as before.
 */
import type { ActionPerson, ActionPreferences, ActionRoute } from '../contracts.js';

export const YOU_ID = 'you';
/** What the find step writes for the user. */
const ME_WORDS = ['me', 'i', 'the user', 'user', 'you', 'myself'];

/** The People list with the user first (an empty one when Settings has none). */
export function peopleOf(p: Pick<ActionPreferences, 'people'>): ActionPerson[] {
  const list = (p.people ?? []).filter((x) => x && typeof x.id === 'string');
  const you = list.find((x) => x.id === YOU_ID) ?? { id: YOU_ID, name: '', aliases: [] };
  return [you, ...list.filter((x) => x.id !== YOU_ID)];
}

/** Routing is on once the user has a name or an alias. */
export function routingOn(p: Pick<ActionPreferences, 'people'>): boolean {
  const you = peopleOf(p)[0]!;
  return you.name.trim() !== '' || you.aliases.some((a) => a.trim() !== '');
}

const fold = (s: string) => s.trim().toLocaleLowerCase('en-US');

/**
 * The People id a name as written matches: "me" → you; else exact on a name or an alias.
 * undefined = no match; null = it matches more than one person (ambiguous: ask).
 */
export function matchPerson(name: string | null | undefined, people: ActionPerson[]): string | null | undefined {
  const n = fold(name ?? '');
  if (n === '') return undefined;
  if (ME_WORDS.includes(n)) return YOU_ID;
  const hits = people.filter((p) => [p.name, ...p.aliases].some((x) => x.trim() !== '' && fold(x) === n));
  if (hits.length === 1) return hits[0]!.id;
  return hits.length > 1 ? null : undefined;
}

/** People ids whose items of this type go to your lists (default: you). */
export function handlesFor(p: Pick<ActionPreferences, 'people' | 'types'>, type: string): string[] {
  const ids = new Set(peopleOf(p).map((x) => x.id));
  const set = p.types[type]?.handlesFor;
  if (!Array.isArray(set)) return [YOU_ID];
  return set.filter((id) => ids.has(id));
}

export interface RouteInput {
  type: string;
  owner?: string | null;
  owedTo?: string | null;
}

export interface RouteResult {
  route: ActionRoute;
  ownerID: string | null;
  owedToID: string | null;
  unclear: boolean;
}

export function routeItem(input: RouteInput, p: Pick<ActionPreferences, 'people' | 'types'>): RouteResult {
  if (!routingOn(p)) return { route: 'list', ownerID: null, owedToID: null, unclear: false };
  const people = peopleOf(p);
  const owner = matchPerson(input.owner, people);
  const owedTo = matchPerson(input.owedTo, people);
  const ownerID = owner ?? null;
  const owedToID = owedTo ?? null;
  // No owner, or a name that fits two people: ask.
  if (owner === null || fold(input.owner ?? '') === '') return { route: 'list', ownerID: null, owedToID, unclear: true };
  // A promise to the user is something to wait for, even from someone whose items you handle.
  if (owedToID === YOU_ID && ownerID !== YOU_ID) return { route: 'waiting', ownerID, owedToID, unclear: false };
  if (ownerID && handlesFor(p, input.type).includes(ownerID)) return { route: 'list', ownerID, owedToID, unclear: false };
  return { route: 'others', ownerID, owedToID, unclear: false };
}

/** The name to show for an owner: the People name when matched, else as written. */
export function displayName(id: string | null | undefined, written: string | null | undefined, people: ActionPerson[]): string {
  const p = id ? people.find((x) => x.id === id) : undefined;
  if (p && p.name.trim()) return p.name.trim();
  if (id === YOU_ID) return 'You';
  return (written ?? '').trim() || 'Someone';
}

/** "Hi Aditya, any update on the ticket links?" (the Nudge prefill). */
export function nudgeText(person: string, what: string): string {
  const first = person.trim().split(/\s+/)[0] ?? '';
  return `Hi ${first || 'there'}, any update on ${what.trim() || 'this'}?`;
}

/** The find step's owner instruction (added to every find prompt while routing is on). */
export function ownerInstruction(p: Pick<ActionPreferences, 'people'>): string {
  const you = peopleOf(p)[0]!;
  const names = [you.name, ...you.aliases].map((x) => x.trim()).filter(Boolean);
  return `- owner: who has to do it, the name as the documents write it ("Aditya", "A", "@mei"). Write "me" when it is the user, the person these notes belong to${names.length > 0 ? ` (the notes call them ${names.map((n) => `"${n}"`).join(', ')})` : ''}; "I'll…" in the user's own notes is the user. Leave it empty when the documents don't say who.
- owedTo: for something someone said they would do FOR the user (send them something, review their work), "me"; for something owed to another person, their name as written; else empty.
- what: for a promise, the thing itself in a few words, e.g. "the ticket links".
- due: the date it is due, YYYY-MM-DD, when the documents say.
Include actions for everyone in the documents, not only the user's: each gets its owner.`;
}
