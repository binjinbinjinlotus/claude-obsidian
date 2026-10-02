#!/usr/bin/env node
// Distill ↔ Vercel AI SDK bridge.
//
// Spawned by the "ai-sdk" runner (ai-sdk.ts) as `node ai-sdk-bridge.mjs`.
// The AI SDK is a library, not a service, and @distill/core has no runtime
// dependencies, so the user installs `ai` plus a provider package in a folder
// of their choice (settings.runnerOptions["ai-sdk"].packageDir), e.g.
//
//   mkdir ~/distill-ai-sdk && cd ~/distill-ai-sdk && npm init -y && npm i ai @ai-sdk/openai
//
// Protocol: one JSON object on stdin
//   { packageDir, provider, model, system?, prompt, schema?, images?: [dataURL], apiKey?, baseURL? }
// and one JSON object on stdout
//   { ok: true, text, object?, usage? }  or  { ok: false, error }
// The API key travels on stdin, never argv or the environment.

import { createRequire } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

export const PROVIDERS = {
  openai: ['@ai-sdk/openai', 'createOpenAI'],
  anthropic: ['@ai-sdk/anthropic', 'createAnthropic'],
  google: ['@ai-sdk/google', 'createGoogleGenerativeAI'],
  openrouter: ['@openrouter/ai-sdk-provider', 'createOpenRouter'],
};

function readStdin() {
  return new Promise((resolve, reject) => {
    const chunks = [];
    process.stdin.on('data', (c) => chunks.push(c));
    process.stdin.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    process.stdin.on('error', reject);
  });
}

async function load(packageDir, specifier) {
  const require = createRequire(path.join(packageDir, 'package.json'));
  let resolved;
  try {
    resolved = require.resolve(specifier);
  } catch {
    throw new Error(`${specifier} is not installed in ${packageDir} (run: npm i ${specifier})`);
  }
  return import(pathToFileURL(resolved).href);
}

async function main() {
  const req = JSON.parse(await readStdin());
  const entry = PROVIDERS[req.provider];
  if (!entry) throw new Error(`Unknown provider "${req.provider}"; use one of ${Object.keys(PROVIDERS).join(', ')}`);
  const ai = await load(req.packageDir, 'ai');
  const providerModule = await load(req.packageDir, entry[0]);
  const create = providerModule[entry[1]];
  if (typeof create !== 'function') throw new Error(`${entry[0]} has no ${entry[1]} export`);
  const options = {};
  if (req.apiKey) options.apiKey = req.apiKey;
  if (req.baseURL) options.baseURL = req.baseURL;
  const provider = create(options);
  const model = provider(req.model);

  const content = [{ type: 'text', text: req.prompt }];
  for (const url of req.images ?? []) content.push({ type: 'image', image: url });
  const common = { model, messages: [{ role: 'user', content }] };
  if (req.system) common.system = req.system;

  if (req.schema) {
    const schema = ai.jsonSchema(req.schema);
    if (typeof ai.generateObject === 'function') {
      const r = await ai.generateObject({ ...common, schema });
      return { ok: true, text: JSON.stringify(r.object), object: r.object, usage: r.usage ?? null };
    }
    const r = await ai.generateText({ ...common, output: ai.Output.object({ schema }) });
    return { ok: true, text: r.text, object: r.output ?? r.experimental_output, usage: r.usage ?? null };
  }
  const r = await ai.generateText(common);
  return { ok: true, text: r.text, usage: r.usage ?? null };
}

main().then(
  (out) => {
    process.stdout.write(JSON.stringify(out));
  },
  (err) => {
    process.stdout.write(JSON.stringify({ ok: false, error: String(err?.message ?? err) }));
    process.exitCode = 1;
  },
);
