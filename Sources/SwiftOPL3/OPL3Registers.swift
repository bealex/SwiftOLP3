//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3Registers.swift
//  SwiftOPL3 — the register-file layer: per-slot/-channel register writes and
//  the top-level `OPL3_WriteReg` dispatch.
//
//  Faithful transcription of the slot/channel write functions and
//  `OPL3_WriteReg` from `opl3.c` (Nuked-OPL3 v1.8, commit cfedb09e). Pointer
//  dereferences become index reads (see OPL3Types.swift). `OPL_ENABLE_STEREOEXT`
//  is 0 in our build, so the `0xd0` panning path and the `0x05` stereoext bit are
//  omitted exactly as the default C compile drops them.

extension OPL3Chip {

    // opl3.c:376 OPL3_EnvelopeUpdateKSL
    func envelopeUpdateKSL(_ s: Int) {
        let c = slot[s].channel
        let kslRomValue = Int32(OPL3Tables.kslrom[Int(channel[c].fNum >> 6)]) << 2
        let blockTerm = (Int32(0x08) - Int32(channel[c].block)) << 5
        var ksl = kslRomValue - blockTerm
        if ksl < 0 {
            ksl = 0
        }

        slot[s].egKsl = UInt8(truncatingIfNeeded: ksl)
    }

    // opl3.c:642 OPL3_SlotWrite20 (am/vib/egt/ksr/mult)
    func slotWrite20(_ s: Int, _ data: UInt8) {
        slot[s].trem = ((data >> 7) & 0x01) != 0 ? .tremolo : .zero
        slot[s].regVib = (data >> 6) & 0x01
        slot[s].regType = (data >> 5) & 0x01
        slot[s].regKsr = (data >> 4) & 0x01
        slot[s].regMult = data & 0x0f
    }

    // opl3.c:658 OPL3_SlotWrite40 (ksl/tl)
    func slotWrite40(_ s: Int, _ data: UInt8) {
        slot[s].regKsl = (data >> 6) & 0x03
        slot[s].regTl = data & 0x3f
        envelopeUpdateKSL(s)
    }

    // opl3.c:665 OPL3_SlotWrite60 (ar/dr)
    func slotWrite60(_ s: Int, _ data: UInt8) {
        slot[s].regAr = (data >> 4) & 0x0f
        slot[s].regDr = data & 0x0f
    }

    // opl3.c:671 OPL3_SlotWrite80 (sl/rr)
    func slotWrite80(_ s: Int, _ data: UInt8) {
        slot[s].regSl = (data >> 4) & 0x0f
        if slot[s].regSl == 0x0f {
            slot[s].regSl = 0x1f
        }

        slot[s].regRr = data & 0x0f
    }

    // opl3.c:681 OPL3_SlotWriteE0 (waveform)
    func slotWriteE0(_ s: Int, _ data: UInt8) {
        slot[s].regWf = data & 0x07
        if newm == 0x00 {
            slot[s].regWf &= 0x03
        }
    }

    // opl3.c:534 OPL3_EnvelopeKeyOn
    func envelopeKeyOn(_ s: Int, _ type: UInt8) {
        slot[s].key |= type
    }

    // opl3.c:539 OPL3_EnvelopeKeyOff
    func envelopeKeyOff(_ s: Int, _ type: UInt8) {
        slot[s].key &= ~type
    }

    // opl3.c:806 OPL3_ChannelWriteA0 (f_num low / ksv)
    func channelWriteA0(_ c: Int, _ data: UInt8) {
        if newm != 0 && channel[c].chtype == OPL3Const.ch4op2 {
            return
        }

        channel[c].fNum = (channel[c].fNum & 0x300) | UInt16(data)
        channel[c].ksv = (channel[c].block << 1)
                       | UInt8((channel[c].fNum >> (0x09 - UInt16(nts))) & 0x01)
        envelopeUpdateKSL(channel[c].slotz[0])
        envelopeUpdateKSL(channel[c].slotz[1])
        if newm != 0 && channel[c].chtype == OPL3Const.ch4op {
            let p = channel[c].pair
            channel[p].fNum = channel[c].fNum
            channel[p].ksv = channel[c].ksv
            envelopeUpdateKSL(channel[p].slotz[0])
            envelopeUpdateKSL(channel[p].slotz[1])
        }
    }

    // opl3.c:826 OPL3_ChannelWriteB0 (f_num high / block / ksv)
    func channelWriteB0(_ c: Int, _ data: UInt8) {
        if newm != 0 && channel[c].chtype == OPL3Const.ch4op2 {
            return
        }

        channel[c].fNum = (channel[c].fNum & 0xff) | (UInt16(data & 0x03) << 8)
        channel[c].block = (data >> 2) & 0x07
        channel[c].ksv = (channel[c].block << 1)
                       | UInt8((channel[c].fNum >> (0x09 - UInt16(nts))) & 0x01)
        envelopeUpdateKSL(channel[c].slotz[0])
        envelopeUpdateKSL(channel[c].slotz[1])
        if newm != 0 && channel[c].chtype == OPL3Const.ch4op {
            let p = channel[c].pair
            channel[p].fNum = channel[c].fNum
            channel[p].block = channel[c].block
            channel[p].ksv = channel[c].ksv
            envelopeUpdateKSL(channel[p].slotz[0])
            envelopeUpdateKSL(channel[p].slotz[1])
        }
    }

