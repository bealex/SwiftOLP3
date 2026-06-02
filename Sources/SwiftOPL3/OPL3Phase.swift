//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3Phase.swift
//  SwiftOPL3 — phase generator, waveform slot output, feedback, and the
//  per-slot processing pipeline.
//
//  Faithful transcription of `OPL3_PhaseGenerate` (opl3.c:548),
//  `OPL3_SlotGenerate` (opl3.c:690), `OPL3_SlotCalcFB` (opl3.c:695),
//  `OPL3_ProcessSlot` (opl3.c:1103) and `OPL3_ClipSample` (opl3.c:1090).
//  Nuked-OPL3 v1.8, commit cfedb09e.
//
//  Integer-width traps reproduced exactly:
//   • `range` is `int8_t` and may go negative for vibrato; `f_num += range`
//     wraps in `uint16_t`.
//   • `basefreq = (f_num << block) >> 1` overflows 16 bits (block up to 7), so it
//     is computed in `UInt32` exactly as C promotes to `int`/`uint32_t`.
//   • `pg_phase` accumulates and wraps in `UInt32`; the noise LFSR feeds bit 22.
//   • Feedback `(prout + out) >> (9 - fb)` is a signed arithmetic shift.

extension OPL3Chip {

    // opl3.c:548 OPL3_PhaseGenerate
    func phaseGenerate(_ s: Int) {
        let c = slot[s].channel
        var fNum = channel[c].fNum

        if slot[s].regVib != 0 {
            var range = Int8((fNum >> 7) & 7)
            let vibpos = vibpos
            if vibpos & 3 == 0 {
                range = 0
            } else if vibpos & 1 != 0 {
                range >>= 1
            }

            range >>= vibshift
            if vibpos & 4 != 0 {
                range = -range
            }

            fNum = UInt16(truncatingIfNeeded: Int(fNum) &+ Int(range))
        }

        let basefreq = (UInt32(fNum) << UInt32(channel[c].block)) >> 1
        let phase = UInt16(truncatingIfNeeded: slot[s].pgPhase >> 9)
        if slot[s].pgReset != 0 {
            slot[s].pgPhase = 0
        }

        slot[s].pgPhase = slot[s].pgPhase &+ ((basefreq &* UInt32(OPL3Tables.mt[Int(slot[s].regMult)])) >> 1)
        // Rhythm mode
        let noise = self.noise
        slot[s].pgPhaseOut = phase
        if slot[s].slotNum == 13 {  // hh
            rmHHBit2 = UInt8((phase >> 2) & 1)
            rmHHBit3 = UInt8((phase >> 3) & 1)
            rmHHBit7 = UInt8((phase >> 7) & 1)
            rmHHBit8 = UInt8((phase >> 8) & 1)
        }

        if slot[s].slotNum == 17 && (rhy & 0x20) != 0 {  // tc
            rmTCBit3 = UInt8((phase >> 3) & 1)
            rmTCBit5 = UInt8((phase >> 5) & 1)
        }

        if rhy & 0x20 != 0 {
            let rmXor = (rmHHBit2 ^ rmHHBit7)
                      | (rmHHBit3 ^ rmTCBit5)
                      | (rmTCBit3 ^ rmTCBit5)
            switch slot[s].slotNum {
                case 13:  // hh
                    slot[s].pgPhaseOut = UInt16(rmXor) << 9
                    if (UInt32(rmXor) ^ (noise & 1)) != 0 {
                        slot[s].pgPhaseOut |= 0xd0
                    } else {
                        slot[s].pgPhaseOut |= 0x34
                    }
                case 16:  // sd
                    slot[s].pgPhaseOut = UInt16(truncatingIfNeeded:
                        (UInt32(rmHHBit8) << 9) | ((UInt32(rmHHBit8) ^ (noise & 1)) << 8))
                case 17:  // tc
                    slot[s].pgPhaseOut = (UInt16(rmXor) << 9) | 0x80
                default:
                    break
            }
        }

        let nBit = UInt8(((noise >> 14) ^ noise) & 0x01)
        self.noise = (noise >> 1) | (UInt32(nBit) << 22)
    }

    // opl3.c:690 OPL3_SlotGenerate
    func slotGenerate(_ s: Int) {
        let modVal = sample(at: slot[s].mod)
        let phaseArg = UInt16(truncatingIfNeeded: Int(slot[s].pgPhaseOut) &+ Int(modVal))
        slot[s].out = OPL3Waveforms.envelopeSin[Int(slot[s].regWf)](phaseArg, slot[s].egOut)
    }

    // opl3.c:695 OPL3_SlotCalcFB
    func slotCalcFB(_ s: Int) {
        let c = slot[s].channel
        if channel[c].fb != 0x00 {
            let sum = Int32(slot[s].prout) + Int32(slot[s].out)
            slot[s].fbmod = Int16(truncatingIfNeeded: sum >> Int32(0x09 - Int(channel[c].fb)))
        } else {
            slot[s].fbmod = 0
        }

        slot[s].prout = slot[s].out
    }

    // opl3.c:1103 OPL3_ProcessSlot
    func processSlot(_ s: Int) {
        slotCalcFB(s)
        envelopeCalc(s)
        phaseGenerate(s)
        slotGenerate(s)
    }

    // opl3.c:1090 OPL3_ClipSample
    @inline(__always)
    func clipSample(_ sample: Int32) -> Int16 {
        var sample = sample
        if sample > 32767 {
            sample = 32767
        } else if sample < -32768 {
            sample = -32768
        }

        return Int16(truncatingIfNeeded: sample)
    }
}
