//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing
@testable import SwiftOPL3

// Register-write decoding parity — drives OPL3_WriteReg (opl3.c:1362) and the
// slot/channel write functions, asserting the decoded register fields and the
// high-bank / key-on / 4-op / rhythm side effects match Nuked.

@Suite("OPL3 register writes — Nuked-OPL3 parity")
struct OPL3RegisterTests {

    @Test("0x20 slot write: am/vib/egt/ksr/mult")
    func write20() {
        let chip = OPL3Chip()
        chip.write(0x20, 0xE5)   // 1110_0101
        #expect(chip.slot[0].trem == .tremolo)
        #expect(chip.slot[0].regVib == 1)
        #expect(chip.slot[0].regType == 1)
        #expect(chip.slot[0].regKsr == 0)
        #expect(chip.slot[0].regMult == 5)
        // reg 0x21 → ad_slot[1] = slot 1; 0x28 → ad_slot[8] = slot 6.
        chip.write(0x28, 0x00)
        #expect(chip.slot[6].trem == .zero)
    }

    @Test("0x40 ksl/tl + 0x60 ar/dr + 0x80 sl/rr (sl=0x0f promotes to 0x1f)")
    func write40_60_80() {
        let chip = OPL3Chip()
        chip.write(0x40, 0xC5)
        #expect(chip.slot[0].regKsl == 3)
        #expect(chip.slot[0].regTl == 5)

        chip.write(0x60, 0x9A)
        #expect(chip.slot[0].regAr == 9)
        #expect(chip.slot[0].regDr == 0xA)

        chip.write(0x80, 0xF3)
        #expect(chip.slot[0].regSl == 0x1f)   // 0x0f promoted
        #expect(chip.slot[0].regRr == 3)
        chip.write(0x80, 0x73)
        #expect(chip.slot[0].regSl == 7)
    }

    @Test("0xE0 waveform masks to 0x03 in OPL2 mode, full 0x07 once newm set")
    func writeE0() {
        let chip = OPL3Chip()
        chip.write(0xE0, 0x07)
        #expect(chip.slot[0].regWf == 3)      // newm == 0 → &= 0x03
        chip.write(0x105, 0x01)               // newm = 1
        chip.write(0xE0, 0x07)
        #expect(chip.slot[0].regWf == 7)
    }

    @Test("high bank (reg | 0x100) targets slots 18..35 / channels 9..17")
    func highBank() {
        let chip = OPL3Chip()
        chip.write(0x120, 0xE5)               // ad_slot[0]=0, high=1 → slot 18
        #expect(chip.slot[18].regMult == 5)
        #expect(chip.slot[0].regMult == 0)    // low bank untouched
    }

    @Test("0xA0/0xB0 f_num, block, ksv")
    func writeA0_B0() {
        let chip = OPL3Chip()
        chip.write(0xA0, 0xAA)
        chip.write(0xB0, 0x13)                // fnum_hi=3, block=4, no key-on
        #expect(chip.channel[0].fNum == 0x3AA)
        #expect(chip.channel[0].block == 4)
        // ksv = (block<<1) | ((fnum >> 9) & 1) = 8 | 1 = 9
        #expect(chip.channel[0].ksv == 9)
    }

    @Test("0xB0 key-on bit drives the envelope key")
    func keyOnOff() {
        let chip = OPL3Chip()
        chip.write(0xB0, 0x20)                // key-on
        #expect(chip.slot[0].key == OPL3Const.egkNorm)
        #expect(chip.slot[3].key == OPL3Const.egkNorm)
        chip.write(0xB0, 0x00)                // key-off
        #expect(chip.slot[0].key == 0)
        #expect(chip.slot[3].key == 0)
    }

    @Test("0xC0 fb/con + stereo panning (compat vs newm)")
    func writeC0() {
        let chip = OPL3Chip()
        chip.write(0xC0, 0x0E)                // fb=7, con=0, OPL2 mode
        #expect(chip.channel[0].fb == 7)
        #expect(chip.channel[0].con == 0)
        #expect(chip.channel[0].cha == 0xffff)
        #expect(chip.channel[0].chb == 0xffff)
        #expect(chip.channel[0].chc == 0)
        #expect(chip.channel[0].chd == 0)

        chip.write(0x105, 0x01)               // newm = 1
        chip.write(0xC0, 0xC1)                // con=1, bits 6,7 set (chc/chd), 4,5 clear
        #expect(chip.channel[0].con == 1)
        #expect(chip.channel[0].cha == 0)
        #expect(chip.channel[0].chb == 0)
        #expect(chip.channel[0].chc == 0xffff)
        #expect(chip.channel[0].chd == 0xffff)
    }

    @Test("0x08 NTS, 0x105 newm")
    func modeBits() {
        let chip = OPL3Chip()
        chip.write(0x08, 0x40)
        #expect(chip.nts == 1)
        chip.write(0x105, 0x01)
        #expect(chip.newm == 1)
    }

    @Test("0x104 4-op enable sets channel pair types")
    func set4Op() {
        let chip = OPL3Chip()
        chip.write(0x105, 0x01)               // newm
        chip.write(0x104, 0x01)               // enable 4-op on pair 0
        #expect(chip.channel[0].chtype == OPL3Const.ch4op)
        #expect(chip.channel[3].chtype == OPL3Const.ch4op2)
        chip.write(0x104, 0x00)               // back to 2-op
        #expect(chip.channel[0].chtype == OPL3Const.ch2op)
        #expect(chip.channel[3].chtype == OPL3Const.ch2op)
    }

    @Test("0xBD rhythm mode: chtype, tremolo/vib shift")
    func rhythm() {
        let chip = OPL3Chip()
        chip.write(0xBD, 0x20)                // rhythm enable, depth bits clear
        #expect(chip.rhy == 0x20)
        #expect(chip.channel[6].chtype == OPL3Const.chDrum)
        #expect(chip.channel[7].chtype == OPL3Const.chDrum)
        #expect(chip.channel[8].chtype == OPL3Const.chDrum)
        #expect(chip.tremoloshift == 4)       // (((0>>7? no)…) → ((0^1)<<1)+2 = 4
        #expect(chip.vibshift == 1)

        chip.write(0xBD, 0xC0)                // tremolo+vib depth bits set, rhythm off
        #expect(chip.rhy == 0)
        #expect(chip.channel[6].chtype == OPL3Const.ch2op)
        #expect(chip.tremoloshift == 2)
        #expect(chip.vibshift == 0)
    }

    @Test("rhythm BD key-on routes the drum envelope key")
    func rhythmBassDrum() {
        let chip = OPL3Chip()
        chip.write(0xBD, 0x20 | 0x10)         // rhythm + bass drum
        // BD = channel 6 both slots keyed with egk_drum.
        let s0 = chip.channel[6].slotz.0
        let s1 = chip.channel[6].slotz.1
        #expect(chip.slot[s0].key & OPL3Const.egkDrum != 0)
        #expect(chip.slot[s1].key & OPL3Const.egkDrum != 0)
    }
}
