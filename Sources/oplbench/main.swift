//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  oplbench — CPU benchmark / Instruments target for the OPL3 DSP + ADL driver.
//
//  No file I/O in the hot loop (a checksum keeps the work from being optimized
//  away), so a Time Profiler trace shows the emulator itself, not WAV writing.
//
//  Usage:
//    oplbench [seconds] [mode] [adl-file] [subsong]
//      seconds  how many seconds of audio to synthesize     (default 300)
//      mode     chip | render                                (default chip)
//      adl-file required for `render`; subsong default 2
//
//  Examples:
//    oplbench 300                              # pure chip DSP at native 49716 Hz
//    oplbench 120 render Resources/Music/DUNE8.ADL 2   # full driver→chip→44.1k
//
//  Profile in Instruments:
//    swift build -c release
//    instruments -t "Time Profiler" .build/release/oplbench 300
//  (or open Instruments, choose Time Profiler, target the built binary + args).

import Foundation
import SwiftOPL3
import WestwoodADL

let args = CommandLine.arguments
let seconds = args.count > 1 ? (Double(args[1]) ?? 300) : 300
let mode = args.count > 2 ? args[2] : "chip"

/// Sustained 2-op note on channel 0 (same patch the golden tests use).
func keyOnNote(_ chip: OPL3Chip) {
    chip.write(0x20, 0x21); chip.write(0x23, 0x21)
    chip.write(0x40, 0x10); chip.write(0x43, 0x00)
    chip.write(0x60, 0xF0); chip.write(0x63, 0xF0)
    chip.write(0x80, 0x00); chip.write(0x83, 0x00)
    chip.write(0xC0, 0x00)
    chip.write(0xA0, 0x98)
    chip.write(0xB0, 0x31)
}

func report(_ label: String, _ audioSeconds: Double, _ elapsed: Double, _ checksum: Int64) {
    let rt = elapsed > 0 ? audioSeconds / elapsed : 0
    let line = String(format: "%@: %.1fs audio in %.3fs  (%.0fx real-time)  [checksum %d]",
                      label, audioSeconds, elapsed, rt, checksum)
    print(line)
}

switch mode {
    case "render":
        guard args.count > 3, let data = try? Data(contentsOf: URL(fileURLWithPath: args[3])) else {
            FileHandle.standardError.write(Data("render mode needs a readable .ADL path\n".utf8))
            exit(2)
        }
        let subsong = args.count > 4 ? (Int(args[4]) ?? 2) : 2
        let sampleRate = 44_100
        let chip = OPL3Chip(sampleRate: UInt32(sampleRate))
        let player = ADLPlayer(chip: chip)
        guard player.load(data) else {
            FileHandle.standardError.write(Data("not a valid .ADL\n".utf8))
            exit(1)
        }
        player.rewind(subsong: subsong)

        let totalTicks = Int(seconds * player.refreshRate)
        var checksum: Int64 = 0
        var emitted = 0
        let t = Date()
        for tick in 0 ..< totalTicks {
            _ = player.update()
            let target = (tick + 1) * sampleRate / Int(player.refreshRate)
            while emitted < target {
                let s = chip.generateResampled()
                checksum &+= Int64(s.left) &+ Int64(s.right)
                emitted += 1
            }
        }
        report("render", seconds, -t.timeIntervalSinceNow, checksum)

    default:    // chip
        let chip = OPL3Chip(sampleRate: OPL3Chip.nativeSampleRate)
        keyOnNote(chip)
        let total = Int(seconds * Double(OPL3Chip.nativeSampleRate))
        var checksum: Int64 = 0
        let t = Date()
        for _ in 0 ..< total {
            let s = chip.generate()
            checksum &+= Int64(s.left) &+ Int64(s.right)
        }
        report("chip", seconds, -t.timeIntervalSinceNow, checksum)
}
