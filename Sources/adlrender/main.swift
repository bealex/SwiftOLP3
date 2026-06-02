//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  adlrender — render a Westwood .ADL track to a 44.1 kHz stereo WAV.
//
//  Usage: adlrender <file.adl> <subsong> <seconds> <out.wav>
//
//  Drives WestwoodADL's ADLPlayer at its 72 Hz tick rate into a SwiftOPL3
//  OPL3Chip and writes the resampled PCM to a WAV. This is the Phase 5 "listen"
//  tool — out of the Foundation-only core, on purpose. See Plan.md §Phase 5.

import Foundation
import SwiftOPL3
import WestwoodADL

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 5,
      let subsong = Int(args[2]),
      let seconds = Double(args[3])
else {
    fail("usage: adlrender <file.adl> <subsong> <seconds> <out.wav>")
}

let inPath = args[1]
let outPath = args[4]
let sampleRate: UInt32 = 44_100

guard let data = try? Data(contentsOf: URL(fileURLWithPath: inPath)) else {
    fail("cannot read \(inPath)")
}

let chip = OPL3Chip(sampleRate: sampleRate)
let player = ADLPlayer(chip: chip)
guard player.load(data) else {
    fail("not a valid .ADL: \(inPath)")
}

player.rewind(subsong: subsong)

let refresh = player.refreshRate                       // 72 Hz
let totalTicks = Int((seconds * refresh).rounded())
var samples: [Int16] = []
samples.reserveCapacity(Int(seconds * Double(sampleRate)) * 2 + 4)

var emitted = 0
for t in 0 ..< totalTicks {
    _ = player.update()
    // Emit chip samples up to this tick's 44.1 kHz boundary (fractional 612.5/tick).
    let target = (t + 1) * Int(sampleRate) / Int(refresh)
    while emitted < target {
        let s = chip.generateResampled()
        samples.append(s.left)
        samples.append(s.right)
        emitted += 1
    }
}

// Peak / RMS report.
var peak: Int32 = 0
var sumSq: Double = 0
for v in samples {
    peak = max(peak, abs(Int32(v)))
    sumSq += Double(v) * Double(v)
}
let rms = samples.isEmpty ? 0 : (sumSq / Double(samples.count)).squareRoot()

// --- WAV (PCM int16 LE, stereo) ---
let channels = 2
let bitsPerSample = 16
let byteRate = Int(sampleRate) * channels * bitsPerSample / 8
let blockAlign = channels * bitsPerSample / 8
let dataBytes = samples.count * 2

var wav = Data()
func u32(_ v: Int) -> Data { var x = UInt32(v).littleEndian; return Data(bytes: &x, count: 4) }
func u16(_ v: Int) -> Data { var x = UInt16(v).littleEndian; return Data(bytes: &x, count: 2) }

wav.append(Data("RIFF".utf8))
wav.append(u32(36 + dataBytes))
wav.append(Data("WAVE".utf8))
wav.append(Data("fmt ".utf8))
wav.append(u32(16))                 // fmt chunk size
wav.append(u16(1))                  // PCM
wav.append(u16(channels))
wav.append(u32(Int(sampleRate)))
wav.append(u32(byteRate))
wav.append(u16(blockAlign))
wav.append(u16(bitsPerSample))
wav.append(Data("data".utf8))
wav.append(u32(dataBytes))
samples.withUnsafeBytes { raw in
    wav.append(raw.bindMemory(to: UInt8.self))
}

do {
    try wav.write(to: URL(fileURLWithPath: outPath))
} catch {
    fail("cannot write \(outPath): \(error)")
}

let frames = samples.count / 2
print("wrote \(outPath): \(frames) frames (\(String(format: "%.1f", Double(frames) / Double(sampleRate)))s) "
    + "peak=\(peak) rms=\(String(format: "%.0f", rms))")
