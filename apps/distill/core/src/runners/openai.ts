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

export const OPENAI_ID = 'openai';
export const OPENAI_DEFAULT_BASE_URL = 'https://api.openai.com/v1';

function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** The Responses API request body for one stateless turn. */
export function openAIRequestBody(request: RunRequest, schema: PreparedSchema | undefined): Record<string, unknown> {
  const content: Record<string, unknown>[] = [{ type: 'input_text', text: request.prompt }];
  for (const img of loadImages(request)) content.push({ type: 'input_image', image_url: img.dataURL });
  const body: Record<string, unknown> = {
    model: request.selection.model,
    input: [{ role: 'user', content }],
    store: false,
  };
  if (request.systemPrompt) body.instructions = request.systemPrompt;
  if (request.selection.effort) body.reasoning = { effort: request.selection.effort };
  if (schema) body.text = { format: { type: 'json_schema', name: 'output', schema: schema.wire, strict: schema.strict } };
  return body;
}

/** Concatenate `output_text` parts of `message` items; a refusal is an error. */
export function parseOpenAIResponse(json: Record<string, unknown>): { text: string; refusal?: string; incomplete?: string } {
  let text = '';
  let refusal: string | undefined;
  for (const item of Array.isArray(json.output) ? json.output : []) {
    if (!isObj(item) || item.type !== 'message' || !Array.isArray(item.content)) continue;
    for (const part of item.content) {
      if (!isObj(part)) continue;
      if (part.type === 'output_text' && typeof part.text === 'string') text += part.text;
      if (part.type === 'refusal' && typeof part.refusal === 'string') refusal = part.refusal;
    }
  }
  const out: { text: string; refusal?: string; incomplete?: string } = { text };
  if (refusal !== undefined) out.refusal = refusal;
  if (json.status === 'incomplete') {
    const reason = isObj(json.incomplete_details) && typeof json.incomplete_details.reason === 'string' ? json.incomplete_details.reason : 'unknown';
    out.incomplete = reason;
  }
  return out;
}

/**
 * OpenAI API (Responses endpoint). A plain model call: no tools, no files, no
 * sessions. Serves labelSuggest (JSON-schema output) and imageText (images).
 */
export class OpenAIRunner implements AgentRunner {
  readonly id = OPENAI_ID;
  readonly displayName = 'OpenAI API';
  readonly kind = 'modelAPI' as const;
  readonly secrets = [{ name: 'apiKey', label: 'API key' }];
  readonly capabilities: ReadonlySet<RunnerCapability> = new Set<RunnerCapability>(['structuredOutput', 'vision', 'effort']);
  readonly models: ModelOption[] = [
    { id: 'gpt-5-mini', label: 'GPT-5 mini', note: 'Cheap and fast; good for labels' },
    { id: 'gpt-5-nano', label: 'GPT-5 nano', note: 'Cheapest' },
    { id: 'gpt-5', label: 'GPT-5' },
    { id: 'gpt-5.5', label: 'GPT-5.5' },
    { id: 'gpt-4.1-mini', label: 'GPT-4.1 mini', note: 'Not a reasoning model: leave effort unset. Any model id works.' },
  ];
  /** Sent as `reasoning.effort`; reasoning models only. */
  readonly effortLevels = ['minimal', 'low', 'medium', 'high'];
  readonly defaultModel = 'gpt-5-mini';

  constructor(
    private readonly secretStore: SecretStore = defaultSecretStore(),
    private readonly fetchImpl: FetchLike = (url, init) => fetch(url, init),
  ) {}

  problems(_settings: Settings): SetupProblem[] {
    return secretIsSet(this.secretStore, this.id, 'apiKey')
      ? []
      : [{ code: 'missingSecret', message: 'OpenAI API key not set (Settings → AI runners, or OPENAI_API_KEY).' }];
  }

  async run(request: RunRequest, settings: Settings): Promise<RunResult> {
    const key = await resolveSecret(this.secretStore, this.id, 'apiKey');
    if (!key) throw new RunnerError('OpenAI API key not set.', 'missingSecret');
    const schema = request.outputSchema !== undefined ? prepareSchema(request.outputSchema) : undefined;
    const base = runnerOption(settings, this.id, 'baseURL') ?? OPENAI_DEFAULT_BASE_URL;
    const { json, raw } = await postJSON(
      this.fetchImpl,
      joinURL(base, 'responses'),
      { authorization: `Bearer ${key}` },
      openAIRequestBody(request, schema),
      'OpenAI',
      request.signal,
    );
    const parsed = parseOpenAIResponse(json);
    const result: RunResult = { sessionID: sessionIDOf(request), resultText: parsed.text, isError: false, costUSD: 0, denials: [], raw };
    if (parsed.refusal !== undefined) return { ...result, resultText: parsed.refusal, isError: true };
    if (parsed.incomplete !== undefined) return { ...result, isError: true, resultText: `Incomplete response (${parsed.incomplete}). ${parsed.text}`.trim() };
    if (schema) result.structured = parseStructured(parsed.text, schema);
    return result;
  }
}
