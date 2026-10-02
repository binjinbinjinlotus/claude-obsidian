import type { AgentRunner, ModelOption, RunRequest, RunResult, RunnerCapability, Settings, SetupProblem } from '../contracts.js';
import {
  joinURL,
  loadImages,
  parseStructured,
  postJSON,
  prepareSchema,
  runnerOption,
  sessionIDOf,
  type FetchLike,
  type PreparedSchema,
} from './model-api.js';
import { RunnerError } from './process.js';
import { defaultSecretStore, resolveSecret, secretIsSet, type SecretStore } from './secrets.js';

export const OPENROUTER_ID = 'openrouter';
export const OPENROUTER_DEFAULT_BASE_URL = 'https://openrouter.ai/api/v1';

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** OpenAI-compatible chat completions body (works for any OpenAI-compatible base URL). */
export function chatCompletionsBody(request: RunRequest, schema: PreparedSchema | undefined): Record<string, unknown> {
  const messages: Record<string, unknown>[] = [];
  if (request.systemPrompt) messages.push({ role: 'system', content: request.systemPrompt });
  const images = loadImages(request);
  if (images.length === 0) {
    messages.push({ role: 'user', content: request.prompt });
  } else {
    messages.push({
      role: 'user',
      content: [{ type: 'text', text: request.prompt }, ...images.map((img) => ({ type: 'image_url', image_url: { url: img.dataURL } }))],
    });
  }
  const body: Record<string, unknown> = { model: request.selection.model, messages };
  if (schema) body.response_format = { type: 'json_schema', json_schema: { name: 'output', strict: schema.strict, schema: schema.wire } };
  return body;
}

export function parseChatCompletion(json: Record<string, unknown>): { text: string; refusal?: string; finishReason?: string; costUSD: number } {
  const choice = Array.isArray(json.choices) && isObj(json.choices[0]) ? json.choices[0] : undefined;
  const message = choice && isObj(choice.message) ? choice.message : undefined;
  let text = '';
  if (message && typeof message.content === 'string') text = message.content;
  else if (message && Array.isArray(message.content)) {
    text = message.content.map((p) => (isObj(p) && typeof p.text === 'string' ? p.text : '')).join('');
  }
  const out: { text: string; refusal?: string; finishReason?: string; costUSD: number } = { text, costUSD: 0 };
  if (message && typeof message.refusal === 'string' && message.refusal.length > 0) out.refusal = message.refusal;
  if (choice && typeof choice.finish_reason === 'string') out.finishReason = choice.finish_reason;
  // OpenRouter reports the charge in usage.cost (USD credits).
  if (isObj(json.usage) && typeof json.usage.cost === 'number') out.costUSD = json.usage.cost;
  return out;
}

/**
 * OpenRouter (OpenAI-compatible chat completions). A plain model call for
 * labelSuggest and imageText. Whether a model honors JSON-schema output or
 * images depends on the model; pick one that lists both.
 */
export class OpenRouterRunner implements AgentRunner {
  readonly id = OPENROUTER_ID;
  readonly displayName = 'OpenRouter';
  readonly kind = 'modelAPI' as const;
  readonly secrets = [{ name: 'apiKey', label: 'API key' }];
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['structuredOutput', 'vision']);
  readonly models: ModelOption[] = [
    { id: 'google/gemini-2.5-flash', label: 'Gemini 2.5 Flash', note: 'Cheap, fast, images' },
    { id: 'openai/gpt-5-mini', label: 'GPT-5 mini' },
    { id: 'anthropic/claude-haiku-4.5', label: 'Claude Haiku 4.5' },
    { id: 'anthropic/claude-sonnet-4.5', label: 'Claude Sonnet 4.5', note: 'Any OpenRouter model id works.' },
  ];
  readonly effortLevels: string[] = [];
  readonly defaultModel = 'google/gemini-2.5-flash';

  constructor(
    private readonly secretStore: SecretStore = defaultSecretStore(),
    private readonly fetchImpl: FetchLike = (url, init) => fetch(url, init),
  ) {}

  problems(_settings: Settings): SetupProblem[] {
    return secretIsSet(this.secretStore, this.id, 'apiKey')
      ? []
      : [{ code: 'missingSecret', message: 'OpenRouter API key not set (Settings → AI runners, or OPENROUTER_API_KEY).' }];
  }

  async run(request: RunRequest, settings: Settings): Promise<RunResult> {
    const key = await resolveSecret(this.secretStore, this.id, 'apiKey');
    if (!key) throw new RunnerError('OpenRouter API key not set.', 'missingSecret');
    const schema = request.outputSchema !== undefined ? prepareSchema(request.outputSchema) : undefined;
    const base = runnerOption(settings, this.id, 'baseURL') ?? OPENROUTER_DEFAULT_BASE_URL;
    const { json, raw } = await postJSON(
      this.fetchImpl,
      joinURL(base, 'chat/completions'),
      { authorization: `Bearer ${key}`, 'x-title': 'Distill' },
      chatCompletionsBody(request, schema),
      'OpenRouter',
      request.signal,
    );
    const parsed = parseChatCompletion(json);
    const result: RunResult = { sessionID: sessionIDOf(request), resultText: parsed.text, isError: false, costUSD: parsed.costUSD, denials: [], raw };
    if (parsed.refusal !== undefined) return { ...result, resultText: parsed.refusal, isError: true };
    if (parsed.finishReason === 'length') return { ...result, isError: true, resultText: `Response cut off (length). ${parsed.text}`.trim() };
    if (schema) result.structured = parseStructured(parsed.text, schema);
    return result;
  }
}
