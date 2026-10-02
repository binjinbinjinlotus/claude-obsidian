import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, describe, test } from 'node:test';
import { CoreError, type RunRequest, type Settings } from '../contracts.js';
import { WorkerProtocol } from '../engine/job-kinds.js';
import { defaultSettings } from '../store/settings.js';
import { createRunnerAdmin } from './admin.js';
import { AiSdkRunner, splitModel } from './ai-sdk.js';
import { codexArguments, CodexRunner, parseCodexEvents, writableRoots } from './codex.js';
import { canBeStrict, prepareSchema, stripOptionalNulls, strictify } from './model-api.js';
import { OpenAIRunner } from './openai.js';
import { OpenRouterRunner } from './openrouter.js';
import { isCancelled, runProcess, type RunProcessOptions } from './process.js';
import { createRunnerRegistry, defaultRunners } from './registry.js';
import { KeychainSecretStore, MemorySecretStore, parsePasswordLine, resolveSecret, secretIsSet, type SecurityOutput } from './secrets.js';

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'distill-runners-'));
after(() => fs.rmSync(tmp, { recursive: true, force: true }));

// 1x1 PNG
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
const pngPath = path.join(tmp, 'img.png');
fs.writeFileSync(pngPath, PNG);

function request(over: Partial<RunRequest> = {}): RunRequest {
  return {
    workingDirectory: '/v',
    prompt: 'PROMPT',
    session: { start: 'sid' },
    selection: { runnerID: 'x', model: 'm' },
    allowedTools: [],
    readableDirectories: [],
    ...over,
  };
}

interface Captured {
  url: string;
  init: RequestInit;
  body: Record<string, unknown>;
}

function fakeFetch(status: number, body: unknown, seen: Captured[] = []) {
  const impl = async (url: string, init?: RequestInit) => {
    seen.push({ url, init: init ?? {}, body: JSON.parse(String(init?.body)) as Record<string, unknown> });
    return new Response(typeof body === 'string' ? body : JSON.stringify(body), { status });
  };
  return { impl, seen };
}

const LABEL_SCHEMA = JSON.stringify({
  type: 'object',
  additionalProperties: false,
  properties: { labels: { type: 'array', items: { type: 'string' } }, note: { type: 'string' } },
  required: ['labels'],
});

async function storeWith(runnerID: string, key = 'sk-test'): Promise<MemorySecretStore> {
  const s = new MemorySecretStore();
  await s.set(runnerID, 'apiKey', key);
  return s;
}

describe('JSON schema strict mode', () => {
  test('strictify makes optional properties required + nullable, strip undoes it', () => {
    const original = JSON.parse(LABEL_SCHEMA);
    const strict = strictify(original) as Record<string, any>;
    assert.deepEqual(strict.required, ['labels', 'note']);
    assert.deepEqual(strict.properties.note.type, ['string', 'null']);
    assert.equal(strict.additionalProperties, false);
    assert.deepEqual(stripOptionalNulls({ labels: ['a'], note: null }, original), { labels: ['a'] });
  });

  test('WorkerProtocol schema is strict-compatible; free-form objects are not', () => {
    assert.equal(canBeStrict(JSON.parse(WorkerProtocol.schema)), true);
    const p = prepareSchema(WorkerProtocol.schema);
    assert.equal(p.strict, true);
    assert.ok(((p.wire as any).properties.questions.type as string[]).includes('null'));
    assert.equal(canBeStrict({ type: 'object' }), false);
    assert.equal(canBeStrict({ type: 'object', properties: {}, additionalProperties: true }), false);
  });

  test('enum gains null when optional', () => {
    const s = strictify({ type: 'object', properties: { k: { type: 'string', enum: ['a'] } } }) as any;
    assert.deepEqual(s.properties.k.enum, ['a', null]);
  });
});

