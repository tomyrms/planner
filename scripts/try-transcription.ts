// One real transcription with the configured OpenAI key (npm run try:transcription -- <file.m4a> [keyword...]).
// Same checks and adapter as the server; the local Docker stack keeps the simulated transcript.
// Each call is billed (about 0.0045 USD per minute): use short, non-sensitive recordings.
import { readFile } from 'node:fs/promises';
import { loadConfig } from '../src/config.js';
import { AudioRejected, inspectM4a, LANGUAGE_HINTS, OpenAITranscriptionProvider, TranscriptionError } from '../src/modules/voice/index.js';

process.env.TRANSCRIPTION_PROVIDER = 'openai';
const [file, ...keywords] = process.argv.slice(2);
if (!file) {
  process.stdout.write('Usage : npm run try:transcription -- <fichier.m4a> [mot-clé…]\n');
  process.exit(1);
}
const config = loadConfig();
if (config.voice.provider.kind !== 'openai') throw new Error('OPENAI_API_KEY manquant.');

/** Reads the duration from the file itself: every declared guess within 1.5 s is accepted by the check. */
function fileDuration(data: Buffer): number {
  let last: unknown;
  for (let declared = 1000; declared <= 120_000; declared += 2000) {
    try {
      return inspectM4a(data, declared).durationMs;
    } catch (error) {
      if (!(error instanceof AudioRejected) || error.code !== 'AUDIO_DURATION_MISMATCH') throw error;
      last = error;
    }
  }
  throw last;
}

const durationMs = fileDuration(await readFile(file));

const provider = new OpenAITranscriptionProvider({ apiKey: config.voice.provider.apiKey, model: config.voice.provider.model, baseUrl: config.voice.provider.baseUrl });
const started = Date.now();
try {
  const result = await provider.transcribe({ audioPath: file, languages: LANGUAGE_HINTS, keywords, signal: AbortSignal.timeout(60_000) });
  process.stdout.write(`${provider.model} · ${(durationMs / 1000).toFixed(1)} s d'audio · ${Date.now() - started} ms\n`
    + `Langues : ${result.languages.join(', ') || '—'} · secondes facturées : ${result.seconds ?? 'non indiquées'}\n`
    + `Texte : ${result.text}\n`);
} catch (error) {
  if (error instanceof TranscriptionError) {
    process.stderr.write(`Échec : ${error.code} (${error.message})\n`);
    process.exitCode = 1;
  } else {
    throw error;
  }
}
