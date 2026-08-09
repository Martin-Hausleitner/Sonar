#!/usr/bin/env swift
// Decode Sonar AudioFrames captured from the simulator relay back to PCM.
//
// Input: wiretap JSON from scripts/e2e/relay_wiretap.py
//        (frames: [{from, seq, wireDataBase64}, ...])
// For one --source device it:
//   1. parses the AudioFrame wire format (4B seq BE + 8B ts BE + 1B codec + Opus payload)
//   2. decodes each Opus payload with AVAudioConverter (kAudioFormatOpus, same
//      codec family the app itself uses — 48 kHz mono, 10 ms frames)
//   3. writes the concatenated PCM to a WAV file
//   4. prints per-run stats (frames, decode failures, overall RMS)
//
// Runs on macOS with plain `swift <script>` — no app target needed.

import AVFoundation
import Foundation

struct WiretapFrame: Decodable {
    let from: String
    let seq: UInt32
    let wireDataBase64: String
}

struct WiretapDump: Decodable {
    let frames: [WiretapFrame]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var sourceFilter: String?
var inputPath: String?
var outputPath: String?

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--source": sourceFilter = iterator.next()
    case "--in": inputPath = iterator.next()
    case "--out": outputPath = iterator.next()
    default: fail("unknown argument: \(argument)")
    }
}

guard let inputPath, let outputPath, let sourceFilter else {
    fail("usage: decode_relay_frames.swift --in wiretap.json --source <deviceID> --out out.wav")
}

guard let dumpData = FileManager.default.contents(atPath: inputPath) else {
    fail("cannot read \(inputPath)")
}
let dump = try JSONDecoder().decode(WiretapDump.self, from: dumpData)
let frames = dump.frames.filter { $0.from == sourceFilter }.sorted { $0.seq < $1.seq }
guard !frames.isEmpty else {
    fail("no frames from source \(sourceFilter)")
}

let sampleRate = 48_000.0
let samplesPerFrame = AVAudioFrameCount(480) // 10 ms @ 48 kHz, LatencyBudget.audioFrameMs

let pcmFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
)!
var opusDescription = AudioStreamBasicDescription()
opusDescription.mSampleRate = sampleRate
opusDescription.mFormatID = kAudioFormatOpus
opusDescription.mChannelsPerFrame = 1
opusDescription.mFramesPerPacket = UInt32(samplesPerFrame)
let opusFormat = AVAudioFormat(streamDescription: &opusDescription)!

guard let decoder = AVAudioConverter(from: opusFormat, to: pcmFormat) else {
    fail("cannot create Opus decoder (AVAudioConverter)")
}

let outputURL = URL(fileURLWithPath: outputPath)
let wav = try AVAudioFile(
    forWriting: outputURL,
    settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
    ],
    commonFormat: .pcmFormatFloat32,
    interleaved: false
)

var decoded = 0
var failed = 0
var badWire = 0
var sumSquares = 0.0
var totalSamples = 0
var peak: Float = 0

for wireFrame in frames {
    guard let wire = Data(base64Encoded: wireFrame.wireDataBase64), wire.count >= 13 else {
        badWire += 1
        continue
    }
    let payload = wire.subdata(in: 13 ..< wire.count)

    let compressed = AVAudioCompressedBuffer(
        format: opusFormat, packetCapacity: 1, maximumPacketSize: max(payload.count, 1)
    )
    compressed.packetCount = 1
    compressed.byteLength = UInt32(payload.count)
    payload.withUnsafeBytes { raw in
        compressed.data.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
    }
    if let descriptions = compressed.packetDescriptions {
        descriptions[0].mStartOffset = 0
        descriptions[0].mVariableFramesInPacket = 0
        descriptions[0].mDataByteSize = UInt32(payload.count)
    }

    guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: samplesPerFrame * 2) else {
        failed += 1
        continue
    }
    var fed = false
    var conversionError: NSError?
    let status = decoder.convert(to: pcm, error: &conversionError) { _, outStatus in
        if fed {
            outStatus.pointee = .noDataNow
            return nil
        }
        fed = true
        outStatus.pointee = .haveData
        return compressed
    }
    if status == .error || conversionError != nil || pcm.frameLength == 0 {
        failed += 1
        continue
    }
    decoded += 1
    let channel = pcm.floatChannelData![0]
    for index in 0 ..< Int(pcm.frameLength) {
        let sample = channel[index]
        sumSquares += Double(sample * sample)
        peak = max(peak, abs(sample))
    }
    totalSamples += Int(pcm.frameLength)
    try wav.write(from: pcm)
}

let rms = totalSamples > 0 ? (sumSquares / Double(totalSamples)).squareRoot() : 0
let seconds = Double(totalSamples) / sampleRate
let stats: [String: Any] = [
    "source": sourceFilter,
    "framesFromSource": frames.count,
    "decoded": decoded,
    "decodeFailures": failed,
    "badWireFrames": badWire,
    "seconds": (seconds * 1000).rounded() / 1000,
    "rms": (Double(rms) * 100_000).rounded() / 100_000,
    "peak": (Double(peak) * 100_000).rounded() / 100_000,
    "wav": outputPath,
]
let json = try JSONSerialization.data(withJSONObject: stats, options: [.sortedKeys])
print(String(data: json, encoding: .utf8)!)

if decoded == 0 { fail("no frame decoded") }