describe('OpenAIRunner', () => {
  test('Responses request shape: instructions, image parts, json_schema, effort, auth, base URL', async () => {
    const { impl, seen } = fakeFetch(200, {
      status: 'completed',
      output: [
        { type: 'reasoning', summary: [] },
        { type: 'message', content: [{ type: 'output_text', text: '{"labels":["tea"],"note":null}' }] },
      ],
    });
    const runner = new OpenAIRunner(await storeWith('openai'), impl);
    const settings: Settings = { ...defaultSettings(), runnerOptions: { openai: { baseURL: 'https://proxy.example/v1/' } } };
    const result = await runner.run(
      request({ systemPrompt: 'SYS', images: [pngPath], outputSchema: LABEL_SCHEMA, selection: { runnerID: 'openai', model: 'gpt-5-mini', effort: 'low' } }),
      settings,
    );
    assert.equal(seen.length, 1);
    const { url, init, body } = seen[0]!;
    assert.equal(url, 'https://proxy.example/v1/responses');
    assert.equal((init.headers as Record<string, string>).authorization, 'Bearer sk-test');
    assert.equal(body.model, 'gpt-5-mini');
    assert.equal(body.instructions, 'SYS');
    assert.equal(body.store, false);
    assert.deepEqual(body.reasoning, { effort: 'low' });
    const content = (body.input as any)[0].content;
    assert.deepEqual(content[0], { type: 'input_text', text: 'PROMPT' });
    assert.equal(content[1].type, 'input_image');
    assert.equal(content[1].image_url, `data:image/png;base64,${PNG.toString('base64')}`);
    const format = (body.text as any).format;
    assert.equal(format.type, 'json_schema');
    assert.equal(format.strict, true);
    assert.deepEqual(format.schema.required, ['labels', 'note']);
    assert.deepEqual(result.structured, { labels: ['tea'] });
    assert.equal(result.isError, false);
    assert.equal(result.sessionID, 'sid');
  });

  test('no schema, no effort: plain text; default base URL', async () => {
    const { impl, seen } = fakeFetch(200, { output: [{ type: 'message', content: [{ type: 'output_text', text: 'hi' }] }] });
    const r = await new OpenAIRunner(await storeWith('openai'), impl).run(request(), defaultSettings());
    assert.equal(seen[0]!.url, 'https://api.openai.com/v1/responses');
    assert.equal('reasoning' in seen[0]!.body, false);
    assert.equal('text' in seen[0]!.body, false);
    assert.equal(r.resultText, 'hi');
    assert.equal(r.structured, undefined);
  });

  test('error mapping: 401 is apiError with hint and provider message; refusal and incomplete are isError', async () => {
    const { impl } = fakeFetch(401, { error: { message: 'Incorrect API key provided' } });
    await assert.rejects(new OpenAIRunner(await storeWith('openai'), impl).run(request(), defaultSettings()), (e: any) => {
      assert.equal(e.code, 'apiError');
      assert.match(e.message, /OpenAI 401: the API key was rejected: Incorrect API key provided/);
      assert.doesNotMatch(e.message, /sk-test/);
      return true;
    });
    const refusal = fakeFetch(200, { output: [{ type: 'message', content: [{ type: 'refusal', refusal: 'no' }] }] });
    const r1 = await new OpenAIRunner(await storeWith('openai'), refusal.impl).run(request(), defaultSettings());
    assert.deepEqual([r1.isError, r1.resultText], [true, 'no']);
    const inc = fakeFetch(200, { status: 'incomplete', incomplete_details: { reason: 'max_output_tokens' }, output: [] });
    const r2 = await new OpenAIRunner(await storeWith('openai'), inc.impl).run(request({ outputSchema: LABEL_SCHEMA }), defaultSettings());
    assert.equal(r2.isError, true);
    assert.match(r2.resultText, /max_output_tokens/);
  });

  test('non-JSON answer under a schema is malformedOutput', async () => {
    const { impl } = fakeFetch(200, { output: [{ type: 'message', content: [{ type: 'output_text', text: 'sorry' }] }] });
    await assert.rejects(new OpenAIRunner(await storeWith('openai'), impl).run(request({ outputSchema: LABEL_SCHEMA }), defaultSettings()), (e: any) => e.code === 'malformedOutput');
  });

  test('missing key: problems() and run()', async () => {
    const r = new OpenAIRunner(new MemorySecretStore(), fakeFetch(200, {}).impl);
    const saved = process.env.OPENAI_API_KEY;
    delete process.env.OPENAI_API_KEY;
    try {
      assert.deepEqual(r.problems(defaultSettings()).map((p) => p.code), ['missingSecret']);
      await assert.rejects(r.run(request(), defaultSettings()), (e: any) => e.code === 'missingSecret');
    } finally {
      if (saved !== undefined) process.env.OPENAI_API_KEY = saved;
    }
  });

  test('network failure is apiError; abort is cancelled', async () => {
    const r = new OpenAIRunner(await storeWith('openai'), async () => {
      throw new TypeError('fetch failed');
    });
    await assert.rejects(r.run(request(), defaultSettings()), (e: any) => e.code === 'apiError' && /could not reach api.openai.com/.test(e.message));
    const ac = new AbortController();
    ac.abort();
    await assert.rejects(r.run(request({ signal: ac.signal }), defaultSettings()), (e) => isCancelled(e));
  });

  test('unsupported image type is refused before any request', async () => {
    const bmp = path.join(tmp, 'x.bmp');
    fs.writeFileSync(bmp, 'x');
    const { impl, seen } = fakeFetch(200, {});
    await assert.rejects(new OpenAIRunner(await storeWith('openai'), impl).run(request({ images: [bmp] }), defaultSettings()), (e: any) => e.code === 'unsupported');
    assert.equal(seen.length, 0);
  });
});

