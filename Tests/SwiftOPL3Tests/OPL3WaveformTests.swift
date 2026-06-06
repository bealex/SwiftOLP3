//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing

@testable import SwiftOPL3

// Waveform / exp-converter parity. Anchor values are hand-derived directly from
// the `opl3.c` integer logic + the ported ROM tables (not from an external
// render); full bit-exact coverage arrives with the Phase 2 PCM golden.

@Suite("OPL3 waveforms — Nuked-OPL3 parity")
struct OPL3WaveformTests {
    @Test("envelopeCalcExp anchor values")
    func envelopeCalcExp() {
        // exprom[0]=0x7fa=2042 → (2042<<1)>>0 = 4084.
        #expect(OPL3Waveforms.envelopeCalcExp(0) == 4084)
        // level=0x100 → exprom[0]=2042, (2042<<1)>>1 = 2042.
        #expect(OPL3Waveforms.envelopeCalcExp(0x100) == 2042)
        // level=0xff → exprom[0xff]=0x400=1024, (1024<<1)>>0 = 2048.
        #expect(OPL3Waveforms.envelopeCalcExp(0xff) == 2048)
        // level clamps at 0x1fff → exprom[0xff]=1024, (2048)>>(0x1f=31) = 0.
        #expect(OPL3Waveforms.envelopeCalcExp(0x1fff) == 0)
        #expect(OPL3Waveforms.envelopeCalcExp(0x4000) == 0)  // > 0x1fff also clamps
    }

    @Test("sin0: peak + the 0x200 one's-complement negate")
    func sin0() {
        // phase 0: out=logsinrom[0]=0x859=2137 → exprom[2137&0xff=89]=0x645=1605,
        // (1605<<1)>>(2137>>8=8) = 3210>>8 = 12.
        #expect(OPL3Waveforms.envelopeCalcSin0(0, 0) == 12)
        // The 0x200 bit flips sign via 16-bit one's-complement: ~12 = -13.
        #expect(OPL3Waveforms.envelopeCalcSin0(0x200, 0) == Int16(truncatingIfNeeded: ~12))
        #expect(OPL3Waveforms.envelopeCalcSin0(0x200, 0) == -13)
    }

    @Test("sin6: half-wave constant + negate")
    func sin6() {
        // phase<0x200 → envelopeCalcExp(env<<3); env=0 → 4084.
        #expect(OPL3Waveforms.envelopeCalcSin6(0, 0) == 4084)
        #expect(OPL3Waveforms.envelopeCalcSin6(0x1ff, 0) == 4084)  // still in first half
        // phase>=0x200 → ~4084 = -4085.
        #expect(OPL3Waveforms.envelopeCalcSin6(0x200, 0) == -4085)
    }

    @Test("envelope_sin dispatch table: 8 entries, indexes to the right function")
    func dispatch() {
        #expect(OPL3Waveforms.envelopeSin.count == 8)
        for phase: UInt16 in [ 0, 0x80, 0x123, 0x200, 0x2ab, 0x3ff ] {
            for env: UInt16 in [ 0, 0x40, 0x1ff ] {
                #expect(OPL3Waveforms.envelopeSin[0](phase, env) == OPL3Waveforms.envelopeCalcSin0(phase, env))
                #expect(OPL3Waveforms.envelopeSin[6](phase, env) == OPL3Waveforms.envelopeCalcSin6(phase, env))
                #expect(OPL3Waveforms.envelopeSin[7](phase, env) == OPL3Waveforms.envelopeCalcSin7(phase, env))
            }
        }
    }

    @Test("max envelope drives the waveforms toward silence")
    func quietAtMaxEnvelope() {
        // envelope<<3 with envelope=0x1ff → 0xff8; exprom[0xf8]<<1 >> 15 ≈ 0.
        #expect(OPL3Waveforms.envelopeCalcSin1(0x40, 0x1ff) == 0)
        #expect(OPL3Waveforms.envelopeCalcSin2(0x40, 0x1ff) == 0)
    }
}
