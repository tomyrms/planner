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
  if (box.end - box.body < 4) throw new AudioRejected('AUDIO_INVALID', 'Short header');
  const version = data.readUInt8(box.body);
  if (version === 1) {
    if (box.end - box.body < 32) throw new AudioRejected('AUDIO_INVALID', 'Short header');
    const timescale = data.readUInt32BE(box.body + 20);
    const duration = Number(data.readBigUInt64BE(box.body + 24));
    if (timescale === 0) throw new AudioRejected('AUDIO_INVALID', 'Zero timescale');
    return Math.round(duration * 1000 / timescale);
  }
  if (version !== 0) throw new AudioRejected('AUDIO_INVALID', 'Unsupported duration header version');
  if (box.end - box.body < 20) throw new AudioRejected('AUDIO_INVALID', 'Short header');
  const timescale = data.readUInt32BE(box.body + 12);
  const duration = data.readUInt32BE(box.body + 16);
  if (timescale === 0) throw new AudioRejected('AUDIO_INVALID', 'Zero timescale');
  return Math.round(duration * 1000 / timescale);
}

interface Descriptor { tag: number; body: number; end: number }

/** ISO/IEC 14496-1 descriptor sizes have at most four 7-bit groups, including padded encodings. */
function descriptors(data: Buffer, from: number, to: number): Descriptor[] {
  const found: Descriptor[] = [];
  let offset = from;
  while (offset < to) {
    const tag = data[offset++]!;
    let length = 0;
    let complete = false;
    for (let group = 0; group < 4; group++) {
      if (offset >= to) throw new AudioRejected('AUDIO_INVALID', 'Truncated descriptor length');
      const byte = data[offset++]!;
      length = length * 128 + (byte & 0x7f);
      if ((byte & 0x80) === 0) { complete = true; break; }
    }
    if (!complete || length > to - offset) throw new AudioRejected('AUDIO_INVALID', 'Descriptor size out of bounds');
    found.push({ tag, body: offset, end: offset + length });
    offset += length;
  }
  return found;
}

function oneDescriptor(list: Descriptor[], tag: number): Descriptor {
  const matches = list.filter((descriptor) => descriptor.tag === tag);
  if (matches.length !== 1) throw new AudioRejected('AUDIO_INVALID', 'Expected one audio descriptor');
  return matches[0]!;
}

/** Codec configuration, not the legacy sample-entry channel count, describes MPEG-4 AAC channels.
 * References: Apple QTFF Sound sample data (mp4a / wave / esds), FFmpeg libavformat/isom.c and
 * libavcodec/mpeg4audio.c. This is a bounded structural check, not an AAC sample decoder.
 */
