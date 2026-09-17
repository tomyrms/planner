import { describe, expect, it } from 'vitest';
import { DeepSeekProvider, ProviderError, toolSpecs, type ProviderRequest } from '../../src/modules/assistant/index.js';

const KEY = 'sk-test-not-a-real-key';

function fakeFetch(respond: (url: string, init: RequestInit) => Response | Promise<Response>) {
  const calls: Array<{ url: string; init: RequestInit; body: any }> = [];
  const fetcher = (async (url: string | URL | Request, init?: RequestInit) => {
    calls.push({ url: String(url), init: init!, body: JSON.parse(String(init!.body)) });
    return respond(String(url), init!);
  }) as typeof fetch;
  return { fetcher, calls };
}

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const request = (signal = new AbortController().signal): ProviderRequest => ({
  system: 'politique',
  signal,
  tools: toolSpecs.filter((tool) => tool.name === 'create_task'),
  messages: [
    { role: 'user', content: 'Ajoute du pain' },
    { role: 'assistant', content: null, toolCalls: [{ id: 'call_1', name: 'create_task', arguments: '{"title":"Pain"}' }], providerState: 'raisonnement' },
    { role: 'tool', toolCallId: 'call_1', content: '{"status":"staged"}' },
  ],
});

describe('DeepSeek provider adapter', () => {
  it('sends an OpenAI-compatible request in non-thinking mode by default', async () => {
    const { fetcher, calls } = fakeFetch(() => json(200, {
      choices: [{ finish_reason: 'tool_calls', message: { role: 'assistant', content: '', tool_calls: [{ id: 'call_2', type: 'function', function: { name: 'list_day', arguments: '{"date":"2026-09-16"}' } }] } }],
      usage: { prompt_tokens: 120, completion_tokens: 18 },
    }));
    const provider = new DeepSeekProvider({ apiKey: KEY, fetch: fetcher });
    const response = await provider.respond(request());
    expect(provider.model).toBe('deepseek-flash');
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe('https://api.deepseek.com/chat/completions');
    expect((calls[0]!.init.headers as Record<string, string>).authorization).toBe(`Bearer ${KEY}`);
    expect(calls[0]!.body).toMatchObject({
      model: 'deepseek-flash', thinking: { type: 'disabled' }, temperature: 0, stream: false, tool_choice: 'auto',
      messages: [
        { role: 'system', content: 'politique' },
        { role: 'user', content: 'Ajoute du pain' },
        { role: 'assistant', content: null, tool_calls: [{ id: 'call_1', type: 'function', function: { name: 'create_task', arguments: '{"title":"Pain"}' } }] },
        { role: 'tool', tool_call_id: 'call_1', content: '{"status":"staged"}' },
      ],
    });
    // Reasoning is only sent back in thinking mode.
    expect(calls[0]!.body.messages[2]).not.toHaveProperty('reasoning_content');
    expect(calls[0]!.body.tools[0]).toMatchObject({ type: 'function', function: { name: 'create_task', parameters: { type: 'object' } } });
    expect(response).toEqual({
      text: null, finish: 'tool_calls', usage: { inputTokens: 120, outputTokens: 18 },
      toolCalls: [{ id: 'call_2', name: 'list_day', arguments: '{"date":"2026-09-16"}' }],
    });
  });

  it('passes reasoning back within the turn when thinking is enabled', async () => {
    const { fetcher, calls } = fakeFetch(() => json(200, {
      choices: [{ finish_reason: 'stop', message: { role: 'assistant', content: 'Fait.', reasoning_content: 'nouveau raisonnement' } }],
    }));
    const provider = new DeepSeekProvider({ apiKey: KEY, fetch: fetcher, thinking: true, model: 'deepseek-v4-pro', baseUrl: 'https://proxy.example/v1/' });
    const response = await provider.respond(request());
    expect(calls[0]!.url).toBe('https://proxy.example/v1/chat/completions');
    expect(calls[0]!.body).toMatchObject({ model: 'deepseek-v4-pro', thinking: { type: 'enabled' } });
    expect(calls[0]!.body).not.toHaveProperty('temperature');
    expect(calls[0]!.body.messages[2].reasoning_content).toBe('raisonnement');
    expect(response).toMatchObject({ text: 'Fait.', finish: 'stop', providerState: 'nouveau raisonnement', usage: { inputTokens: 0, outputTokens: 0 } });
  });

  it('maps failures to provider errors without exposing the key', async () => {
    const cases: Array<[() => Response | Promise<Response>, string]> = [
      [() => json(429, { error: 'rate limited' }), 'PROVIDER_UNAVAILABLE'],
      [() => json(503, {}), 'PROVIDER_UNAVAILABLE'],
      [() => json(401, { error: 'bad key' }), 'PROVIDER_REJECTED'],
      [() => new Response('not json', { status: 200 }), 'PROVIDER_INVALID_RESPONSE'],
      [() => json(200, { choices: [] }), 'PROVIDER_INVALID_RESPONSE'],
      [() => json(200, { choices: [{ finish_reason: 'tool_calls', message: { tool_calls: [{ id: 1, function: {} }] } }] }), 'PROVIDER_INVALID_RESPONSE'],
      [() => { throw new TypeError('fetch failed'); }, 'PROVIDER_UNAVAILABLE'],
    ];
    for (const [respond, code] of cases) {
      const provider = new DeepSeekProvider({ apiKey: KEY, fetch: fakeFetch(respond).fetcher });
      const error = await provider.respond(request()).catch((caught: unknown) => caught);
      expect(error, code).toBeInstanceOf(ProviderError);
      expect((error as ProviderError).code).toBe(code);
      expect(String((error as Error).message)).not.toContain(KEY);
    }
    const controller = new AbortController();
    controller.abort();
    const aborted = new DeepSeekProvider({ apiKey: KEY, fetch: fakeFetch(() => { throw new DOMException('aborted', 'AbortError'); }).fetcher });
    await expect(aborted.respond(request(controller.signal))).rejects.toMatchObject({ code: 'PROVIDER_TIMEOUT' });
    const truncated = new DeepSeekProvider({ apiKey: KEY, fetch: fakeFetch(() => json(200, { choices: [{ finish_reason: 'length', message: { content: 'Ajouté' } }] })).fetcher });
    expect(await truncated.respond(request())).toMatchObject({ finish: 'length' });
    expect(() => new DeepSeekProvider({ apiKey: '' })).toThrow();
  });

  it('projects every tool as a closed JSON schema', () => {
    expect(toolSpecs.map((tool) => tool.name)).toEqual([
      'search_tasks', 'get_task', 'list_day', 'list_upcoming', 'list_projects', 'list_tags', 'find_free_slots',
      'create_task', 'update_task', 'complete_task', 'reopen_task', 'delete_task', 'restore_task',
      'skip_occurrence', 'reschedule_occurrence', 'update_series', 'end_series', 'set_reminder', 'remove_reminder',
      'create_project', 'add_subtask', 'update_subtask', 'remove_subtask', 'add_task_tag', 'remove_task_tag', 'ask_clarification', 'refuse_request',
    ]);
    for (const tool of toolSpecs) {
      expect(tool.parameters, tool.name).toMatchObject({ type: 'object', additionalProperties: false });
      expect(tool.parameters).not.toHaveProperty('$schema');
      expect(JSON.stringify(tool.parameters)).not.toMatch(/userId|ownerId|createdAt|completedAt/);
    }
  });
});
