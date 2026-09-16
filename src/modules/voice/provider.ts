import { openAsBlob } from 'node:fs';

/** Speech-to-text boundary (ADR-006). The server stores only the text; the audio file is deleted afterwards. */
export interface TranscriptionRequest {
  audioPath: string;
  /** ISO 639-1 language hints (fr, pt, en). */
  languages: readonly string[];
  /** Short list of names the user uses (lists, C#…); hints never guarantee a word. */
  keywords: readonly string[];
  signal: AbortSignal;
}

export interface TranscriptionResult {
  text: string;
  languages: string[];
  /** Billed seconds when the provider reports them. */
  seconds: number | null;
}

export interface TranscriptionProvider {
  readonly name: string;
  readonly model: string;
  transcribe(request: TranscriptionRequest): Promise<TranscriptionResult>;
}

export type TranscriptionErrorCode = 'TRANSCRIPTION_TIMEOUT' | 'TRANSCRIPTION_UNAVAILABLE' | 'TRANSCRIPTION_REJECTED' | 'TRANSCRIPTION_INVALID_RESPONSE';

export class TranscriptionError extends Error {
  constructor(public readonly code: TranscriptionErrorCode, message: string = code) {
    super(message);
  }
}

export interface OpenAITranscriptionOptions {
  apiKey: string;
  /** gpt-transcribe: recommended model for recorded speech (developers.openai.com, 16/09/2026). */
  model?: string;
  baseUrl?: string;
  fetch?: typeof fetch;
}

/** POST /v1/audio/transcriptions (multipart). Logs nothing: audio and text are private. */
export class OpenAITranscriptionProvider implements TranscriptionProvider {
  readonly name = 'openai';
  readonly model: string;
  private readonly baseUrl: string;
  private readonly fetcher: typeof fetch;

  constructor(private readonly options: OpenAITranscriptionOptions) {
    if (!options.apiKey) throw new Error('OPENAI_API_KEY is required for the OpenAI transcription provider.');
    this.model = options.model ?? 'gpt-transcribe';
    this.baseUrl = (options.baseUrl ?? 'https://api.openai.com/v1').replace(/\/+$/, '');
    this.fetcher = options.fetch ?? fetch;
  }

  async transcribe(request: TranscriptionRequest): Promise<TranscriptionResult> {
    const form = new FormData();
    form.append('file', await openAsBlob(request.audioPath, { type: 'audio/mp4' }), 'message.m4a');
    form.append('model', this.model);
    form.append('response_format', 'json');
    // Array fields use the repeated "name[]" form of the OpenAI multipart examples.
    for (const language of request.languages) form.append('languages[]', language);
    for (const keyword of request.keywords) form.append('keywords[]', keyword);
    let response: Response;
    try {
      response = await this.fetcher(`${this.baseUrl}/audio/transcriptions`, {
        method: 'POST',
        headers: { authorization: `Bearer ${this.options.apiKey}` },
        body: form,
        signal: request.signal,
      });
    } catch (error) {
      if (request.signal.aborted || (error as { name?: string }).name === 'TimeoutError') throw new TranscriptionError('TRANSCRIPTION_TIMEOUT');
      throw new TranscriptionError('TRANSCRIPTION_UNAVAILABLE');
    }
    if (response.status === 429 || response.status >= 500) throw new TranscriptionError('TRANSCRIPTION_UNAVAILABLE', `HTTP ${response.status}`);
    if (!response.ok) throw new TranscriptionError('TRANSCRIPTION_REJECTED', `HTTP ${response.status}`);
    let payload: any;
    try { payload = await response.json(); } catch { throw new TranscriptionError('TRANSCRIPTION_INVALID_RESPONSE'); }
    if (typeof payload?.text !== 'string') throw new TranscriptionError('TRANSCRIPTION_INVALID_RESPONSE');
    const languages = Array.isArray(payload.languages)
      ? payload.languages.map((item: { code?: unknown }) => item?.code).filter((code: unknown): code is string => typeof code === 'string' && /^[a-z]{2,3}$/.test(code))
      : typeof payload.language === 'string' ? [payload.language] : [];
    const seconds = payload.usage?.type === 'duration' && Number.isFinite(payload.usage.seconds) ? payload.usage.seconds : null;
    return { text: payload.text, languages: languages.slice(0, 10), seconds };
  }
}

/** Development stand-in: no audio leaves the machine; the text says it is simulated. Never used in production. */
export class SimulatedTranscriptionProvider implements TranscriptionProvider {
  readonly name = 'simulated';
  readonly model = 'simulated-v1';
  constructor(private readonly text = 'Demain rappelle-moi de [voix simulée] réécouter le message vers 17h.') {}
  async transcribe(request: TranscriptionRequest): Promise<TranscriptionResult> {
    if (request.signal.aborted) throw new TranscriptionError('TRANSCRIPTION_TIMEOUT');
    return { text: this.text, languages: ['fr'], seconds: null };
  }
}

/** Deterministic provider for tests. */
export class ScriptedTranscriptionProvider implements TranscriptionProvider {
  readonly name = 'scripted';
  readonly model = 'scripted-v1';
  readonly requests: TranscriptionRequest[] = [];
  private index = 0;
  constructor(private readonly steps: ReadonlyArray<TranscriptionResult | TranscriptionError | ((request: TranscriptionRequest) => Promise<TranscriptionResult>)>) {}
  async transcribe(request: TranscriptionRequest): Promise<TranscriptionResult> {
    this.requests.push(request);
    const step = this.steps[Math.min(this.index++, this.steps.length - 1)];
    if (step === undefined) throw new TranscriptionError('TRANSCRIPTION_UNAVAILABLE');
    if (step instanceof TranscriptionError) throw step;
    return typeof step === 'function' ? step(request) : step;
  }
}
