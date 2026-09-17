import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { AudioRejected, inspectM4a } from '../../src/modules/voice/index.js';

// Real AAC files written by ffmpeg (3 s, 440 Hz). Mutated headers below cover other legal container
// layouts; they are not claimed to be recordings captured on an iPhone.
const mono = readFileSync(new URL('../fixtures/audio/tone-3s-mono.m4a', import.meta.url));
const stereo = readFileSync(new URL('../fixtures/audio/tone-3s-stereo.m4a', import.meta.url));
// Synthetic 440 Hz tone encoded by Apple AVAudioFile on CI, using ios/scripts/generate-audio-fixture.swift.
// Contains no speech or personal audio. AAC priming/padding makes its movie duration slightly over 3 s.
const appleMono = readFileSync(new URL('../fixtures/audio/apple-tone-3s-mono.m4a', import.meta.url));

function rejection(data: Buffer, declared = 3000): string {
  try {
    inspectM4a(data, declared);
  } catch (error) {
    if (error instanceof AudioRejected) return error.code;
    throw error;
  }
  return 'accepted';
}

/** Copy with the movie header duration (version 0, milliseconds timescale in the fixture) replaced. */
function withMovieDuration(ms: number): Buffer {
  const copy = Buffer.from(mono);
  const at = copy.indexOf(Buffer.from('mvhd'));
  expect(copy.readUInt32BE(at + 16)).toBe(1000);
  copy.writeUInt32BE(ms, at + 20);
  return copy;
}

function box(type: string, body: Buffer): Buffer {
  const header = Buffer.alloc(8);
  header.writeUInt32BE(body.length + 8);
  header.write(type, 4, 'latin1');
  return Buffer.concat([header, body]);
}

/** Replace a known box in the fixture, adjusting its enclosing boxes without touching media bytes. */
function replacingBox(fixture: Buffer, type: string, replacement: Buffer): Buffer {
  const start = fixture.indexOf(Buffer.from(type)) - 4;
  expect(start).toBeGreaterThanOrEqual(0);
  const end = start + fixture.readUInt32BE(start);
  const result = Buffer.concat([fixture.subarray(0, start), replacement, fixture.subarray(end)]);
  const delta = replacement.length - (end - start);
  for (const ancestor of ['moov', 'trak', 'mdia', 'minf', 'stbl', 'stsd', 'mp4a']) {
    const at = fixture.indexOf(Buffer.from(ancestor)) - 4;
    if (at >= 0 && at < start && at + fixture.readUInt32BE(at) >= end) result.writeUInt32BE(fixture.readUInt32BE(at) + delta, at);
  }
  return result;
}

function description(fixture = mono): Buffer {
  const at = fixture.indexOf(Buffer.from('mp4a')) - 4;
  return Buffer.from(fixture.subarray(at + 8, at + fixture.readUInt32BE(at)));
}

function descriptor(tag: number, body: Buffer): Buffer {
  expect(body.length).toBeLessThan(128);
  return Buffer.concat([Buffer.from([tag, body.length]), body]);
}

