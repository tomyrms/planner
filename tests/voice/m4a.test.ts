import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';
import { AudioRejected, inspectM4a } from '../../src/modules/voice/index.js';

// Real AAC files written by ffmpeg (3 s, 440 Hz): the iPhone records the same container.
const mono = readFileSync(new URL('../fixtures/audio/tone-3s-mono.m4a', import.meta.url));
const stereo = readFileSync(new URL('../fixtures/audio/tone-3s-stereo.m4a', import.meta.url));

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

describe('M4A structural check', () => {
  it('accepts a mono AAC recording and reads its duration from the file', () => {
    expect(inspectM4a(mono, 3000)).toEqual({ durationMs: 3000, channels: 1, codec: 'mp4a', brand: 'M4A ' });
    // The declared duration may differ by up to 1.5 s (recorder rounding).
    expect(inspectM4a(mono, 4500).durationMs).toBe(3000);
    expect(inspectM4a(mono, 1500).durationMs).toBe(3000);
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
