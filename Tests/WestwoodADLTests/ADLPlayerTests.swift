//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Foundation
import Testing
import SwiftOPL3
@testable import WestwoodADL

// End-to-end: a synthetic full .ADL (track table + soundData) → ADLPlayer →
// OPL3Chip → PCM. Driver trace-equivalence (ADLTraceTests) + bit-exact chip
// (OPL3GoldenTests) already prove each half; this wires them and confirms a
// keyed note renders audible, deterministic output through the public surface.

@Suite("ADLPlayer — end-to-end driver → chip → PCM")
struct ADLPlayerTests {

    private static func setLE16(_ a: inout [UInt8], _ i: Int, _ v: Int) {
        a[i] = UInt8(v & 0xFF)
        a[i + 1] = UInt8((v >> 8) & 0xFF)
    }

    /// A complete v3 file: subsong 0 → program 2, whose bytecode sets up an
    /// instrument and plays a keyed note. soundData index = fileOffset - 120.
    private static func makeFullADL() -> Data {
        var f = [UInt8](repeating: 0, count: 120 + 1200)
        f[0] = 2                                  // subsong 0 → program id 2
        for i in 1 ..< 120 { f[i] = 0xFF }
        let base = 120
        setLE16(&f, base + 2 * 2, 1000)           // program 2 → soundData offset 1000
        setLE16(&f, base + 500 + 2 * 0, 1020)     // instrument 0 (program 250) → 1020

        var p = base + 1000
        f[p] = 0; p += 1                          // channel 0
        f[p] = 16; p += 1                         // priority
        f[p] = 0x90; p += 1; f[p] = 0x00; p += 1  // setupInstrument 0
        f[p] = 0x20; p += 1; f[p] = 0x20; p += 1  // inline note 0x20, duration 0x20 (key-on)
        f[p] = 0x88                               // stopChannel

        let instr: [UInt8] = [ 0x01, 0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0xF0, 0xF0, 0x00, 0x00 ]
        for (i, b) in instr.enumerated() { f[base + 1020 + i] = b }
        return Data(f)
    }

    @Test("loads a synthetic .ADL and reports a subsong")
    func loadSucceeds() {
        let chip = OPL3Chip()
        let player = ADLPlayer(chip: chip)
        #expect(player.load(Self.makeFullADL()))
        #expect(player.subsongCount >= 1)
        #expect(player.refreshRate == 72.0)
    }

    @Test("ticking the player renders an audible note through the chip")
    func rendersAudio() {
        let chip = OPL3Chip(sampleRate: 44_100)
        let player = ADLPlayer(chip: chip)
        #expect(player.load(Self.makeFullADL()))

        // 44100 / 72 ≈ 613 chip samples per driver tick.
        let samplesPerTick = 613
        var peak: Int32 = 0
        for _ in 0 ..< 30 {
            _ = player.update()
            for _ in 0 ..< samplesPerTick {
                let s = chip.generateResampled()
                peak = max(peak, abs(Int32(s.left)))
            }
        }
        #expect(peak > 0, "expected audible output from the keyed note")
    }

    @Test("a real Dune II track (DUNE8.ADL subsong 2) renders audibly")
    func realTrackAudible() {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Music/DUNE8.ADL")
        guard let data = try? Data(contentsOf: url) else {
            return  // game asset absent — skip
        }

        let chip = OPL3Chip(sampleRate: 44_100)
        let player = ADLPlayer(chip: chip)
        #expect(player.load(data))
        player.rewind(subsong: 2)

        var peak: Int32 = 0
        for _ in 0 ..< (72 * 5) {   // ~5 seconds at 72 Hz
            _ = player.update()
            for _ in 0 ..< 612 {
                peak = max(peak, abs(Int32(chip.generateResampled().left)))
            }
        }
        #expect(peak > 1_000, "expected an audible melody from DUNE8 subsong 2")
    }

    @Test("playback is fully deterministic")
    func deterministic() {
        func render() -> [Int16] {
            let chip = OPL3Chip(sampleRate: 44_100)
            let player = ADLPlayer(chip: chip)
            _ = player.load(Self.makeFullADL())
            var out: [Int16] = []
            for _ in 0 ..< 10 {
                _ = player.update()
                for _ in 0 ..< 613 {
                    out.append(chip.generateResampled().left)
                }
            }
            return out
        }
        #expect(render() == render())
    }
}