    // opl3.c:949 OPL3_ChannelUpdateAlg
    func channelUpdateAlg(_ c: Int) {
        channel[c].alg = channel[c].con
        if newm != 0 {
            if channel[c].chtype == OPL3Const.ch4op {
                let p = channel[c].pair
                channel[p].alg = 0x04 | (channel[c].con << 1) | channel[p].con
                channel[c].alg = 0x08
                channelSetupAlg(p)
            } else if channel[c].chtype == OPL3Const.ch4op2 {
                let p = channel[c].pair
                channel[c].alg = 0x04 | (channel[p].con << 1) | channel[c].con
                channel[p].alg = 0x08
                channelSetupAlg(c)
            } else {
                channelSetupAlg(c)
            }
        } else {
            channelSetupAlg(c)
        }
    }

    // opl3.c:977 OPL3_ChannelWriteC0 (fb / con / stereo)
    func channelWriteC0(_ c: Int, _ data: UInt8) {
        channel[c].fb = (data & 0x0e) >> 1
        channel[c].con = data & 0x01
        channelUpdateAlg(c)
        if newm != 0 {
            channel[c].cha = ((data >> 4) & 0x01) != 0 ? 0xffff : 0
            channel[c].chb = ((data >> 5) & 0x01) != 0 ? 0xffff : 0
            channel[c].chc = ((data >> 6) & 0x01) != 0 ? 0xffff : 0
            channel[c].chd = ((data >> 7) & 0x01) != 0 ? 0xffff : 0
        } else {
            channel[c].cha = 0xffff
            channel[c].chb = 0xffff
            // TODO: Verify on real chip if DAC2 output is disabled in compat mode
            channel[c].chc = 0
            channel[c].chd = 0
        }
    }

    // opl3.c:1015 OPL3_ChannelKeyOn
    func channelKeyOn(_ c: Int) {
        if newm != 0 {
            if channel[c].chtype == OPL3Const.ch4op {
                let p = channel[c].pair
                envelopeKeyOn(channel[c].slotz[0], OPL3Const.egkNorm)
                envelopeKeyOn(channel[c].slotz[1], OPL3Const.egkNorm)
                envelopeKeyOn(channel[p].slotz[0], OPL3Const.egkNorm)
                envelopeKeyOn(channel[p].slotz[1], OPL3Const.egkNorm)
            } else if channel[c].chtype == OPL3Const.ch2op || channel[c].chtype == OPL3Const.chDrum {
                envelopeKeyOn(channel[c].slotz[0], OPL3Const.egkNorm)
                envelopeKeyOn(channel[c].slotz[1], OPL3Const.egkNorm)
            }
        } else {
            envelopeKeyOn(channel[c].slotz[0], OPL3Const.egkNorm)
            envelopeKeyOn(channel[c].slotz[1], OPL3Const.egkNorm)
        }
    }

    // opl3.c:1039 OPL3_ChannelKeyOff
    func channelKeyOff(_ c: Int) {
        if newm != 0 {
            if channel[c].chtype == OPL3Const.ch4op {
                let p = channel[c].pair
                envelopeKeyOff(channel[c].slotz[0], OPL3Const.egkNorm)
                envelopeKeyOff(channel[c].slotz[1], OPL3Const.egkNorm)
                envelopeKeyOff(channel[p].slotz[0], OPL3Const.egkNorm)
                envelopeKeyOff(channel[p].slotz[1], OPL3Const.egkNorm)
            } else if channel[c].chtype == OPL3Const.ch2op || channel[c].chtype == OPL3Const.chDrum {
                envelopeKeyOff(channel[c].slotz[0], OPL3Const.egkNorm)
                envelopeKeyOff(channel[c].slotz[1], OPL3Const.egkNorm)
            }
        } else {
            envelopeKeyOff(channel[c].slotz[0], OPL3Const.egkNorm)
            envelopeKeyOff(channel[c].slotz[1], OPL3Const.egkNorm)
        }
    }

    // opl3.c:1063 OPL3_ChannelSet4Op
    func channelSet4Op(_ data: UInt8) {
        for bit in 0 ..< 6 {
            var chnum = bit
            if bit >= 3 {
                chnum += 9 - 3
            }

            if (data >> bit) & 0x01 != 0 {
                channel[chnum].chtype = OPL3Const.ch4op
                channel[chnum + 3].chtype = OPL3Const.ch4op2
                channelUpdateAlg(chnum)
            } else {
                channel[chnum].chtype = OPL3Const.ch2op
                channel[chnum + 3].chtype = OPL3Const.ch2op
                channelUpdateAlg(chnum)
                channelUpdateAlg(chnum + 3)
            }
        }
    }

