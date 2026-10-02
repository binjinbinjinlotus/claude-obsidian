/**
 * Manual smoke: one real actionFind run (Claude Code · Sonnet) over a throwaway
 * note, in a temp state dir. Never touches the real state dir or a real vault.
 *   node --import tsx src/dev/actions-smoke.ts
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createActionsService } from '../actions/index.js';
import { defaultRegistry } from '../runners/registry.js';
import { MemorySecretStore } from '../runners/secrets.js';
import { decodeSettings } from '../store/settings.js';

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-actions-smoke-'));
const vault = path.join(root, 'vault');
fs.mkdirSync(path.join(vault, 'wiki', 'sources'), { recursive: true });
fs.writeFileSync(
  path.join(vault, 'wiki', 'sources', 'tea.md'),
  `---\ntitle: "Tea club planning"\n---\n\n# Tea club planning\n\nI’ll book the tasting room for Saturday afternoon and tell Mei so she can bring the new tin.\nThe payment client retry cap still needs a ticket in PX before Thursday.\nThe gyokuro was best at 60 °C.\n`,
);
const settings = decodeSettings({ vaults: [{ path: vault, queueDirectory: path.join(root, 'q') }], activeVaultPath: vault });
const service = createActionsService({
  emit: (e) => (e.type === 'progress' ? console.log('progress:', e.progress.message) : undefined),
  getSettings: () => settings,
  runners: defaultRegistry({ secrets: new MemorySecretStore() }),
  file: path.join(root, 'state', 'actions.json'),
  stateDir: path.join(root, 'state'),
  secrets: new MemorySecretStore(),
  setJobActions: (id, s) => console.log('summary:', JSON.stringify(s)),
});
await service.findInJob({
  id: 'job-smoke',
  kind: 'ingest',
  vaultPath: vault,
  files: [],
  sessionID: 's',
  model: 'sonnet',
  state: 'completed',
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
  turns: [],
  grantedTools: [],
  changedPaths: ['wiki/sources/tea.md'],
});
for (const a of await service.listActions()) console.log(`${a.type}\t${a.status}\t${a.title}\t${JSON.stringify(a.fields)}\t"${a.source.kind === 'note' ? a.source.quote : ''}"`);
fs.rmSync(root, { recursive: true, force: true });
