//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing

@testable import SwiftOPL3

// Top-level generate parity — behavioural checks on OPL3_Generate / Resampled /
// Stream (opl3.c:1111+). Bit-exact PCM equality vs the Nuked C reference is the
// Phase 2 golden (Scripts/gen-chip-goldens.sh); here we lock in idle silence, an
// audible keyed note, full determinism, and the resampler/stream plumbing.

@Suite("OPL3 generate — behaviour + determinism")
struct OPL3GenerateTests {
    /// Sets up a simple sustained 2-op sine note on channel 0 (OPL2 mode) and
    /// keys it on.
    private func keyOnNote(_ chip: OPL3Chip) {
        chip.write(0x20, 0x21)  // slot0: mult=1, EGT (sustained)
        chip.write(0x23, 0x21)  // slot3 (carrier): mult=1, EGT
        chip.write(0x40, 0x10)  // slot0 TL: light modulator level
        chip.write(0x43, 0x00)  // slot3 TL: full carrier volume
        chip.write(0x60, 0xF0)  // slot0 AR=15, DR=0
        chip.write(0x63, 0xF0)  // slot3 AR=15, DR=0
        chip.write(0x80, 0x00)  // slot0 SL=0, RR=0
        chip.write(0x83, 0x00)  // slot3 SL=0, RR=0
        chip.write(0xC0, 0x00)  // fb=0, con=0 (FM)
        chip.write(0xA0, 0x98)  // f_num low
        chip.write(0xB0, 0x31)  // f_num high=1, block=4, key-on
    }

    @Test("idle chip is exactly silent")
    func idleSilence() {
        let chip = OPL3Chip()
        for _ in 0 ..< 256 {
            let s = chip.generate()
            #expect(s.left == 0)
            #expect(s.right == 0)
        }
    }

    @Test("a keyed note becomes audible")
    func audibleNote() {
        let chip = OPL3Chip()
        keyOnNote(chip)
        var peak: Int32 = 0
        for _ in 0 ..< 4_096 {
            let s = chip.generate()
            peak = max(peak, abs(Int32(s.left)))
            peak = max(peak, abs(Int32(s.right)))
        }
        #expect(peak > 1_000)
    }

    @Test("channel-sample-delay quirk: right side lags left by one sample")
    func channelSampleDelay() {
        // OPL_QUIRK_CHANNELSAMPLEDELAY is on (stereoext off): buf[1] is emitted
        // from the previous sample's mixbuff, so with cha==chb (OPL2 mode) the
        // right channel equals the *previous* sample's left channel.
        let chip = OPL3Chip()
        keyOnNote(chip)
        var previousLeft = chip.generate().left
        for _ in 0 ..< 2_048 {
            let s = chip.generate()
            #expect(s.right == previousLeft)
            previousLeft = s.left
        }
    }

    @Test("fully deterministic: identical setup ⇒ identical sample stream")
    func determinism() {
        let a = OPL3Chip()
        let b = OPL3Chip()
        keyOnNote(a)
        keyOnNote(b)
        for i in 0 ..< 1_024 {
            let sa = a.generate()
            let sb = b.generate()
            #expect(sa.left == sb.left, "left mismatch at \(i)")
            #expect(sa.right == sb.right, "right mismatch at \(i)")
        }
    }

    @Test("resampler: idle silent, note audible at 44100 Hz")
    func resampled() {
        let idle = OPL3Chip(sampleRate: 44_100)
        for _ in 0 ..< 256 {
            let s = idle.generateResampled()
            #expect(s.left == 0 && s.right == 0)
        }

        let chip = OPL3Chip(sampleRate: 44_100)
        keyOnNote(chip)
        var peak: Int32 = 0
        for _ in 0 ..< 4_096 {
            let s = chip.generateResampled()
            peak = max(peak, abs(Int32(s.left)))
        }
        #expect(peak > 1_000)
    }

    @Test("generateStream fills an interleaved buffer matching generateResampled")
    func stream() {
        let viaStream = OPL3Chip(sampleRate: 44_100)
        let viaLoop = OPL3Chip(sampleRate: 44_100)
        keyOnNote(viaStream)
        keyOnNote(viaLoop)

        let frames = 512
        var buffer = [Int16](repeating: 0, count: frames * 2)
        viaStream.generateStream(into: &buffer, frames: frames)
        for i in 0 ..< frames {
            let s = viaLoop.generateResampled()
            #expect(buffer[i * 2] == s.left)
            #expect(buffer[i * 2 + 1] == s.right)
        }
    }

    @Test("buffered writes apply through the timed queue while generating")
    func bufferedWrite() {
        let chip = OPL3Chip()
        chip.writeBuffered(0x20, 0x21)
        chip.writeBuffered(0x23, 0x21)
        chip.writeBuffered(0x40, 0x10)
        chip.writeBuffered(0x43, 0x00)
        chip.writeBuffered(0x60, 0xF0)
        chip.writeBuffered(0x63, 0xF0)
        chip.writeBuffered(0xC0, 0x00)
        chip.writeBuffered(0xA0, 0x98)
        chip.writeBuffered(0xB0, 0x31)
        var peak: Int32 = 0
        for _ in 0 ..< 8_192 {
            let s = chip.generate()
            peak = max(peak, abs(Int32(s.left)))
        }
        #expect(peak > 1_000)
    }
}
