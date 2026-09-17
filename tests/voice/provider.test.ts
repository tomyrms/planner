import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { OpenAITranscriptionProvider, TranscriptionError, type TranscriptionRequest } from '../../src/modules/voice/index.js';

const audioPath = fileURLToPath(new URL('../fixtures/audio/tone-3s-mono.m4a', import.meta.url));
const KEY = 'sk-test-secret-value';

function request(overrides: Partial<TranscriptionRequest> = {}): TranscriptionRequest {
  return { audioPath, languages: ['fr', 'pt', 'en'], keywords: ['C#', 'Maison'], signal: new AbortController().signal, beforeSend: async () => {}, ...overrides };
}

function providerWith(respond: (url: string, init: RequestInit) => Promise<Response>) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const provider = new OpenAITranscriptionProvider({
    apiKey: KEY, baseUrl: 'https://openai.test/v1/',
    fetch: (async (url: string, init: RequestInit) => { calls.push({ url, init }); return respond(url, init); }) as typeof fetch,
  });
  return { provider, calls };
}

async function failure(promise: Promise<unknown>): Promise<TranscriptionError> {
  const error = await promise.then(() => null, (caught: unknown) => caught);
  expect(error).toBeInstanceOf(TranscriptionError);
  expect(String((error as Error).message)).not.toContain(KEY);
  return error as TranscriptionError;
}

describe('OpenAI transcription adapter', () => {
  it('sends the file with the model, JSON format, language hints and keywords', async () => {
    const { provider, calls } = providerWith(async () => Response.json({
      text: 'Demain rappelle-moi d’appeler le garage.', languages: [{ code: 'fr' }, { code: 'bad code' }, {}],
      usage: { type: 'duration', seconds: 3 },
    }));
    expect(provider).toMatchObject({ name: 'openai', model: 'gpt-transcribe' });
    const result = await provider.transcribe(request());
    expect(result).toEqual({ text: 'Demain rappelle-moi d’appeler le garage.', languages: ['fr'], seconds: 3 });
    expect(calls).toHaveLength(1);
    const { url, init } = calls[0]!;
    expect(url).toBe('https://openai.test/v1/audio/transcriptions');
    expect(init.method).toBe('POST');
    expect(init.headers).toEqual({ authorization: `Bearer ${KEY}` });
    const form = init.body as FormData;
    expect(form.get('model')).toBe('gpt-transcribe');
    expect(form.get('response_format')).toBe('json');
    expect(form.getAll('languages[]')).toEqual(['fr', 'pt', 'en']);
    expect(form.getAll('keywords[]')).toEqual(['C#', 'Maison']);
    const file = form.get('file') as File;
    expect(file.name).toBe('message.m4a');
    expect(file.type).toBe('audio/mp4');
    expect(file.size).toBe(13_523);
    // No prompt, no temperature, nothing else is sent.
    expect([...new Set(form.keys())].sort()).toEqual(['file', 'keywords[]', 'languages[]', 'model', 'response_format']);
  });

  it('accepts the older single-language shape and a response without usage', async () => {
    const { provider } = providerWith(async () => Response.json({ text: 'Olá', language: 'pt' }));
    expect(await provider.transcribe(request({ keywords: [] }))).toEqual({ text: 'Olá', languages: ['pt'], seconds: null });
  });

  it('awaits durable dispatch authorization before any HTTP and preserves its rejection', async () => {
    const { provider, calls } = providerWith(async () => Response.json({ text: 'Autorisé.' }));
    let authorize!: () => void;
    let entered!: () => void;
    const waiting = new Promise<void>((resolve) => { entered = resolve; });
    const gate = new Promise<void>((resolve) => { authorize = resolve; });
    const pending = provider.transcribe(request({ beforeSend: async () => { entered(); await gate; } }));
    try {
      await waiting;
      expect(calls).toHaveLength(0);
      authorize();
      expect(await pending).toMatchObject({ text: 'Autorisé.' });
      expect(calls).toHaveLength(1);
    } finally { authorize(); }

    const blocked = providerWith(async () => Response.json({ text: 'Jamais envoyé.' }));
    const budgetError = new Error('TRANSCRIPTION_BUDGET_EXCEEDED');
    await expect(blocked.provider.transcribe(request({ beforeSend: async () => { throw budgetError; } }))).rejects.toBe(budgetError);
    expect(blocked.calls).toHaveLength(0);
  });

  it('does not authorize dispatch when local preparation fails or the request was already cancelled', async () => {
    const { provider, calls } = providerWith(async () => Response.json({ text: 'Jamais envoyé.' }));
    let authorized = 0;
    const beforeSend = async () => { authorized++; };
    await expect(provider.transcribe(request({ audioPath: `${audioPath}.missing`, beforeSend }))).rejects.toThrow();
    const signal = AbortSignal.abort();
    expect((await failure(provider.transcribe(request({ signal, beforeSend })))).code).toBe('TRANSCRIPTION_TIMEOUT');
    expect(authorized).toBe(0);
    expect(calls).toHaveLength(0);
  });

  it('maps provider failures to stable codes without leaking the key or the body', async () => {
    const statuses: Array<[number, string]> = [[429, 'TRANSCRIPTION_UNAVAILABLE'], [500, 'TRANSCRIPTION_UNAVAILABLE'], [503, 'TRANSCRIPTION_UNAVAILABLE'], [400, 'TRANSCRIPTION_REJECTED'], [401, 'TRANSCRIPTION_REJECTED'], [413, 'TRANSCRIPTION_REJECTED']];
    for (const [status, code] of statuses) {
      const { provider } = providerWith(async () => new Response(`{"error":"private transcript ${KEY}"}`, { status }));
      const error = await failure(provider.transcribe(request()));
      expect(error.code).toBe(code);
      expect(error.message).not.toContain('private');
    }
    const invalid = providerWith(async () => new Response('not json', { status: 200 }));
    expect((await failure(invalid.provider.transcribe(request()))).code).toBe('TRANSCRIPTION_INVALID_RESPONSE');
    const noText = providerWith(async () => Response.json({ transcript: 'x' }));
    expect((await failure(noText.provider.transcribe(request()))).code).toBe('TRANSCRIPTION_INVALID_RESPONSE');
    const network = providerWith(async () => { throw new TypeError('fetch failed'); });
    expect((await failure(network.provider.transcribe(request()))).code).toBe('TRANSCRIPTION_UNAVAILABLE');
  });

  it('reports a cancelled or timed-out call as a timeout', async () => {
    const abort = new AbortController();
    // Like the real fetch: an already-aborted signal rejects at once, a later abort rejects the pending call.
    const { provider } = providerWith(async (_url, init) => new Promise<Response>((_resolve, reject) => {
      const signal = init.signal!;
      if (signal.aborted) reject(signal.reason);
      signal.addEventListener('abort', () => reject(signal.reason));
    }));
    const pending = provider.transcribe(request({ signal: abort.signal }));
    abort.abort();
    expect((await failure(pending)).code).toBe('TRANSCRIPTION_TIMEOUT');
    const timed = provider.transcribe(request({ signal: AbortSignal.timeout(10) }));
    expect((await failure(timed)).code).toBe('TRANSCRIPTION_TIMEOUT');
  });

  it('requires a key', () => {
    expect(() => new OpenAITranscriptionProvider({ apiKey: '' })).toThrow(/OPENAI_API_KEY/);
  });
});