describe('OpenRouterRunner', () => {
  test('chat completions shape, image_url parts, response_format, cost from usage', async () => {
    const { impl, seen } = fakeFetch(200, {
      choices: [{ message: { role: 'assistant', content: '```json\n{"labels":["x"]}\n```' }, finish_reason: 'stop' }],
      usage: { prompt_tokens: 10, completion_tokens: 3, cost: 0.00042 },
    });
    const r = await new OpenRouterRunner(await storeWith('openrouter', 'or-key'), impl).run(
      request({ systemPrompt: 'SYS', images: [pngPath], outputSchema: LABEL_SCHEMA, selection: { runnerID: 'openrouter', model: 'google/gemini-2.5-flash' } }),
      defaultSettings(),
    );
    const { url, init, body } = seen[0]!;
    assert.equal(url, 'https://openrouter.ai/api/v1/chat/completions');
    assert.equal((init.headers as Record<string, string>).authorization, 'Bearer or-key');
    const messages = body.messages as any[];
    assert.deepEqual(messages[0], { role: 'system', content: 'SYS' });
    assert.equal(messages[1].content[0].type, 'text');
    assert.deepEqual(messages[1].content[1], { type: 'image_url', image_url: { url: `data:image/png;base64,${PNG.toString('base64')}` } });
    assert.equal((body.response_format as any).type, 'json_schema');
    assert.equal((body.response_format as any).json_schema.strict, true);
    assert.deepEqual(r.structured, { labels: ['x'] });
    assert.equal(r.costUSD, 0.00042);
  });

  test('text-only prompt is a plain string; 429 maps to apiError', async () => {
    const ok = fakeFetch(200, { choices: [{ message: { content: 'hi' } }] });
    await new OpenRouterRunner(await storeWith('openrouter'), ok.impl).run(request(), defaultSettings());
    assert.deepEqual(ok.seen[0]!.body.messages, [{ role: 'user', content: 'PROMPT' }]);
    assert.deepEqual(ok.seen[0]!.body.usage, { include: true });
    const limited = fakeFetch(429, { error: { message: 'Rate limit exceeded', code: 429 } });
    await assert.rejects(new OpenRouterRunner(await storeWith('openrouter'), limited.impl).run(request(), defaultSettings()), /OpenRouter 429: rate limited/);
  });

  test('env fallback supplies the key', async () => {
    const { impl, seen } = fakeFetch(200, { choices: [{ message: { content: 'hi' } }] });
    const saved = process.env.OPENROUTER_API_KEY;
    process.env.OPENROUTER_API_KEY = 'env-key';
    try {
      const r = new OpenRouterRunner(new MemorySecretStore(), impl);
      assert.deepEqual(r.problems(defaultSettings()), []);
      await r.run(request(), defaultSettings());
      assert.equal((seen[0]!.init.headers as Record<string, string>).authorization, 'Bearer env-key');
    } finally {
      if (saved === undefined) delete process.env.OPENROUTER_API_KEY;
      else process.env.OPENROUTER_API_KEY = saved;
    }
  });
});