function aacChannels(data: Buffer, esds: Box): number {
  if (esds.end - esds.body < 4 || data.readUInt32BE(esds.body) !== 0) {
    throw new AudioRejected('AUDIO_INVALID', 'Unsupported elementary stream header');
  }
  const stream = oneDescriptor(descriptors(data, esds.body + 4, esds.end), 0x03);
  if (stream.end - stream.body < 3) throw new AudioRejected('AUDIO_INVALID', 'Short elementary stream descriptor');
  const flags = data[stream.body + 2]!;
  let offset = stream.body + 3;
  if (flags & 0x80) offset += 2; // dependsOn_ES_ID
  if (flags & 0x40) {
    if (offset >= stream.end) throw new AudioRejected('AUDIO_INVALID', 'Short stream URL');
    offset += 1 + data[offset]!;
  }
  if (flags & 0x20) offset += 2; // OCR_ES_ID
  if (offset > stream.end) throw new AudioRejected('AUDIO_INVALID', 'Short elementary stream flags');
  const decoder = oneDescriptor(descriptors(data, offset, stream.end), 0x04);
  if (decoder.end - decoder.body < 13) throw new AudioRejected('AUDIO_INVALID', 'Short decoder descriptor');
  // MPEG-4 audio or MPEG-2 AAC, with streamType AudioStream (5) and its required reserved bit.
  if (![0x40, 0x66, 0x67, 0x68].includes(data[decoder.body]!) || (data[decoder.body + 1]! >> 2) !== 5
      || (data[decoder.body + 1]! & 1) !== 1) throw new AudioRejected('AUDIO_INVALID', 'Expected an AAC decoder');
  const config = oneDescriptor(descriptors(data, decoder.body + 13, decoder.end), 0x05);
  let bit = config.body * 8;
  const endBit = config.end * 8;
  const read = (count: number): number => {
    if (bit + count > endBit) throw new AudioRejected('AUDIO_INVALID', 'Truncated AudioSpecificConfig');
    let value = 0;
    for (let index = 0; index < count; index++, bit++) value = value * 2 + ((data[Math.floor(bit / 8)]! >> (7 - bit % 8)) & 1);
    return value;
  };
  const objectType = () => { const type = read(5); return type === 31 ? 32 + read(6) : type; };
  const frequency = () => {
    const index = read(4);
    if (index === 15) {
      if (read(24) === 0) throw new AudioRejected('AUDIO_INVALID', 'Zero AAC frequency');
    } else if (index > 12) throw new AudioRejected('AUDIO_INVALID', 'Reserved AAC frequency');
  };
  let type = objectType();
  frequency();
  const channels = read(4);
  // Program Config Elements (0) and reserved configurations cannot prove a mono stream here.
  if (channels === 0 || [8, 9, 10, 15].includes(channels)) throw new AudioRejected('AUDIO_INVALID', 'Unsupported AAC channel configuration');
  if (channels !== 1 || type === 29) throw new AudioRejected('AUDIO_NOT_MONO', 'Expected mono audio');
  const explicitSbr = type === 5;
  if (explicitSbr) { frequency(); type = objectType(); }
  if (![1, 2, 3, 4].includes(type)) throw new AudioRejected('AUDIO_INVALID', 'Unsupported AAC object type');
  read(1); // frameLengthFlag
  if (read(1)) read(14); // dependsOnCoreCoder / coreCoderDelay
  if (read(1) && read(1)) throw new AudioRejected('AUDIO_INVALID', 'Unsupported AAC extension');
  // Implicit HE-AAC/HE-AACv2 may follow a plain AAC config. Parametric stereo turns a mono core
  // into stereo output; never accept it merely because channelConfiguration was 1.
  if (!explicitSbr && endBit - bit >= 11) {
    const extensionStart = bit;
    if (read(11) === 0x2b7) {
      if (objectType() !== 5) throw new AudioRejected('AUDIO_INVALID', 'Unsupported AAC sync extension');
      if (read(1)) frequency();
      if (endBit - bit >= 12) {
        const stereoStart = bit;
        if (read(11) === 0x548) {
          if (read(1)) throw new AudioRejected('AUDIO_NOT_MONO', 'Parametric stereo is not mono');
        } else bit = stereoStart;
      }
    } else {
      bit = extensionStart;
    }
  }
  // Remaining bits are padding; unknown/truncated extensions are not evidence of mono audio.
  while (bit < endBit) if (read(1)) throw new AudioRejected('AUDIO_INVALID', 'Unexpected AAC configuration bits');
  return channels;
}

function sampleChannels(data: Buffer, entry: Box): number {
  if (entry.type !== 'mp4a') throw new AudioRejected('AUDIO_INVALID', 'Expected AAC audio');
  if (entry.end - entry.body < 28) throw new AudioRejected('AUDIO_INVALID', 'Short audio sample entry');
  const version = data.readUInt16BE(entry.body + 8);
  if (version !== 0 && version !== 1) throw new AudioRejected('AUDIO_INVALID', 'Unsupported audio sample entry version');
  const headerSize = version === 1 ? 44 : 28;
  if (entry.end - entry.body < headerSize) throw new AudioRejected('AUDIO_INVALID', 'Short versioned audio sample entry');
  const configs: Box[] = [];
  const find = (from: number, to: number, depth: number) => {
    if (depth > MAX_DEPTH) throw new AudioRejected('AUDIO_INVALID', 'Audio extensions nested too deeply');
    for (const child of boxes(data, from, to)) {
      if (child.type === 'esds') configs.push(child);
      else if (child.type === 'wave') find(child.body, child.end, depth + 1);
    }
  };
  find(entry.body + headerSize, entry.end, 0);
  if (configs.length !== 1) throw new AudioRejected('AUDIO_INVALID', 'Expected one AAC configuration');
  return aacChannels(data, configs[0]!);
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
      if (data.readUInt32BE(box.body) !== 0) throw new AudioRejected('AUDIO_INVALID', 'Unsupported sample description version');
      const entries = boxes(data, box.body + 8, box.end);
      if (data.readUInt32BE(box.body + 4) !== entries.length) throw new AudioRejected('AUDIO_INVALID', 'Sample entry count mismatch');
      for (const entry of entries) formats.push({ format: entry.type, channels: sampleChannels(data, entry) });
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
