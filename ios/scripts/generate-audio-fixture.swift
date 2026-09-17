// Synthetic tone, no microphone or personal audio. Exercises Apple's AAC/M4A writer.
import AVFoundation
import Foundation

guard CommandLine.arguments.count == 2 else { fatalError("Expected output path") }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let sampleRate = 22_050.0
let frames = AVAudioFrameCount(sampleRate * 3)
let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames
for index in 0..<Int(frames) {
    buffer.floatChannelData![0][index] = Float(sin(2 * .pi * 440 * Double(index) / sampleRate) * 0.2)
}
do {
    let output = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    ])
    try output.write(from: buffer)
}
let recorded = try AVAudioFile(forReading: url)
guard recorded.fileFormat.channelCount == 1 else { fatalError("Expected mono AAC") }
print("Synthetic Apple AAC: \(recorded.fileFormat.channelCount) channel, \(recorded.length) frames")
