---
name: authoring-skills-and-agents
description: Writes and reviews Claude skills (SKILL.md) and agent definitions (.claude/agents/*.md) as frames that set intent, context and preferences, not scripts that cap what the model can do. Use when creating, editing or reviewing any skill, subagent, system prompt or reusable instruction file in this repo.
---

# Authoring skills and agents that don't cap the model

A skill or agent is a **briefing for a very capable colleague**. It isn't a
procedure for a junior one. The model already knows how to write a document,
review code, research a market or test an app. What it lacks is *your*
context: the goal, the audience, local facts, past mistakes, preferences, and
the few lines it must not cross. Give it that, then get out of the way.

This matters more with each model generation. Current Claude models follow
instructions closely and literally, so every rule you write is likely to be
obeyed, including the ones you didn't really mean as limits. Anthropic
removed most of Claude Code's own system prompt for its newest models with no
loss. Over-specifying doesn't make a newer model safer; it makes it smaller.

## What to put in

- **Intent and the reason for it.** Say what the output is for and who uses
  it. The model generalises from a reason ("this goes into a client email,
  so prose reads warmer than bullets"). It can only obey a bare rule ("no
  bullets").
- **Context the model can't know.** Paths, product facts, conventions, names,
  where the source of truth lives, and what was already decided. Point to the
  file rather than restating it.
- **Preferences as defaults, labelled as defaults.** "A sensible default
  structure is …; adapt it to what you find." A strict template is only for
  output a machine or a fixed process consumes.
- **Known gaps.** The mistakes earlier runs actually made, with why they
  happened. This is often the most valuable part of a skill, and it never
  limits anything: it helps the model remember.
- **Real boundaries, kept short.** Safety, user data, irreversible or
  outward-facing actions, and approvals. Give each one its reason.
- **What "great" looks like,** described by its qualities, not by steps.
- **An explicit invitation to go further.** Say plainly that the content is a
  frame, that it's incomplete, and that the model should use its full
  judgement, knowledge and tools beyond it.

## What to leave out

- How to do things the model already knows (how to write, review, search,
  test).
- Long step lists for open-ended work. Steps are for fragile operations.
- Bare rules with no reason, and "always/never" where "prefer" is what you
  mean.
- Shouting: CRITICAL, MUST, ALL CAPS. Newer models already take instructions
  seriously, and emphasis makes them over-apply a rule. Save it for the one
  line that truly can't be broken.
- Exhaustive lists presented as complete. If the list is partial, say so.
- One example presented as *the* format. Show 2–3 varied examples, or label
  the single one as an illustration, so it doesn't get copied.
- A persona so narrow it walls off knowledge, such as "only consider X".
- Time-sensitive facts with no date, and anything that duplicates what the
  repo already records.

## Match the freedom to the risk

| Situation | Freedom | Form |
|---|---|---|
| Many valid approaches (reviews, research, design, writing) | High | Goals, context, qualities, known gaps |
| A preferred pattern with room to adapt (reports, runbooks) | Medium | A default template or a parameterised script, labelled adaptable |
| Fragile or irreversible (migrations, publishing, deleting, user data) | Low | Exact commands or scripts, plus the reason |

A single skill often mixes all three. Keep the low-freedom parts small and
fenced, and leave the rest open.

## Structure that helps without boxing in

- **Frontmatter:**
  - `name`: lowercase-hyphen.
  - `description`: third person, what it does plus when to use it, with the
    trigger words. Only the description is in context until the skill loads,
    so it does all the routing.
  - Agents may add `model` and `tools`. Leave `tools` unset unless there's a
    real reason to restrict them.
- **Body:** short sections. Keep it well under 500 lines. Put long reference
  material in separate files linked one level deep from SKILL.md, so it's read
  only when needed.
- **One term per concept,** used consistently throughout.
- **Point to the source of truth** instead of copying it. Copies drift.

## Before you finish, read it as the model would

For each instruction, ask:

1. Would a strong expert need to be told this? If not, cut it.
2. Does it say *why*? If not, add the reason or cut the rule.
3. Is it a preference written as a law? If so, soften it to a default.
4. Could the model follow it literally and do worse than it would without
   it? If so, rewrite it as a goal.
5. Is anything missing that only we know: context, gaps, boundaries? If so,
   add it.

Then test it. Run a fresh instance with the skill on 2–3 real tasks, and
compare against the same tasks without it. Keep what improved the result.
Remove what it ignored or followed to its detriment. Record misses as known
gaps.

## Illustration (one of many valid shapes)

Caps the model:

> Write the review in this format: Summary (3 bullets), Issues (table with
> columns A, B, C), Recommendations (5 items). Do not include anything else.
> ALWAYS cite the spec.

Frames it:

> The review goes to the owner, who decides what to build next. A useful
> default shape is a short verdict, then issues ranked by user impact, then
> recommendations with effort and confidence. Reshape it if the findings call
> for it. Cite the spec or screen behind each claim, so the owner can check
> it. Add anything you think they should know that they didn't ask about.

## In this repo

- Skills live in `.claude/skills/<name>/SKILL.md`, and agents in
  `.claude/agents/<name>.md`.
  - Product skills under `skills/` follow the stricter portable rules in
    `AGENTS.md`: exactly `name` and `description`.
- Good local examples: `.claude/skills/distill-macos-e2e/` (a frame plus
  known gaps) and `.claude/agents/distill-pm.md` (a persona with an open
  remit and three boundaries).
- When you review an existing skill or agent, report what you'd cut, soften,
  add or test, and why. Change it only when asked.

Sources this draws on, current as of 2026-10:
[Anthropic, Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices);
[Anthropic, Prompting best practices](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices);
[Claude blog, Prompt engineering best practices for 2026](https://claude.com/blog/best-practices-for-prompt-engineering).
