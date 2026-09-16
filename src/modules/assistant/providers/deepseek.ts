import { ProviderError, type ProviderMessage, type ProviderRequest, type ProviderResponse, type ReasoningProvider } from '../provider.js';

export interface DeepSeekOptions {
  apiKey: string;
  /** deepseek-flash = DeepSeek-V4.1-Flash (api-docs.deepseek.com, 16/09/2026). */
  model?: string;
  baseUrl?: string;
  /** Thinking is the provider default; V1 disables it unless the evaluation set proves it better (ADR-005). */
  thinking?: boolean;
  maxOutputTokens?: number;
  fetch?: typeof fetch;
}

interface WireToolCall { id: string; type: 'function'; function: { name: string; arguments: string } }
interface WireMessage { role: string; content: string | null; tool_calls?: WireToolCall[]; tool_call_id?: string; reasoning_content?: string }

function toWire(message: ProviderMessage, thinking: boolean): WireMessage {
  switch (message.role) {
    case 'user':
      return { role: 'user', content: message.content };
    case 'tool':
      return { role: 'tool', tool_call_id: message.toolCallId, content: message.content };
    case 'assistant': {
      const wire: WireMessage = { role: 'assistant', content: message.content };
      if (message.toolCalls.length > 0) {
        wire.tool_calls = message.toolCalls.map((call) => ({ id: call.id, type: 'function', function: { name: call.name, arguments: call.arguments } }));
      }
      // With tools, thinking mode requires the reasoning of the current turn to be sent back; it is never stored.
      if (thinking && typeof message.providerState === 'string') wire.reasoning_content = message.providerState;
      return wire;
    }
  }
}

/** OpenAI-compatible Chat Completions adapter. Logs nothing: prompts and arguments are private. */
export class DeepSeekProvider implements ReasoningProvider {
  readonly name = 'deepseek';
  readonly model: string;
  private readonly baseUrl: string;
  private readonly thinking: boolean;
  private readonly maxOutputTokens: number;
  private readonly fetcher: typeof fetch;

  constructor(private readonly options: DeepSeekOptions) {
    if (!options.apiKey) throw new Error('DEEPSEEK_API_KEY is required for the DeepSeek provider.');
    this.model = options.model ?? 'deepseek-flash';
    this.baseUrl = (options.baseUrl ?? 'https://api.deepseek.com').replace(/\/+$/, '');
    this.thinking = options.thinking ?? false;
    this.maxOutputTokens = options.maxOutputTokens ?? 1024;
    this.fetcher = options.fetch ?? fetch;
  }

  async respond(request: ProviderRequest): Promise<ProviderResponse> {
    const body = {
      model: this.model,
      messages: [{ role: 'system', content: request.system }, ...request.messages.map((message) => toWire(message, this.thinking))],
      tools: request.tools.map((tool) => ({ type: 'function', function: { name: tool.name, description: tool.description, parameters: tool.parameters } })),
      tool_choice: 'auto',
      thinking: { type: this.thinking ? 'enabled' : 'disabled' },
      max_tokens: this.maxOutputTokens,
      stream: false,
      ...(this.thinking ? {} : { temperature: 0 }),
    };
    let response: Response;
    try {
      response = await this.fetcher(`${this.baseUrl}/chat/completions`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', authorization: `Bearer ${this.options.apiKey}` },
        body: JSON.stringify(body),
        signal: request.signal,
      });
    } catch (error) {
      if (request.signal.aborted || (error as { name?: string }).name === 'TimeoutError') throw new ProviderError('PROVIDER_TIMEOUT');
      throw new ProviderError('PROVIDER_UNAVAILABLE');
    }
    if (response.status === 429 || response.status >= 500) throw new ProviderError('PROVIDER_UNAVAILABLE', `HTTP ${response.status}`);
    if (!response.ok) throw new ProviderError('PROVIDER_REJECTED', `HTTP ${response.status}`);
    let payload: any;
    try { payload = await response.json(); } catch { throw new ProviderError('PROVIDER_INVALID_RESPONSE'); }
    const choice = payload?.choices?.[0];
    const message = choice?.message;
    if (!message || typeof message !== 'object') throw new ProviderError('PROVIDER_INVALID_RESPONSE');
    const toolCalls = Array.isArray(message.tool_calls) ? message.tool_calls : [];
    for (const call of toolCalls) {
      if (typeof call?.id !== 'string' || typeof call?.function?.name !== 'string' || typeof call?.function?.arguments !== 'string') {
        throw new ProviderError('PROVIDER_INVALID_RESPONSE');
      }
    }
    const finish = choice.finish_reason === 'stop' || choice.finish_reason === 'tool_calls' || choice.finish_reason === 'length'
      ? choice.finish_reason : 'other';
    return {
      text: typeof message.content === 'string' && message.content.length > 0 ? message.content : null,
      toolCalls: toolCalls.map((call: WireToolCall) => ({ id: call.id, name: call.function.name, arguments: call.function.arguments })),
      finish,
      usage: {
        inputTokens: Number.isSafeInteger(payload.usage?.prompt_tokens) ? payload.usage.prompt_tokens : 0,
        outputTokens: Number.isSafeInteger(payload.usage?.completion_tokens) ? payload.usage.completion_tokens : 0,
      },
      ...(typeof message.reasoning_content === 'string' ? { providerState: message.reasoning_content } : {}),
    };
  }
}