describe('CodexRunner', () => {
  const vault = path.join(tmp, 'v');
  const job = `${vault}/.vault-meta/worker/job-1`;
  const codexSettings: Settings = { ...defaultSettings(), runnerOptions: { codex: { path: '/bin/sh' } } };

  test('writable roots come only from directory-wide Edit rules', () => {
    const r = request({
      allowedTools: ['Read', `Edit(/${job}/**)`, `Edit(/${vault}/wiki/a.md)`, 'Bash(ls:*)', `Edit(/${vault}/other/**)`, `Edit(/${job}/**)`],
    });
    assert.deepEqual(writableRoots(r), [job, `${vault}/other`]);
  });

  test('first turn argv: exec, sandbox confined to the job dir, cwd = job dir, schema file, images, prompt on stdin', async () => {
    let seen: RunProcessOptions | undefined;
    let schemaOnDisk: unknown;
    const runner = new CodexRunner(async (opts) => {
      seen = opts;
      const i = opts.args.indexOf('--output-schema');
      schemaOnDisk = JSON.parse(fs.readFileSync(opts.args[i + 1]!, 'utf8'));
      const out = [
        { type: 'thread.started', thread_id: 'thread-1' },
        { type: 'turn.started' },
        { type: 'item.completed', item: { id: 'i0', type: 'agent_message', text: 'thinking' } },
        { type: 'item.completed', item: { id: 'i1', type: 'agent_message', text: '{"status":"needs_approval","summary":"s","bundle_path":"/b","questions":null,"operation_id":null,"changed_paths":null,"skipped":null}' } },
        { type: 'turn.completed', usage: { input_tokens: 1, output_tokens: 1 } },
      ].map((e) => JSON.stringify(e)).join('\n');
      return { status: 0, stdout: Buffer.from(out), stderr: Buffer.alloc(0) };
    });
    const result = await runner.run(
      request({
        workingDirectory: vault,
        allowedTools: ['Read', `Edit(/${job}/**)`, 'Bash(python3 /p/x.py transaction inspect:*)'],
        outputSchema: WorkerProtocol.schema,
        systemPrompt: 'SYS',
        images: ['/img/a.png'],
        environment: { CLAUDE_OBSIDIAN_VAULT: vault },
        selection: { runnerID: 'codex', model: 'gpt-5.5', effort: 'high' },
      }),
      { ...codexSettings, runnerOptions: { codex: { path: process.execPath } } },
    );
    assert.ok(seen);
    assert.equal(seen.executable, process.execPath);
    assert.equal(seen.cwd, job);
    assert.equal(seen.stdin, '<instructions>\nSYS\n</instructions>\n\nPROMPT');
    assert.deepEqual(seen.environment, { CLAUDE_OBSIDIAN_VAULT: vault });
    const schemaFile = seen.args[seen.args.indexOf('--output-schema') + 1]!;
    assert.deepEqual(seen.args, [
      'exec', '--json', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules',
      '-C', job, '--sandbox', 'workspace-write', '-m', 'gpt-5.5',
      '-c', 'sandbox_mode="workspace-write"', '-c', 'approval_policy="never"',
      '-c', `sandbox_workspace_write.writable_roots=["${job}"]`,
      '-c', 'sandbox_workspace_write.network_access=false',
      '-c', 'sandbox_workspace_write.exclude_slash_tmp=true',
      '-c', 'sandbox_workspace_write.exclude_tmpdir_env_var=true',
      '-c', 'model_reasoning_effort="high"',
      '--output-schema', schemaFile, '--image', '/img/a.png', '--', '-',
    ]);
    assert.equal(fs.existsSync(schemaFile), false, 'temp schema file is removed');
    assert.deepEqual((schemaOnDisk as any).required.sort(), ['bundle_path', 'changed_paths', 'operation_id', 'questions', 'skipped', 'status', 'summary']);
    assert.equal(result.sessionID, 'thread-1');
    assert.equal(result.isError, false);
    assert.deepEqual(result.structured, { status: 'needs_approval', summary: 's', bundle_path: '/b' });
    assert.deepEqual(result.denials, []);
  });

  test('resume argv: options after `resume`, sandbox via -c only, session id positional, no system prompt', () => {
    const inv = new CodexRunner().invocation(
      request({ workingDirectory: vault, session: { resume: 'thread-1' }, allowedTools: [`Edit(/${job}/**)`], selection: { runnerID: 'codex', model: 'gpt-5.5' } }),
      codexSettings,
    );
    assert.equal(inv.cwd, job);
    const args = codexArguments(inv);
    assert.deepEqual(args.slice(0, 6), ['exec', 'resume', '--json', '--skip-git-repo-check', '--ignore-user-config', '--ignore-rules']);
    assert.equal(args.includes('-C'), false);
    assert.equal(args.includes('--sandbox'), false);
    assert.ok(args.includes('sandbox_mode="workspace-write"'));
    assert.deepEqual(args.slice(-3), ['--', 'thread-1', '-']);
    assert.equal(CodexRunner.prompt(request({ session: { resume: 'x' }, systemPrompt: 'SYS' })), 'PROMPT');
  });

  test('no writable rule → read-only sandbox, cwd = working directory, never workspace-write', () => {
    const inv = new CodexRunner().invocation(request({ workingDirectory: vault, allowedTools: ['Read', `Edit(/${vault}/wiki/a.md)`] }), codexSettings);
    assert.equal(inv.sandbox, 'read-only');
    const args = codexArguments(inv);
    assert.ok(args.includes('sandbox_mode="read-only"'));
    assert.equal(args.some((a) => a.startsWith('sandbox_workspace_write')), false);
  });

  test('job dir is preferred as workspace even when another root comes first', () => {
    const inv = new CodexRunner().invocation(request({ workingDirectory: vault, allowedTools: [`Edit(/${vault}/other/**)`, `Edit(/${job}/**)`] }), codexSettings);
    assert.equal(inv.cwd, job);
    assert.deepEqual(inv.writableRoots, [`${vault}/other`, job]);
  });

  test('event parsing: failures and errors', () => {
    const ev = parseCodexEvents(
      [
        '{"type":"thread.started","thread_id":"t"}',
        'not json',
        '{"type":"turn.started"}',
        '{"type":"error","message":"Your access token could not be refreshed."}',
        '{"type":"turn.failed","error":{"message":"Your access token could not be refreshed."}}',
      ].join('\n'),
    );
    assert.deepEqual(ev, { threadID: 't', error: 'Your access token could not be refreshed.', turnCompleted: false });
  });

  test('failed turn returns isError with the message; no output and non-zero exit throws', async () => {
    const failing = new CodexRunner(async () => ({
      status: 1,
      stdout: Buffer.from('{"type":"thread.started","thread_id":"t"}\n{"type":"turn.failed","error":{"message":"boom"}}\n'),
      stderr: Buffer.alloc(0),
    }));
    const r = await failing.run(request(), codexSettings);
    assert.deepEqual([r.isError, r.resultText, r.sessionID], [true, 'boom', 't']);
    const dead = new CodexRunner(async () => ({ status: 2, stdout: Buffer.alloc(0), stderr: Buffer.from('error: unexpected argument') }));
    await assert.rejects(dead.run(request(), codexSettings), /Exited 2: error: unexpected argument/);
  });

  test('problems and resumeCommand', () => {
    const r = new CodexRunner();
    assert.deepEqual(r.problems({ ...defaultSettings(), runnerOptions: { codex: { path: '/nope/codex' } } }).map((p) => p.code), ['missingCodex']);
    assert.deepEqual(r.problems(codexSettings), []);
    assert.deepEqual(r.resumeCommand('t', 'gpt-5.5', codexSettings), ['/bin/sh', 'resume', 't', '-m', 'gpt-5.5']);
  });
});

