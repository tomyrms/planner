/** Thin provider boundary (04_AI_Orchestration.md §2). The server validates everything a provider returns. */

export interface ToolSpec {
  name: string;
  description: string;
  /** JSON Schema projection of the tool's Zod schema. */
  parameters: Record<string, unknown>;
}

export interface ToolCall {
  id: string;
  name: string;
  /** Raw JSON text as produced by the model; parsed and validated by the server. */
  arguments: string;
}

export type ProviderMessage =
  | { role: 'user'; content: string }
  /** providerState carries protocol content (e.g. reasoning) for the current turn only; never persisted. */
  | { role: 'assistant'; content: string | null; toolCalls: ToolCall[]; providerState?: unknown }
  | { role: 'tool'; toolCallId: string; content: string };

export interface ProviderRequest {
  system: string;
  messages: readonly ProviderMessage[];
  tools: readonly ToolSpec[];
  signal: AbortSignal;
}

export interface ProviderResponse {
  text: string | null;
  toolCalls: ToolCall[];
  /** Anything but "stop" or "tool_calls" means a partial output: no effect is ever derived from it. */
  finish: 'stop' | 'tool_calls' | 'length' | 'other';
  usage: { inputTokens: number; outputTokens: number };
  providerState?: unknown;
}

export interface ReasoningProvider {
  readonly name: string;
  readonly model: string;
  respond(request: ProviderRequest): Promise<ProviderResponse>;
}

export type ProviderErrorCode = 'PROVIDER_TIMEOUT' | 'PROVIDER_UNAVAILABLE' | 'PROVIDER_REJECTED' | 'PROVIDER_INVALID_RESPONSE';

export class ProviderError extends Error {
  constructor(public readonly code: ProviderErrorCode, message: string = code) {
    super(message);
  }
}
