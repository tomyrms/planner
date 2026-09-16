/**
 * Structural check of an M4A (MP4/ISO-BMFF) voice message: container brand, a single mono AAC track,
 * a media payload and the duration from the movie header. The file name and the declared MIME type
 * are ignored (04_Backend/06_Security_Privacy.md, Audio). The audio samples themselves are decoded by
 * the transcription provider, which rejects a corrupt stream.
 */

export class AudioRejected extends Error {
  constructor(public readonly code: 'AUDIO_INVALID' | 'AUDIO_TOO_SHORT' | 'AUDIO_TOO_LONG' | 'AUDIO_DURATION_MISMATCH' | 'AUDIO_NOT_MONO', message: string) {
    super(message);
  }
}

export interface AudioInfo { durationMs: number; channels: number; codec: 'mp4a'; brand: string }

const BRANDS = new Set(['M4A ', 'M4B ', 'mp42', 'mp41', 'isom', 'iso2', 'iso4', 'iso5', 'iso6', '3gp4', '3gp5']);
const CONTAINERS = new Set(['moov', 'trak', 'mdia', 'minf', 'stbl']);
const MAX_DEPTH = 8;
export const MIN_DURATION_MS = 1000;
/** A recorder stopped automatically at 2 minutes may overshoot by a few frames. */
export const MAX_DURATION_MS = 120_500;
const DURATION_TOLERANCE_MS = 1500;

interface Box { type: string; start: number; body: number; end: number }

function boxes(data: Buffer, from: number, to: number): Box[] {
  const found: Box[] = [];
  let offset = from;
  while (offset < to) {
    if (to - offset < 8) throw new AudioRejected('AUDIO_INVALID', 'Truncated box header');
    let size = data.readUInt32BE(offset);
    const type = data.toString('latin1', offset + 4, offset + 8);
    let body = offset + 8;
    if (size === 1) {
      if (to - offset < 16) throw new AudioRejected('AUDIO_INVALID', 'Truncated large box header');
      const large = data.readBigUInt64BE(offset + 8);
      if (large > BigInt(to - offset)) throw new AudioRejected('AUDIO_INVALID', 'Box larger than its parent');
      size = Number(large);
      body = offset + 16;
    } else if (size === 0) {
      size = to - offset;
    }
    if (size < body - offset || offset + size > to) throw new AudioRejected('AUDIO_INVALID', 'Box size out of bounds');
    found.push({ type, start: offset, body, end: offset + size });
    offset += size;
  }
  return found;
}

function walk(data: Buffer, box: Box, depth: number, visit: (box: Box, path: string[]) => void, path: string[]): void {
  if (depth > MAX_DEPTH) throw new AudioRejected('AUDIO_INVALID', 'Boxes nested too deeply');
  visit(box, path);
  if (!CONTAINERS.has(box.type)) return;
  for (const child of boxes(data, box.body, box.end)) walk(data, child, depth + 1, visit, [...path, box.type]);
}

function headerDuration(data: Buffer, box: Box): number {
  const version = data.readUInt8(box.body);
  if (version === 1) {
    if (box.end - box.body < 32) throw new AudioRejected('AUDIO_INVALID', 'Short header');
    const timescale = data.readUInt32BE(box.body + 20);
    const duration = Number(data.readBigUInt64BE(box.body + 24));
    if (timescale === 0) throw new AudioRejected('AUDIO_INVALID', 'Zero timescale');
    return Math.round(duration * 1000 / timescale);
  }
  if (box.end - box.body < 20) throw new AudioRejected('AUDIO_INVALID', 'Short header');
  const timescale = data.readUInt32BE(box.body + 12);
  const duration = data.readUInt32BE(box.body + 16);
  if (timescale === 0) throw new AudioRejected('AUDIO_INVALID', 'Zero timescale');
  return Math.round(duration * 1000 / timescale);
}

export function inspectM4a(data: Buffer, declaredDurationMs: number): AudioInfo {
  const top = boxes(data, 0, data.length);
  const ftyp = top[0];
  if (!ftyp || ftyp.type !== 'ftyp' || ftyp.end - ftyp.body < 8) throw new AudioRejected('AUDIO_INVALID', 'Not an MP4 container');
  const brand = data.toString('latin1', ftyp.body, ftyp.body + 4);
  if (!BRANDS.has(brand)) throw new AudioRejected('AUDIO_INVALID', 'Unsupported container brand');
  const moov = top.filter((box) => box.type === 'moov');
  if (moov.length !== 1) throw new AudioRejected('AUDIO_INVALID', 'Expected one movie box');
  if (!top.some((box) => box.type === 'mdat' && box.end > box.body)) throw new AudioRejected('AUDIO_INVALID', 'No media data');

  const durations: { movie: number | null; media: number | null } = { movie: null, media: null };
  const handlers: string[] = [];
  const formats: Array<{ format: string; channels: number }> = [];
  walk(data, moov[0]!, 0, (box, path) => {
    const parent = path.at(-1);
    if (box.type === 'mvhd' && parent === 'moov') durations.movie = headerDuration(data, box);
    if (box.type === 'mdhd' && parent === 'mdia') durations.media ??= headerDuration(data, box);
    if (box.type === 'hdlr' && parent === 'mdia') {
      if (box.end - box.body < 12) throw new AudioRejected('AUDIO_INVALID', 'Short handler');
      handlers.push(data.toString('latin1', box.body + 8, box.body + 12));
    }
    if (box.type === 'stsd' && parent === 'stbl') {
      if (box.end - box.body < 8) throw new AudioRejected('AUDIO_INVALID', 'Short sample description');
      for (const entry of boxes(data, box.body + 8, box.end)) {
        // Audio sample entry: 6 reserved, 2 index, 8 version/revision/vendor, then the channel count.
        if (entry.end - entry.body < 18) throw new AudioRejected('AUDIO_INVALID', 'Short sample entry');
        formats.push({ format: entry.type, channels: data.readUInt16BE(entry.body + 16) });
      }
    }
  }, []);
  if (handlers.length !== 1 || handlers[0] !== 'soun') throw new AudioRejected('AUDIO_INVALID', 'Expected exactly one audio track');
  if (formats.length !== 1 || formats[0]!.format !== 'mp4a') throw new AudioRejected('AUDIO_INVALID', 'Expected AAC audio');
  if (formats[0]!.channels !== 1) throw new AudioRejected('AUDIO_NOT_MONO', 'Expected mono audio');
  const durationMs = durations.movie ?? durations.media;
  if (durationMs === null) throw new AudioRejected('AUDIO_INVALID', 'No duration');
  if (durationMs < MIN_DURATION_MS) throw new AudioRejected('AUDIO_TOO_SHORT', 'Recording shorter than 1 s');
  if (durationMs > MAX_DURATION_MS) throw new AudioRejected('AUDIO_TOO_LONG', 'Recording longer than 2 min');
  if (Math.abs(durationMs - declaredDurationMs) > DURATION_TOLERANCE_MS) throw new AudioRejected('AUDIO_DURATION_MISMATCH', 'Declared duration differs from the file');
  return { durationMs, channels: 1, codec: 'mp4a', brand };
}