describe('AiSdkRunner + bridge', () => {
  // A stub package folder with fake `ai` and `@ai-sdk/openai` modules: runs the real bridge, no network.
  const pkgDir = path.join(tmp, 'aisdk');
  const mod = (name: string, src: string) => {
    const dir = path.join(pkgDir, 'node_modules', ...name.split('/'));
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'package.json'), JSON.stringify({ name, version: '0.0.0', main: 'index.js' }));
    fs.writeFileSync(path.join(dir, 'index.js'), src);
  };
  fs.mkdirSync(pkgDir, { recursive: true });
  fs.writeFileSync(path.join(pkgDir, 'package.json'), '{"name":"aisdk-stub","private":true}');
  mod(
    'ai',
    `exports.jsonSchema = (s) => ({ __schema: s });
     exports.generateObject = async (o) => ({ object: { echo: o.messages[0].content, system: o.system ?? null, model: o.model, schema: o.schema }, usage: { totalTokens: 3 } });
     exports.generateText = async (o) => ({ text: 'text:' + o.messages[0].content[0].text });`,
  );
  mod('@ai-sdk/openai', `exports.createOpenAI = (opts) => (id) => ({ id, apiKey: opts.apiKey ?? null, baseURL: opts.baseURL ?? null });`);
  const settings: Settings = { ...defaultSettings(), nodePath: process.execPath, runnerOptions: { 'ai-sdk': { packageDir: pkgDir, provider: 'openai' } } };

  test('structured call through the real bridge: key and images on stdin, provider:model split', async () => {
    const secrets = await storeWith('ai-sdk', 'k1');
    let seen: RunProcessOptions | undefined;
    const runner = new AiSdkRunner(secrets, (opts) => {
      seen = opts;
      return runProcess(opts);
    });
    const r = await runner.run(
      request({ outputSchema: LABEL_SCHEMA, systemPrompt: 'SYS', images: [pngPath], selection: { runnerID: 'ai-sdk', model: 'openai:gpt-5-mini' } }),
      settings,
    );
    assert.ok(seen);
    assert.equal(seen.cwd, pkgDir);
    assert.equal(seen.args.length, 1);
    assert.equal(seen.args.some((a) => a.includes('k1')), false, 'key never on argv');
    const obj = r.structured as any;
    assert.equal(obj.model.id, 'gpt-5-mini');
    assert.equal(obj.model.apiKey, 'k1');
    assert.equal(obj.system, 'SYS');
    assert.deepEqual(obj.echo[1], { type: 'image', image: `data:image/png;base64,${PNG.toString('base64')}` });
    assert.deepEqual(obj.schema.__schema, JSON.parse(LABEL_SCHEMA));
  });

  test('text call and bridge errors', async () => {
    const runner = new AiSdkRunner(new MemorySecretStore());
    const r = await runner.run(request({ selection: { runnerID: 'ai-sdk', model: 'gpt-5-mini' } }), settings);
    assert.equal(r.resultText, 'text:PROMPT');
    await assert.rejects(
      runner.run(request({ selection: { runnerID: 'ai-sdk', model: 'anthropic:claude-haiku-4-5' } }), settings),
      /@ai-sdk\/anthropic is not installed/,
    );
  });

  test('problems report setup gaps clearly', () => {
    const r = new AiSdkRunner(new MemorySecretStore());
    assert.deepEqual(r.problems(settings), []);
    assert.deepEqual(r.problems({ ...settings, runnerOptions: {} }).map((p) => p.code), ['aiSdkNotConfigured']);
    const empty = path.join(tmp, 'empty');
    fs.mkdirSync(empty, { recursive: true });
    assert.deepEqual(r.problems({ ...settings, runnerOptions: { 'ai-sdk': { packageDir: empty, provider: 'google' } } }).map((p) => p.code), ['missingAiSdk', 'missingAiSdkProvider']);
    assert.deepEqual(r.problems({ ...settings, nodePath: '/nope/node' }).map((p) => p.code), ['missingNode']);
  });

  test('splitModel', () => {
    assert.deepEqual(splitModel('google:gemini-2.5-flash', settings), { provider: 'google', model: 'gemini-2.5-flash' });
    assert.deepEqual(splitModel('gpt-5-mini', settings), { provider: 'openai', model: 'gpt-5-mini' });
    assert.deepEqual(splitModel('foo:bar', settings), { provider: 'openai', model: 'foo:bar' });
  });
});

