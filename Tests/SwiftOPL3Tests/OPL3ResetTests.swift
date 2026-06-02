//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing
@testable import SwiftOPL3

// Reset wiring — asserts OPL3_Reset (opl3.c:1293) produces the same slot/channel
// topology and resampler constants as Nuked: slot defaults, channel→slot map,
// 4-op pairing, default 2-op algorithm routing, and rateratio.

@Suite("OPL3 reset — Nuked-OPL3 parity")
struct OPL3ResetTests {

    @Test("storage sizes")
    func sizes() {
        let chip = OPL3Chip()
        #expect(chip.slot.count == 36)
        #expect(chip.channel.count == 18)
        #expect(chip.writebuf.count == 1024)
    }

    @Test("slot defaults after reset")
    func slotDefaults() {
        let chip = OPL3Chip()
        for i in 0 ..< 36 {
            #expect(chip.slot[i].egRout == 0x1ff)
            #expect(chip.slot[i].egOut == 0x1ff)
            #expect(chip.slot[i].egGen == OPL3Const.envRelease)
            #expect(chip.slot[i].trem == .zero)
            #expect(chip.slot[i].slotNum == UInt8(i))
        }
    }

    @Test("channel → slot mapping and back-reference")
    func channelSlotMap() {
        let chip = OPL3Chip()
        // chSlot[0]=0 → slotz [0,3]; chSlot[3]=6 → [6,9]; chSlot[9]=18 → [18,21].
        #expect(chip.channel[0].slotz == [ 0, 3 ])
        #expect(chip.channel[3].slotz == [ 6, 9 ])
        #expect(chip.channel[9].slotz == [ 18, 21 ])
        #expect(chip.channel[17].slotz == [ 32, 35 ])
        // slot->channel back-reference.
        #expect(chip.slot[0].channel == 0)
        #expect(chip.slot[3].channel == 0)
        #expect(chip.slot[18].channel == 9)
    }

    @Test("4-op pairing (channels 6/7/8 have no pair)")
    func pairing() {
        let chip = OPL3Chip()
        #expect(chip.channel[0].pair == 3)
        #expect(chip.channel[3].pair == 0)
        #expect(chip.channel[6].pair == -1)
        #expect(chip.channel[7].pair == -1)
        #expect(chip.channel[8].pair == -1)
        #expect(chip.channel[9].pair == 12)
        #expect(chip.channel[12].pair == 9)
    }

    @Test("default 2-op algorithm routing (alg 0)")
    func defaultRouting() {
        let chip = OPL3Chip()
        // channel 0: s0=0, s1=3. alg=0 → slot0.mod=fbmod(self), slot1.mod=slot0.out,
        // channel.out = [slot1.out, zero, zero, zero].
        #expect(chip.slot[0].mod == .slotFbmod(0))
        #expect(chip.slot[3].mod == .slotOut(0))
        #expect(chip.channel[0].out == [ .slotOut(3), .zero, .zero, .zero ])
        #expect(chip.channel[0].chtype == OPL3Const.ch2op)
        #expect(chip.channel[0].cha == 0xffff)
        #expect(chip.channel[0].chb == 0xffff)
        #expect(chip.channel[0].chc == 0)
        #expect(chip.channel[0].chd == 0)
    }

    @Test("resampler + LFO constants")
    func resamplerConstants() {
        let native = OPL3Chip(sampleRate: 49_716)
        #expect(native.rateratio == 1024)        // (49716<<10)/49716
        #expect(native.noise == 1)
        #expect(native.tremoloshift == 4)
        #expect(native.vibshift == 1)

        let cd = OPL3Chip(sampleRate: 44_100)
        #expect(cd.rateratio == 908)             // (44100<<10)/49716 = 908
    }

    @Test("source resolution helpers")
    func sourceResolution() {
        let chip = OPL3Chip()
        chip.slot[5].out = 0x1234
        chip.slot[5].fbmod = -42
        chip.tremolo = 7
        #expect(chip.sample(at: .zero) == 0)
        #expect(chip.sample(at: .slotOut(5)) == 0x1234)
        #expect(chip.sample(at: .slotFbmod(5)) == -42)
        #expect(chip.tremValue(.zero) == 0)
        #expect(chip.tremValue(.tremolo) == 7)
    }
}