function elementaryStream(config: Buffer, options: { streamFlags?: Buffer; decoderHeader?: Buffer } = {}): Buffer {
  const decoderHeader = options.decoderHeader ?? Buffer.from([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
  return box('esds', Buffer.concat([Buffer.alloc(4), descriptor(3, Buffer.concat([
    options.streamFlags ?? Buffer.from([0, 1, 0]), descriptor(4, Buffer.concat([decoderHeader, descriptor(5, config)])), descriptor(6, Buffer.from([2])),
  ]))]));
}

function withConfig(config: Buffer): Buffer {
  return replacingBox(mono, 'esds', elementaryStream(config));
}

/** Bits for AudioSpecificConfig examples; final zero bits are byte padding. */
function bits(...fields: Array<[number, number]>): Buffer {
  const text = fields.map(([value, count]) => value.toString(2).padStart(count, '0')).join('');
  const padded = text.padEnd(Math.ceil(text.length / 8) * 8, '0');
  return Buffer.from(padded.match(/.{8}/g)!.map((byte) => Number.parseInt(byte, 2)));
}

describe('M4A structural check', () => {
  it('accepts a mono AAC recording and reads its duration from the file', () => {
    expect(inspectM4a(mono, 3000)).toEqual({ durationMs: 3000, channels: 1, codec: 'mp4a', brand: 'M4A ' });
    // The declared duration may differ by up to 1.5 s (recorder rounding).
    expect(inspectM4a(mono, 4500).durationMs).toBe(3000);
    expect(inspectM4a(mono, 1500).durationMs).toBe(3000);
  });

  it('accepts a real Apple-encoded mono AAC fixture with legacy stereo count and reserved decoder bit 0', () => {
    expect(appleMono.readUInt16BE(appleMono.indexOf(Buffer.from('mp4a')) + 20)).toBe(2);
    const info = inspectM4a(appleMono, 3000);
    expect(info).toMatchObject({ channels: 1, codec: 'mp4a', brand: 'M4A ' });
    expect(info.durationMs).toBe(3111);
    expect(Math.abs(info.durationMs - 3000)).toBeLessThanOrEqual(1500);
  });

  it('uses the AAC channel configuration even when the legacy sample entry says stereo', () => {
    const legacyStereo = Buffer.from(mono);
    legacyStereo.writeUInt16BE(2, legacyStereo.indexOf(Buffer.from('mp4a')) + 20);
    expect(inspectM4a(legacyStereo, 3000).channels).toBe(1);
    // A real stereo AAC stream cannot pass by falsifying the legacy field to mono.
    const hiddenStereo = Buffer.from(stereo);
    hiddenStereo.writeUInt16BE(1, hiddenStereo.indexOf(Buffer.from('mp4a')) + 20);
    expect(rejection(hiddenStereo)).toBe('AUDIO_NOT_MONO');
    expect(rejection(withConfig(Buffer.from([0x12, 0x10])))).toBe('AUDIO_NOT_MONO');
  });

  it('accepts bounded sample entry versions 0 and 1 with direct or wave-wrapped esds', () => {
    const original = description();
    const extensions = original.subarray(28);
    for (const version of [0, 1]) {
      for (const wave of [false, true]) {
        const header = Buffer.concat([original.subarray(0, 28), Buffer.alloc(version === 1 ? 16 : 0)]);
        header.writeUInt16BE(version, 8);
        header.writeUInt16BE(2, 16);
        const children = wave
          ? box('wave', Buffer.concat([box('frma', Buffer.from('mp4a')), extensions, box('\0\0\0\0', Buffer.alloc(0))]))
          : extensions;
        expect(rejection(replacingBox(mono, 'mp4a', box('mp4a', Buffer.concat([header, children]))))).toBe('accepted');
      }
    }
  });

  it('parses short and padded descriptors, optional ES fields and AAC frequency encodings', () => {
    expect(rejection(withConfig(Buffer.from([0x12, 0x08])))).toBe('accepted');
    expect(rejection(withConfig(Buffer.from([0x12, 0x08, 0, 0, 0])))).toBe('accepted');
    const optionalFields = elementaryStream(Buffer.from([0x12, 0x08]), {
      streamFlags: Buffer.from([0, 1, 0xe0, 0, 2, 3, 0x61, 0x62, 0x63, 0, 3]),
    });
    expect(rejection(replacingBox(mono, 'esds', optionalFields))).toBe('accepted');
    expect(rejection(withConfig(bits([2, 5], [15, 4], [44_100, 24], [1, 4], [0, 3])))).toBe('accepted');
    expect(rejection(withConfig(bits([5, 5], [7, 4], [1, 4], [4, 4], [2, 5], [0, 3])))).toBe('accepted');
    expect(rejection(withConfig(bits([2, 5], [4, 4], [1, 4], [0, 3], [0x2b7, 11], [5, 5], [1, 1], [4, 4])))).toBe('accepted');
  });

  it('rejects parametric stereo and configurations that cannot establish mono AAC', () => {
    expect(rejection(withConfig(bits([29, 5], [4, 4], [1, 4])))).toBe('AUDIO_NOT_MONO');
    expect(rejection(withConfig(bits([2, 5], [4, 4], [1, 4], [0, 3], [0x2b7, 11], [5, 5], [1, 1], [4, 4], [0x548, 11], [1, 1])))).toBe('AUDIO_NOT_MONO');
    for (const config of [
      Buffer.alloc(0), Buffer.from([0x12]), // truncated config
      bits([2, 5], [13, 4], [1, 4], [0, 3]), // reserved frequency
      bits([2, 5], [15, 4], [0, 24], [1, 4], [0, 3]), // zero explicit frequency
      bits([2, 5], [4, 4], [0, 4], [0, 3]), // PCE not supported, cannot assume mono
      bits([2, 5], [4, 4], [15, 4], [0, 3]), // reserved channels
      bits([31, 5], [0, 6], [4, 4], [1, 4], [0, 3]), // unsupported escaped object type
      bits([2, 5], [4, 4], [1, 4], [0, 1], [1, 1]), // missing core coder delay
      bits([2, 5], [4, 4], [1, 4], [0, 3], [0x2b7, 11], [5, 5]), // missing extension flag
    ]) expect(rejection(withConfig(config))).toBe('AUDIO_INVALID');
  });

  it('rejects malformed descriptor sizes and missing, duplicate or non-AAC decoder configurations', () => {
    for (const payload of [
      Buffer.from([3]), // no length
      Buffer.from([3, 0x80, 0x80, 0x80, 0x80, 0]), // overlong length
      Buffer.from([3, 0x7f, 0, 1, 0]), // beyond parent
      descriptor(3, Buffer.from([0, 1, 0x40, 0x7f])), // truncated URL
      descriptor(3, Buffer.concat([Buffer.from([0, 1, 0]), descriptor(4, Buffer.alloc(12))])), // short decoder
      descriptor(3, Buffer.concat([Buffer.from([0, 1, 0]), descriptor(4, Buffer.concat([Buffer.from([0x40, 0x15]), Buffer.alloc(11), Buffer.from([5, 127])]))])),
    ]) expect(rejection(replacingBox(mono, 'esds', box('esds', Buffer.concat([Buffer.alloc(4), payload]))))).toBe('AUDIO_INVALID');
    const nonAudio = Buffer.from([0x40, 0x11, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    expect(rejection(replacingBox(mono, 'esds', elementaryStream(Buffer.from([0x12, 0x08]), { decoderHeader: nonAudio })))).toBe('AUDIO_INVALID');
    const mp3 = Buffer.from(nonAudio); mp3[0] = 0x6b; mp3[1] = 0x15;
    expect(rejection(replacingBox(mono, 'esds', elementaryStream(Buffer.from([0x12, 0x08]), { decoderHeader: mp3 })))).toBe('AUDIO_INVALID');
    const original = description();
    expect(rejection(replacingBox(mono, 'mp4a', box('mp4a', original.subarray(0, 28))))).toBe('AUDIO_INVALID');
    expect(rejection(replacingBox(mono, 'mp4a', box('mp4a', Buffer.concat([original, original.subarray(28)]))))).toBe('AUDIO_INVALID');
  });

  it('rejects unsupported versions, invalid entry counts and truncated versioned headers without RangeError', () => {
    for (const type of ['mvhd', 'mdhd', 'stsd', 'esds']) {
      const invalid = Buffer.from(mono);
      invalid[invalid.indexOf(Buffer.from(type)) + 4] = 2;
      expect(rejection(invalid)).toBe('AUDIO_INVALID');
    }
    const count = Buffer.from(mono);
    count.writeUInt32BE(2, count.indexOf(Buffer.from('stsd')) + 8);
    expect(rejection(count)).toBe('AUDIO_INVALID');
    const original = description();
    for (const version of [0, 1, 2, 65_535]) {
      const body = Buffer.from(original.subarray(0, version === 1 ? 43 : 27));
      body.writeUInt16BE(version, 8);
      expect(rejection(replacingBox(mono, 'mp4a', box('mp4a', body)))).toBe('AUDIO_INVALID');
    }
    for (const version of [2, 65_535]) {
      const body = Buffer.from(original);
      body.writeUInt16BE(version, 8);
      expect(rejection(replacingBox(mono, 'mp4a', box('mp4a', body)))).toBe('AUDIO_INVALID');
    }
    for (const type of ['mvhd', 'mdhd']) {
      for (const length of [0, 1, 3, 19]) expect(rejection(replacingBox(mono, type, box(type, Buffer.alloc(length))))).toBe('AUDIO_INVALID');
      const shortV1 = Buffer.alloc(31); shortV1[0] = 1;
      expect(rejection(replacingBox(mono, type, box(type, shortV1)))).toBe('AUDIO_INVALID');
      const at = mono.indexOf(Buffer.from(type)) + 4;
      const completeV1 = Buffer.alloc(32);
      completeV1[0] = 1;
      completeV1.writeUInt32BE(mono.readUInt32BE(at + 12), 20);
      completeV1.writeBigUInt64BE(BigInt(mono.readUInt32BE(at + 16)), 24);
      expect(rejection(replacingBox(mono, type, box(type, completeV1)))).toBe('accepted');
    }
  });

  it('rejects stereo, a declared duration that does not match, and lengths outside 1 s – 2 min', () => {
    expect(rejection(stereo)).toBe('AUDIO_NOT_MONO');
    expect(rejection(mono, 4501)).toBe('AUDIO_DURATION_MISMATCH');
    expect(rejection(mono, 1499)).toBe('AUDIO_DURATION_MISMATCH');
    expect(rejection(withMovieDuration(999), 1000)).toBe('AUDIO_TOO_SHORT');
    expect(rejection(withMovieDuration(1000), 1000)).toBe('accepted');
    expect(rejection(withMovieDuration(120_500), 120_000)).toBe('accepted');
    expect(rejection(withMovieDuration(120_501), 120_000)).toBe('AUDIO_TOO_LONG');
  });

  it('rejects anything that is not a complete MP4 audio container, whatever its name or MIME type', () => {
    expect(rejection(Buffer.alloc(0))).toBe('AUDIO_INVALID');
    expect(rejection(Buffer.from('RIFF....WAVEfmt '))).toBe('AUDIO_INVALID');
    expect(rejection(Buffer.from('{"text":"not audio"}'))).toBe('AUDIO_INVALID');
    // Truncated upload: the last box claims bytes that never arrived.
    expect(rejection(mono.subarray(0, mono.length - 100))).toBe('AUDIO_INVALID');
    expect(rejection(mono.subarray(0, 40))).toBe('AUDIO_INVALID');
    // Unknown brand (a video or HEIF container).
    const heic = Buffer.from(mono);
    heic.write('heic', 8, 'latin1');
    expect(rejection(heic)).toBe('AUDIO_INVALID');
    // A box larger than the file.
    const oversized = Buffer.from(mono);
    oversized.writeUInt32BE(mono.length + 1, 0);
    expect(rejection(oversized)).toBe('AUDIO_INVALID');
    // The first box must be ftyp.
    const reordered = Buffer.from(mono);
    reordered.write('free', 4, 'latin1');
    expect(rejection(reordered)).toBe('AUDIO_INVALID');
    // A video track instead of the audio one.
    const video = Buffer.from(mono);
    video.write('vide', video.indexOf(Buffer.from('soun')), 'latin1');
    expect(rejection(video)).toBe('AUDIO_INVALID');
    // Another codec in the sample description.
    const opus = Buffer.from(mono);
    opus.write('Opus', opus.indexOf(Buffer.from('mp4a')), 'latin1');
    expect(rejection(opus)).toBe('AUDIO_INVALID');
    // A zero timescale cannot give a duration.
    const zero = Buffer.from(mono);
    zero.writeUInt32BE(0, zero.indexOf(Buffer.from('mvhd')) + 16);
    expect(rejection(zero)).toBe('AUDIO_INVALID');
  });

  it('accepts harmless trailing boxes and never reads outside the buffer', () => {
    const padded = Buffer.concat([mono, Buffer.from([0, 0, 0, 8]), Buffer.from('free', 'latin1')]);
    expect(rejection(padded)).toBe('accepted');
    // Every truncation point either parses or is rejected cleanly (no RangeError).
    for (let length = 0; length < mono.length; length += 97) {
      expect(['AUDIO_INVALID', 'accepted']).toContain(rejection(mono.subarray(0, length)));
    }
  });
});
