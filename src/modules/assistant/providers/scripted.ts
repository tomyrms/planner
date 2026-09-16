import { ProviderError, type ProviderRequest, type ProviderResponse, type ReasoningProvider, type ToolCall } from '../provider.js';

export type ScriptStep = ProviderResponse | ProviderError | ((request: ProviderRequest) => ProviderResponse | Promise<ProviderResponse>);

let callCounter = 0;

/** Tool calls in the provider's shape; arguments are serialized like a model would. */
export function toolCall(name: string, args: unknown, id = `call_${++callCounter}`): ToolCall {
  return { id, name, arguments: typeof args === 'string' ? args : JSON.stringify(args) };
}

export function callTools(...calls: ToolCall[]): ProviderResponse {
  return { text: null, toolCalls: calls, finish: 'tool_calls', usage: { inputTokens: 100, outputTokens: 20 } };
}

export function reply(text: string): ProviderResponse {
  return { text, toolCalls: [], finish: 'stop', usage: { inputTokens: 100, outputTokens: 10 } };
}

/** Deterministic provider for tests: plays the given steps in order, then answers with an empty text. */
export class ScriptedProvider implements ReasoningProvider {
  readonly name = 'scripted';
  readonly model = 'scripted-v1';
  readonly requests: ProviderRequest[] = [];
  private index = 0;

  constructor(private readonly steps: readonly ScriptStep[]) {}

  async respond(request: ProviderRequest): Promise<ProviderResponse> {
    this.requests.push({ ...request, messages: [...request.messages] });
    if (request.signal.aborted) throw new ProviderError('PROVIDER_TIMEOUT');
    const step = this.steps[this.index++];
    if (step === undefined) return reply('');
    if (step instanceof ProviderError) throw step;
    return typeof step === 'function' ? step(request) : step;
  }
}