    // opl3.c:714 OPL3_ChannelUpdateRhythm
    func channelUpdateRhythm(_ data: UInt8) {
        rhy = data & 0x3f
        if rhy & 0x20 != 0 {
            let c6 = 6, c7 = 7, c8 = 8
            channel[c6].out = [ .slotOut(channel[c6].slotz[1]), .slotOut(channel[c6].slotz[1]), .zero, .zero ]
            channel[c7].out = [
                .slotOut(channel[c7].slotz[0]), .slotOut(channel[c7].slotz[0]),
                .slotOut(channel[c7].slotz[1]), .slotOut(channel[c7].slotz[1]),
            ]
            channel[c8].out = [
                .slotOut(channel[c8].slotz[0]), .slotOut(channel[c8].slotz[0]),
                .slotOut(channel[c8].slotz[1]), .slotOut(channel[c8].slotz[1]),
            ]
            for chnum in 6 ..< 9 {
                channel[chnum].chtype = OPL3Const.chDrum
            }

            channelSetupAlg(c6)
            channelSetupAlg(c7)
            channelSetupAlg(c8)
            // hh
            if rhy & 0x01 != 0 {
                envelopeKeyOn(channel[c7].slotz[0], OPL3Const.egkDrum)
            } else {
                envelopeKeyOff(channel[c7].slotz[0], OPL3Const.egkDrum)
            }
            // tc
            if rhy & 0x02 != 0 {
                envelopeKeyOn(channel[c8].slotz[1], OPL3Const.egkDrum)
            } else {
                envelopeKeyOff(channel[c8].slotz[1], OPL3Const.egkDrum)
            }
            // tom
            if rhy & 0x04 != 0 {
                envelopeKeyOn(channel[c8].slotz[0], OPL3Const.egkDrum)
            } else {
                envelopeKeyOff(channel[c8].slotz[0], OPL3Const.egkDrum)
            }
            // sd
            if rhy & 0x08 != 0 {
                envelopeKeyOn(channel[c7].slotz[1], OPL3Const.egkDrum)
            } else {
                envelopeKeyOff(channel[c7].slotz[1], OPL3Const.egkDrum)
            }
            // bd
            if rhy & 0x10 != 0 {
                envelopeKeyOn(channel[c6].slotz[0], OPL3Const.egkDrum)
                envelopeKeyOn(channel[c6].slotz[1], OPL3Const.egkDrum)
            } else {
                envelopeKeyOff(channel[c6].slotz[0], OPL3Const.egkDrum)
                envelopeKeyOff(channel[c6].slotz[1], OPL3Const.egkDrum)
            }
        } else {
            for chnum in 6 ..< 9 {
                channel[chnum].chtype = OPL3Const.ch2op
                channelSetupAlg(chnum)
                envelopeKeyOff(channel[chnum].slotz[0], OPL3Const.egkDrum)
                envelopeKeyOff(channel[chnum].slotz[1], OPL3Const.egkDrum)
            }
        }
    }

    // opl3.c:1362 OPL3_WriteReg
    func writeReg(_ reg: UInt16, _ v: UInt8) {
        let high = Int((reg >> 8) & 0x01)
        let regm = Int(reg & 0xff)
        switch regm & 0xf0 {
            case 0x00:
                if high != 0 {
                    switch regm & 0x0f {
                        case 0x04: channelSet4Op(v)
                        case 0x05: newm = v & 0x01
                        default: break
                    }
                } else {
                    switch regm & 0x0f {
                        case 0x08: nts = (v >> 6) & 0x01
                        default: break
                    }
                }
            case 0x20, 0x30:
                let a = OPL3Tables.adSlot[regm & 0x1f]
                if a >= 0 { slotWrite20(18 * high + Int(a), v) }
            case 0x40, 0x50:
                let a = OPL3Tables.adSlot[regm & 0x1f]
                if a >= 0 { slotWrite40(18 * high + Int(a), v) }
            case 0x60, 0x70:
                let a = OPL3Tables.adSlot[regm & 0x1f]
                if a >= 0 { slotWrite60(18 * high + Int(a), v) }
            case 0x80, 0x90:
                let a = OPL3Tables.adSlot[regm & 0x1f]
                if a >= 0 { slotWrite80(18 * high + Int(a), v) }
            case 0xe0, 0xf0:
                let a = OPL3Tables.adSlot[regm & 0x1f]
                if a >= 0 { slotWriteE0(18 * high + Int(a), v) }
            case 0xa0:
                if (regm & 0x0f) < 9 {
                    channelWriteA0(9 * high + (regm & 0x0f), v)
                }
            case 0xb0:
                if regm == 0xbd && high == 0 {
                    tremoloshift = (((v >> 7) ^ 1) << 1) + 2
                    vibshift = ((v >> 6) & 0x01) ^ 1
                    channelUpdateRhythm(v)
                } else if (regm & 0x0f) < 9 {
                    let c = 9 * high + (regm & 0x0f)
                    channelWriteB0(c, v)
                    if v & 0x20 != 0 {
                        channelKeyOn(c)
                    } else {
                        channelKeyOff(c)
                    }
                }
            case 0xc0:
                if (regm & 0x0f) < 9 {
                    channelWriteC0(9 * high + (regm & 0x0f), v)
                }
            default:
                break
        }
    }
}
