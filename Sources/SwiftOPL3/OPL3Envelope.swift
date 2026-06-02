//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3Envelope.swift
//  SwiftOPL3 — the envelope generator state machine.
//
//  Faithful transcription of `OPL3_EnvelopeCalc` (opl3.c:387). Nuked-OPL3 v1.8,
//  commit cfedb09e.
//
//  Integer-width traps reproduced exactly:
//   • `eg_out` is summed in (promoted) `int` then narrowed to `uint16_t`.
//   • Attack increment `~slot->eg_rout >> (4 - shift)`: in C `eg_rout` (uint16)
//     promotes to `int`, `~` sets the high bits, and `>>` is an *arithmetic*
//     (sign-propagating) shift; the result narrows to `int16_t eg_inc`. We do the
//     `~`/shift in signed `Int32` and truncate to `Int16` to match bit-for-bit.
//   • The local `eg_rout` (a working copy) is distinct from the `slot.egRout`
//     field, which the switch still reads in its original (pre-update) state.

extension OPL3Chip {

    // opl3.c:387 OPL3_EnvelopeCalc
    func envelopeCalc(_ s: Int) {
        var regRate: UInt8 = 0
        var reset: UInt8 = 0

        let tremVal = tremValue(slot[s].trem)
        let kslShiftAmount = OPL3Tables.kslshift[Int(slot[s].regKsl)]
        slot[s].egOut = UInt16(truncatingIfNeeded:
            UInt32(slot[s].egRout)
            &+ (UInt32(slot[s].regTl) << 2)
            &+ (UInt32(slot[s].egKsl) >> UInt32(kslShiftAmount))
            &+ UInt32(tremVal))

        if slot[s].key != 0 && slot[s].egGen == OPL3Const.envRelease {
            reset = 1
            regRate = slot[s].regAr
        } else {
            switch slot[s].egGen {
                case OPL3Const.envAttack:
                    regRate = slot[s].regAr
                case OPL3Const.envDecay:
                    regRate = slot[s].regDr
                case OPL3Const.envSustain:
                    if slot[s].regType == 0 {
                        regRate = slot[s].regRr
                    }
                case OPL3Const.envRelease:
                    regRate = slot[s].regRr
                default:
                    break
            }
        }

        slot[s].pgReset = UInt32(reset)
        let c = slot[s].channel
        let ks = channel[c].ksv >> ((slot[s].regKsr ^ 1) << 1)
        let nonzero = regRate != 0
        let rate = ks &+ (regRate << 2)
        var rateHi = rate >> 2
        let rateLo = rate & 0x03
        if rateHi & 0x10 != 0 {
            rateHi = 0x0f
        }

        let egShift = rateHi &+ egAdd
        var shift: UInt8 = 0
        if nonzero {
            if rateHi < 12 {
                if egState != 0 {
                    switch egShift {
                        case 12: shift = 1
                        case 13: shift = (rateLo >> 1) & 0x01
                        case 14: shift = rateLo & 0x01
                        default: break
                    }
                }
            } else {
                shift = (rateHi & 0x03) &+ OPL3Tables.egIncstep[Int(rateLo)][Int(egTimerLo)]
                if shift & 0x04 != 0 {
                    shift = 0x03
                }
                if shift == 0 {
                    shift = egState
                }
            }
        }

        var egRout = slot[s].egRout
        var egInc: Int16 = 0
        var egOff: UInt8 = 0
        // Instant attack
        if reset != 0 && rateHi == 0x0f {
            egRout = 0x00
        }
        // Envelope off
        if (slot[s].egRout & 0x1f8) == 0x1f8 {
            egOff = 1
        }
        if slot[s].egGen != OPL3Const.envAttack && reset == 0 && egOff != 0 {
            egRout = 0x1ff
        }

        switch slot[s].egGen {
            case OPL3Const.envAttack:
                if slot[s].egRout == 0 {
                    slot[s].egGen = OPL3Const.envDecay
                } else if slot[s].key != 0 && shift > 0 && rateHi != 0x0f {
                    egInc = Int16(truncatingIfNeeded: (~Int32(slot[s].egRout)) >> Int32(4 - Int(shift)))
                }
            case OPL3Const.envDecay:
                if (slot[s].egRout >> 4) == UInt16(slot[s].regSl) {
                    slot[s].egGen = OPL3Const.envSustain
                } else if egOff == 0 && reset == 0 && shift > 0 {
                    egInc = Int16(1 << Int(shift - 1))
                }
            case OPL3Const.envSustain, OPL3Const.envRelease:
                if egOff == 0 && reset == 0 && shift > 0 {
                    egInc = Int16(1 << Int(shift - 1))
                }
            default:
                break
        }

        slot[s].egRout = UInt16(truncatingIfNeeded: (Int32(egRout) + Int32(egInc)) & 0x1ff)
        // Key off
        if reset != 0 {
            slot[s].egGen = OPL3Const.envAttack
        }
        if slot[s].key == 0 {
            slot[s].egGen = OPL3Const.envRelease
        }
    }
}