describe('secrets', () => {
  test('Keychain store: value goes over stdin as hex, never argv; read, missing, delete', async () => {
    const calls: { args: string[]; stdin?: string }[] = [];
    const items = new Map<string, string>();
    const fake = (args: string[], stdin?: string): SecurityOutput => {
      calls.push({ args, ...(stdin !== undefined ? { stdin } : {}) });
      if (args[0] === '-i') {
        const m = /-a (\S+) -X ([0-9a-f]+)/.exec(stdin ?? '')!;
        items.set(m[1]!, Buffer.from(m[2]!, 'hex').toString('utf8'));
        return { status: 0, stdout: '', stderr: '' };
      }
      const acct = args[args.indexOf('-a') + 1]!;
      if (args[0] === 'delete-generic-password') return items.delete(acct) ? { status: 0, stdout: '', stderr: '' } : { status: 44, stdout: '', stderr: 'not found' };
      const v = items.get(acct);
      if (v === undefined) return { status: 44, stdout: '', stderr: 'not found' };
      if (!args.includes('-g')) return { status: 0, stdout: 'attributes', stderr: '' };
      return { status: 0, stdout: 'attributes', stderr: `password: 0x${Buffer.from(v).toString('hex').toUpperCase()}  "escaped"\n` };
    };
    const store = new KeychainSecretStore(fake, 'svc.test', 0);
    assert.equal(await store.get('openai', 'apiKey'), undefined);
    await store.set('openai', 'apiKey', 'sk-ünïcode "quoted"');
    const write = calls.find((c) => c.args[0] === '-i')!;
    assert.deepEqual(write.args, ['-i']);
    assert.equal(write.stdin, `add-generic-password -U -s svc.test -a openai.apiKey -X ${Buffer.from('sk-ünïcode "quoted"').toString('hex')}\n`);
    assert.ok(calls.every((c) => !c.args.join(' ').includes('sk-')));
    assert.equal(await store.get('openai', 'apiKey'), 'sk-ünïcode "quoted"');
    assert.equal(store.hasSync('openai', 'apiKey'), true);
    await store.set('openai', 'apiKey', null);
    assert.equal(store.hasSync('openai', 'apiKey'), false);
    await store.set('openai', 'apiKey', null); // deleting a missing item is fine
    await assert.rejects(store.set('bad id', 'apiKey', 'x'), /Invalid secret address/);
  });

  test('parsePasswordLine: hex form, plain form, empty', () => {
    assert.equal(parsePasswordLine('keychain: "x"\npassword: 0x7468726F77617761792DC3BC20227122  "throwaway-\\303\\274 "q""\n'), 'throwaway-ü "q"');
    assert.equal(parsePasswordLine('password: "sk-abc123"\n'), 'sk-abc123');
    assert.equal(parsePasswordLine('password: \n'), '');
    assert.equal(parsePasswordLine('nothing'), undefined);
  });

  test('Keychain write failure reported via stderr', async () => {
    const store = new KeychainSecretStore(() => ({ status: 0, stdout: '', stderr: 'security: SecKeychainItemCreateFromContent: denied' }), 'svc', 0);
    await assert.rejects(store.set('openai', 'apiKey', 'x'), /Keychain write failed/);
  });

  test('resolveSecret / secretIsSet: store first, then env', async () => {
    const store = new MemorySecretStore();
    assert.equal(await resolveSecret(store, 'openai', 'apiKey', { OPENAI_API_KEY: 'e' }), 'e');
    await store.set('openai', 'apiKey', 's');
    assert.equal(await resolveSecret(store, 'openai', 'apiKey', { OPENAI_API_KEY: 'e' }), 's');
    assert.equal(secretIsSet(new MemorySecretStore(), 'openrouter', 'apiKey', { OPENROUTER_API_KEY: 'x' }), true);
    assert.equal(secretIsSet(new MemorySecretStore(), 'ai-sdk', 'apiKey', {}), false);
  });
});

