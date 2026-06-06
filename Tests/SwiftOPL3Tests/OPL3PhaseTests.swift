//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing

@testable import SwiftOPL3

// Phase generator / slot output / feedback parity — exercises OPL3_PhaseGenerate
// (opl3.c:548), OPL3_SlotGenerate (opl3.c:690), OPL3_SlotCalcFB (opl3.c:695) and
// OPL3_ClipSample (opl3.c:1090) with hand-derived expected values.

@Suite("OPL3 phase / slot — Nuked-OPL3 parity")
struct OPL3PhaseTests {
    // clipSample / slotCalcFB / slotGenerate are the per-sample synthesis
    // functions the block-SIMD float fork replaces (OPL3BlockSimd.swift). Their
    // exact integer values only hold in the faithful build; under OPL_BLOCKSIMD
    // the float path is validated by the tolerance golden in OPL3GoldenTests.
    #if !OPL_BLOCKSIMD
        @Test("clipSample saturates to int16 range")
        func clipSample() {
            let chip = OPL3Chip()
            #expect(chip.clipSample(100) == 100)
            #expect(chip.clipSample(40_000) == 32767)
            #expect(chip.clipSample(-40_000) == -32768)
            #expect(chip.clipSample(32_767) == 32767)
            #expect(chip.clipSample(-32_768) == -32768)
        }

        @Test("slotCalcFB: fb=0 zeroes fbmod; fb!=0 is (prout+out) >> (9-fb)")
        func slotCalcFB() {
            let chip = OPL3Chip()
            let s = 0
            let c = chip.slot[s].channel
            chip.channel[c].fb = 0
            chip.slot[s].prout = 4
            chip.slot[s].out = 8
            chip.slotCalcFB(s)
            #expect(chip.slot[s].fbmod == 0)
            #expect(chip.slot[s].prout == 8)  // prout <- out

            chip.channel[c].fb = 7
            chip.slot[s].prout = 4
            chip.slot[s].out = 8
            chip.slotCalcFB(s)  // (4+8) >> (9-7=2) = 3
            #expect(chip.slot[s].fbmod == 3)
            #expect(chip.slot[s].prout == 8)
        }

        @Test("slotGenerate routes through the selected waveform")
        func slotGenerate() {
            let chip = OPL3Chip()
            let s = 0
            chip.slot[s].regWf = 0
            chip.slot[s].pgPhaseOut = 0
            chip.slot[s].mod = .zero
            chip.slot[s].egOut = 0
            chip.slotGenerate(s)
            #expect(chip.slot[s].out == 12)  // sin0(0,0) = 12

            // Modulation shifts the phase argument.
            chip.slot[s].pgPhaseOut = 0x200
            chip.slot[s].mod = .zero
            chip.slotGenerate(s)
            #expect(chip.slot[s].out == OPL3Waveforms.envelopeCalcSin0(0x200, 0))
        }
    #endif  // !OPL_BLOCKSIMD

    @Test("phase accumulation: pg_phase += (basefreq * mt[mult]) >> 1")
    func phaseAccumulation() {
        let chip = OPL3Chip()
        let s = 0
        let c = chip.slot[s].channel
        chip.channel[c].fNum = 0x200
        chip.channel[c].block = 1
        chip.slot[s].regMult = 2  // mt[2] = 4
        chip.slot[s].pgReset = 0
        chip.slot[s].pgPhase = 0
        // basefreq = (0x200<<1)>>1 = 0x200; inc = (0x200*4)>>1 = 0x400.
        chip.phaseGenerate(s)
        #expect(chip.slot[s].pgPhaseOut == 0)  // phase from pg_phase=0
        #expect(chip.slot[s].pgPhase == 0x400)
        chip.phaseGenerate(s)
        #expect(chip.slot[s].pgPhaseOut == 2)  // 0x400 >> 9 = 2
        #expect(chip.slot[s].pgPhase == 0x800)
    }

    @Test("pg_reset captures the pre-reset phase then zeroes the accumulator")
    func phaseReset() {
        let chip = OPL3Chip()
        let s = 0
        let c = chip.slot[s].channel
        chip.channel[c].fNum = 0x200
        chip.channel[c].block = 1
        chip.slot[s].regMult = 2
        chip.slot[s].pgReset = 1
        chip.slot[s].pgPhase = 0x1234
        chip.phaseGenerate(s)
        #expect(chip.slot[s].pgPhaseOut == 0x09)  // 0x1234 >> 9 = 9 (computed before reset)
        #expect(chip.slot[s].pgPhase == 0x400)  // reset to 0 then += 0x400
    }

    @Test("noise LFSR advances as (noise>>1) | (n_bit<<22)")
    func noiseLFSR() {
        let chip = OPL3Chip()
        #expect(chip.noise == 1)  // reset seed
        chip.phaseGenerate(0)
        // n_bit = ((1>>14) ^ 1) & 1 = 1; noise = (1>>1) | (1<<22) = 0x400000.
        #expect(chip.noise == 0x400000)
    }
}
