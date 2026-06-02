//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Foundation
import Testing
@testable import SwiftOPL3

// Chip golden — bit-exact PCM equality vs Nuked-OPL3. The reference C
// (References/Nuked-OPL3) is compiled by Scripts/chip_golden_harness.c, which
// replays a register script and dumps raw interleaved LE int16 stereo PCM to
// Fixtures/<name>.pcm. Nuked's DSP is integer-only, so a correct port is
// sample-for-sample identical — the golden is byte-equality, not a tolerance.
// See Documentation/Architecture/Testing.md.
//
// Each Swift `script` here must stay in lock-step with the matching C function
// in chip_golden_harness.c. Tests short-circuit (skip) when a fixture is absent
// so the suite stays green on a fresh checkout without the C reference installed.

@Suite("OPL3 chip golden — bit-exact PCM vs Nuked-OPL3")
struct OPL3GoldenTests {

    private static func w(_ chip: OPL3Chip, _ reg: UInt16, _ v: UInt8) { chip.write(reg, v) }

    // setup_sine
    private static func setupSine(_ chip: OPL3Chip) {
        w(chip, 0x20, 0x21); w(chip, 0x23, 0x21)
        w(chip, 0x40, 0x10); w(chip, 0x43, 0x00)
        w(chip, 0x60, 0xF0); w(chip, 0x63, 0xF0)
        w(chip, 0x80, 0x00); w(chip, 0x83, 0x00)
        w(chip, 0xC0, 0x00)
        w(chip, 0xA0, 0x98)
        w(chip, 0xB0, 0x31)
    }

    // setup_fourop
    private static func setupFourOp(_ chip: OPL3Chip) {
        w(chip, 0x105, 0x01)
        w(chip, 0x104, 0x01)
        let ofs: [UInt16] = [ 0x00, 0x03, 0x08, 0x0B ]
        for (i, o) in ofs.enumerated() {
            w(chip, 0x20 + o, 0x01)
            w(chip, 0x40 + o, i == 3 ? 0x00 : 0x10)
            w(chip, 0x60 + o, 0xF0)
            w(chip, 0x80 + o, 0x00)
            w(chip, 0xE0 + o, UInt8(i) & 0x07)
        }
        w(chip, 0xC0, 0x01)
        w(chip, 0xC3, 0x00)
        w(chip, 0xA0, 0x98)
        w(chip, 0xB0, 0x31)
    }

    // setup_rhythm
    private static func setupRhythm(_ chip: OPL3Chip) {
        let ofs: [UInt16] = [ 0x10, 0x13, 0x14, 0x11, 0x12, 0x15 ]
        for o in ofs {
            w(chip, 0x20 + o, 0x01)
            w(chip, 0x40 + o, 0x00)
            w(chip, 0x60 + o, 0xF0)
            w(chip, 0x80 + o, 0x00)
        }
        w(chip, 0xA6, 0x40); w(chip, 0xB6, 0x11)
        w(chip, 0xA7, 0x40); w(chip, 0xB7, 0x11)
        w(chip, 0xA8, 0x40); w(chip, 0xB8, 0x11)
        w(chip, 0xBD, 0x20 | 0x1F)
    }

    /// Renders a script to interleaved [Int16], matching the C harness exactly.
    private static func render(_ name: String) -> [Int16] {
        let total = 4_096 * 2
        var out: [Int16] = []
        out.reserveCapacity(total)

        switch name {
            case "resample_44100":
                let chip = OPL3Chip(sampleRate: 44_100)
                setupSine(chip)
                for _ in 0 ..< 4_096 {
                    let s = chip.generateResampled()
                    out.append(s.left); out.append(s.right)
                }
            case "fourop_49716":
                let chip = OPL3Chip(sampleRate: 49_716)
                setupFourOp(chip)
                for _ in 0 ..< 4_096 {
                    let s = chip.generate(); out.append(s.left); out.append(s.right)
                }
            case "rhythm_49716":
                let chip = OPL3Chip(sampleRate: 49_716)
                setupRhythm(chip)
                for _ in 0 ..< 4_096 {
                    let s = chip.generate(); out.append(s.left); out.append(s.right)
                }
            case "waveforms_49716":
                let chip = OPL3Chip(sampleRate: 49_716)
                w(chip, 0x105, 0x01)
                setupSine(chip)
                for wf in 0 ..< 8 {
                    w(chip, 0xE0, UInt8(wf))
                    w(chip, 0xE3, UInt8(wf))
                    for _ in 0 ..< (4_096 / 8) {
                        let s = chip.generate(); out.append(s.left); out.append(s.right)
                    }
                }
            default:    // sine_note_49716
                let chip = OPL3Chip(sampleRate: 49_716)
                setupSine(chip)
                for _ in 0 ..< 4_096 {
                    let s = chip.generate(); out.append(s.left); out.append(s.right)
                }
        }
        return out
    }

    private static func golden(_ name: String) -> [Int16]? {
        let url = Bundle.module.url(forResource: name, withExtension: "pcm", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "pcm")
        guard let url, let data = try? Data(contentsOf: url) else {
            return nil
        }

        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    @Test("bit-exact PCM vs Nuked", arguments: [
        "sine_note_49716", "waveforms_49716", "fourop_49716", "rhythm_49716", "resample_44100",
    ])
    func golden(_ name: String) {
        guard let golden = Self.golden(name) else {
            return  // fixture not generated on this checkout — skip
        }

        let rendered = Self.render(name)
        #expect(rendered.count == golden.count)

        var firstMismatch = -1
        for i in 0 ..< min(rendered.count, golden.count) where rendered[i] != golden[i] {
            firstMismatch = i
            break
        }
        #expect(firstMismatch == -1, "\(name): first PCM divergence at interleaved index \(firstMismatch)")
    }
}