describe('runner admin', () => {
  const secrets = new MemorySecretStore();
  const registry = createRunnerRegistry(defaultRunners({ secrets }));
  const settings: Settings = { ...defaultSettings(), enabledRunners: ['claude-code', 'openrouter'] };
  const admin = createRunnerAdmin({ runners: registry, getSettings: () => settings, secrets, env: {} });

  test('listRunners: every runner, Claude Code first, tasks per capabilities, enabled flags, secrets', async () => {
    const list = await admin.listRunners();
    assert.deepEqual(list.map((r) => r.id), ['claude-code', 'codex', 'openai', 'openrouter', 'ai-sdk']);
    const by = Object.fromEntries(list.map((r) => [r.id, r]));
    assert.deepEqual(by['claude-code']!.tasks, ['ingest', 'ask', 'labelSuggest', 'imageText']);
    assert.deepEqual(by['codex']!.tasks, ['ingest', 'labelSuggest']);
    assert.deepEqual(by['openai']!.tasks, ['labelSuggest', 'imageText']);
    assert.deepEqual(by['openrouter']!.tasks, ['labelSuggest', 'imageText']);
    assert.deepEqual(by['ai-sdk']!.tasks, ['labelSuggest']);
    assert.deepEqual(list.map((r) => r.kind), ['agent', 'agent', 'modelAPI', 'modelAPI', 'modelAPI']);
    assert.deepEqual(list.filter((r) => r.enabled).map((r) => r.id), ['claude-code', 'openrouter']);
    assert.deepEqual(by['claude-code']!.secrets, []);
    assert.deepEqual(by['openrouter']!.secrets, [{ name: 'apiKey', label: 'API key', isSet: false }]);
    assert.ok(by['codex']!.capabilities.includes('sandboxedWrites'));
    assert.equal(by['codex']!.capabilities.includes('toolPermissions'), false);
  });

  test('setRunnerSecret stores, clears and validates', async () => {
    await admin.setRunnerSecret('openrouter', 'apiKey', '  or-key  ');
    assert.equal(await secrets.get('openrouter', 'apiKey'), 'or-key');
    const info = (await admin.listRunners()).find((r) => r.id === 'openrouter')!;
    assert.equal(info.secrets[0]!.isSet, true);
    assert.equal(info.problems.length, 0);
    await admin.setRunnerSecret('openrouter', 'apiKey', null);
    assert.equal(await secrets.get('openrouter', 'apiKey'), undefined);
    await assert.rejects(admin.setRunnerSecret('nope', 'apiKey', 'x'), (e) => e instanceof CoreError && e.code === 'not_found');
    await assert.rejects(admin.setRunnerSecret('claude-code', 'apiKey', 'x'), (e) => e instanceof CoreError && e.code === 'invalid_request');
    await assert.rejects(admin.setRunnerSecret('openai', 'apiKey', ' '), (e) => e instanceof CoreError && e.code === 'invalid_request');
  });

  test('candidates: disabled runners are never offered; Codex is never offered for Ask', () => {
    assert.deepEqual(registry.candidates('labelSuggest', settings).map((r) => r.id), ['claude-code', 'openrouter']);
    const all = { ...settings, enabledRunners: ['claude-code', 'codex', 'openai', 'openrouter', 'ai-sdk'] };
    assert.deepEqual(registry.candidates('ask', all).map((r) => r.id), ['claude-code']);
    assert.deepEqual(registry.candidates('ingest', all).map((r) => r.id), ['claude-code', 'codex']);
    assert.deepEqual(registry.candidates('imageText', all).map((r) => r.id), ['claude-code', 'openai', 'openrouter']);
  });
});
