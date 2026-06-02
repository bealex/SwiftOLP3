//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing
@testable import SwiftOPL3

// Envelope generator parity — exercises OPL3_EnvelopeCalc (opl3.c:387) directly,
// setting up slot state and the chip EG clock fields the way OPL3_Generate would,
// then asserting the eg_out sum, the state transitions, and the instant-attack /
// key-off paths.

@Suite("OPL3 envelope generator — Nuked-OPL3 parity")
struct OPL3EnvelopeTests {

    @Test("eg_out = eg_rout + (tl<<2) + (ksl>>shift) + trem")
    func egOutSum() {
        let chip = OPL3Chip()
        let s = 0
        chip.slot[s].egRout = 0x1ff
        chip.slot[s].regTl = 0x10
        chip.slot[s].regKsl = 3            // kslshift[3] = 0 → no shift
        chip.slot[s].egKsl = 0x20
        chip.slot[s].trem = .zero
        chip.slot[s].key = 0
        chip.slot[s].egGen = OPL3Const.envRelease
        chip.envelopeCalc(s)
        // 0x1ff + (0x10<<2=0x40) + 0x20 + 0 = 0x25f
        #expect(chip.slot[s].egOut == 0x25f)

        chip.slot[s].trem = .tremolo
        chip.tremolo = 5
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egOut == 0x25f + 5)
    }

    @Test("ksl shift selects by reg_ksl (kslshift = [8,1,2,0])")
    func kslShift() {
        let chip = OPL3Chip()
        let s = 0
        chip.slot[s].egRout = 0
        chip.slot[s].regTl = 0
        chip.slot[s].egKsl = 0x40
        chip.slot[s].key = 0
        chip.slot[s].egGen = OPL3Const.envRelease
        chip.slot[s].regKsl = 0            // shift 8 → 0x40>>8 = 0
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egOut == 0)
        chip.slot[s].regKsl = 1            // shift 1 → 0x40>>1 = 0x20
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egOut == 0x20)
        chip.slot[s].regKsl = 2            // shift 2 → 0x40>>2 = 0x10
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egOut == 0x10)
        chip.slot[s].regKsl = 3            // shift 0 → 0x40
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egOut == 0x40)
    }

    @Test("key-on from release with AR=0x0f, ksv=0 → instant attack (eg_rout=0), then decay")
    func instantAttack() {
        let chip = OPL3Chip()
        let s = 0
        chip.channel[chip.slot[s].channel].ksv = 0
        chip.slot[s].regKsr = 0
        chip.slot[s].regAr = 0x0f
        chip.slot[s].key = OPL3Const.egkNorm
        chip.slot[s].egGen = OPL3Const.envRelease
        chip.slot[s].egRout = 0x1ff
        chip.envelopeCalc(s)
        // reset path: rate_hi == 0x0f → eg_rout forced to 0; reset → eg_gen = attack.
        #expect(chip.slot[s].pgReset == 1)
        #expect(chip.slot[s].egRout == 0)
        #expect(chip.slot[s].egGen == OPL3Const.envAttack)
    }

    @Test("attack with eg_rout already 0 transitions to decay")
    func attackToDecay() {
        let chip = OPL3Chip()
        let s = 0
        chip.slot[s].key = OPL3Const.egkNorm
        chip.slot[s].egGen = OPL3Const.envAttack
        chip.slot[s].egRout = 0
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egGen == OPL3Const.envDecay)
    }

    @Test("decay transitions to sustain when (eg_rout>>4) == reg_sl")
    func decayToSustain() {
        let chip = OPL3Chip()
        let s = 0
        chip.slot[s].key = OPL3Const.egkNorm
        chip.slot[s].egGen = OPL3Const.envDecay
        chip.slot[s].regSl = 2
        chip.slot[s].egRout = 0x20         // 0x20 >> 4 == 2
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egGen == OPL3Const.envSustain)
    }

    @Test("key-off forces release")
    func keyOffRelease() {
        let chip = OPL3Chip()
        let s = 0
        chip.slot[s].key = 0
        chip.slot[s].egGen = OPL3Const.envAttack
        chip.slot[s].egRout = 0x100
        chip.envelopeCalc(s)
        #expect(chip.slot[s].egGen == OPL3Const.envRelease)
    }

    @Test("attack increment is the sign-extended ~eg_rout >> (4-shift)")
    func attackIncrement() {
        let chip = OPL3Chip()
        let s = 0
        // Drive a non-instant attack with shift = 1 (rate_hi in [12,15) region).
        // ksv=0, ksr=0 → ks=0; pick AR=12 → rate=48, rate_hi=12, rate_lo=0.
        chip.channel[chip.slot[s].channel].ksv = 0
        chip.slot[s].regKsr = 0
        chip.slot[s].regAr = 12
        chip.slot[s].key = OPL3Const.egkNorm
        chip.slot[s].egGen = OPL3Const.envAttack
        chip.slot[s].egRout = 0x100
        // rate_hi=12 → else-branch shift = (12&3=0) + eg_incstep[0][eg_timer_lo].
        // eg_incstep[0] = {0,0,0,0}; shift would be 0 → shift = eg_state. Force eg_state=1.
        chip.egState = 1
        chip.egTimerLo = 0
        chip.envelopeCalc(s)
        // shift=1 → eg_inc = ~0x100 >> 3 (signed) = (-257) >> 3 = -33.
        // eg_rout = (0x100 + (-33)) & 0x1ff = 256 - 33 = 223 = 0xdf.
        #expect(chip.slot[s].egRout == 0xdf)
        #expect(chip.slot[s].egGen == OPL3Const.envAttack)
    }
}
