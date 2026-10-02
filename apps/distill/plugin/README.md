# Distill agent plugin

Two portable Agent Skills that let AI agents use Distill through the `distill`
CLI:

| Skill | What it does |
| --- | --- |
| `distill-ask` | Answers questions from the user's own vault with citations (`distill ask … --json`). Read-only. |
| `distill-note` | Queues a note (text, images, source) for Distill to ingest (`distill note add … --json`). |

Agents cannot approve vault changes. The CLI has no approve, apply, reply or
reject command; queued notes go through Review in the Distill app.

This plugin is separate from the repository-root `claude-obsidian` plugin and
is not part of its release artifact.

## 1. Install the `distill` CLI

Requires Node.js 20 or newer.

```bash
cd apps/distill
npm install
npm run build
npm link --workspace @distill/cli   # puts `distill` on your PATH
distill --version
distill status                      # starts the server in the background if needed
```

The CLI starts the Distill core server on demand (`distill serve` runs it in
the foreground). It listens on `127.0.0.1` only and requires the per-user token
in `~/Library/Application Support/Distill/token` (mode 0600). Set
`DISTILL_STATE_DIR` to use another state directory.

## 2. Install the skills

### Claude Code

```bash
distill plugin install --target claude --dry-run   # show the commands
distill plugin install --target claude             # run them
```

which runs:

```bash
claude plugin marketplace add /path/to/claude-obsidian/apps/distill/plugin
claude plugin install distill@distill-local
```

`.claude-plugin/marketplace.json` declares the local marketplace
`distill-local` with this directory as the `distill` plugin. Restart Claude
Code afterwards; the skills appear as `/distill:distill-ask` and
`/distill:distill-note` and also trigger on their own.

To remove: `claude plugin uninstall distill@distill-local` and
`claude plugin marketplace remove distill-local`.

### Codex (and other Agent Skills hosts)

```bash
distill plugin install --target codex --dry-run    # show what would be linked
distill plugin install --target codex              # symlink each skill
distill plugin install --target codex --copy       # copy instead of symlink
```

This creates `~/.agents/skills/distill-ask` and `~/.agents/skills/distill-note`
(symlinks into this directory, so updates to the checkout apply at once).
Existing entries that are not these skills are left alone unless you pass
`--force`. Older Codex builds read `~/.codex/skills/` instead; if Codex does
not list the skills, link them there as well:

```bash
mkdir -p ~/.codex/skills
ln -s "$PWD/skills/distill-ask" ~/.codex/skills/distill-ask
ln -s "$PWD/skills/distill-note" ~/.codex/skills/distill-note
```

## Layout

```
plugin/
  .claude-plugin/plugin.json        Claude Code plugin manifest (name: distill)
  .claude-plugin/marketplace.json   local marketplace (name: distill-local, source ./)
  skills/distill-ask/SKILL.md
  skills/distill-note/SKILL.md
```

Skill frontmatter holds exactly `name` and `description`, like the
repository's `skills/`.
