//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3SimdDSP.swift
//  SwiftOPL3 — EXPERIMENTAL Struct-of-Arrays / SIMD synthesis fork
//  (compiled only under `-DOPL_SIMD`; mutually exclusive with OPL_FLOAT).
//
//  ⚠️  NOT a faithful transcription. Like OPL_FLOAT it is a non-bit-exact, float
//  reimplementation; on top of that it re-lays the per-sample hot-loop state as
//  Struct-of-Arrays so melodic channels can be processed as SIMD lanes. It exists
//  to measure whether "channels as SIMD lanes" beats the scalar float chip.
//
//  Design (see History/2026-06-04):
//   • The faithful AoS register/reset/routing layer is UNCHANGED and stays the
//     source of truth for configuration. It runs at register-write rate (~72 Hz
//     under the driver), not per sample, so vectorising it would buy nothing.
//   • A persistent SoA mirror (`OPL3SimdState`) holds the per-sample hot-loop
//     state. Config is synced AoS→SoA whenever a register write dirties it;
//     dynamic state (envelope, phase, outputs) is authoritative in the SoA and
//     is seeded from AoS once after each `reset`.
//   • Operators are reindexed `op = (isCarrier ? 18 : 0) + channel`, so the 18
//     modulator operators occupy indices 0..<18 and the 18 carriers 18..<36 —
//     each row contiguous, so four consecutive channels load as one SIMD4.
//   • Stage A (this file's scalar path) processes operators one at a time in the
//     exact Nuked slot order, advancing the noise LFSR per operator and keeping
//     the two-pass mix + channel-sample-delay quirk — so it is numerically
//     identical to the OPL_FLOAT chip. Stage B vectorises the melodic operators.

#if OPL_SIMD
import Foundation

/// Persistent Struct-of-Arrays hot-loop state. Operator-indexed arrays are length
/// 36 with the `row*18 + channel` layout described above; channel-indexed arrays
/// are length 18. Backed by owned `UnsafeMutableBufferPointer` (process-lifetime),
/// mirroring the chip's `slot`/`channel` storage.
final class OPL3SimdState {
    static let opCount = 36
    static let chanCount = 18

    // Per-operator dynamic state (authoritative here; seeded from AoS at reset).
    let out: UnsafeMutableBufferPointer<Float>
    let fbmod: UnsafeMutableBufferPointer<Float>
    let prout: UnsafeMutableBufferPointer<Float>
    let egRout: UnsafeMutableBufferPointer<UInt16>
    let egGen: UnsafeMutableBufferPointer<UInt8>
    let egOut: UnsafeMutableBufferPointer<UInt16>
    let pgPhase: UnsafeMutableBufferPointer<UInt32>
    let pgPhaseOut: UnsafeMutableBufferPointer<UInt16>
    let pgReset: UnsafeMutableBufferPointer<UInt32>

    // Per-operator configuration (synced from AoS).
    let regWf: UnsafeMutableBufferPointer<UInt8>
    let regMult: UnsafeMutableBufferPointer<UInt8>
    let regKsl: UnsafeMutableBufferPointer<UInt8>
    let regTl: UnsafeMutableBufferPointer<UInt8>
    let regAr: UnsafeMutableBufferPointer<UInt8>
    let regDr: UnsafeMutableBufferPointer<UInt8>
    let regSl: UnsafeMutableBufferPointer<UInt8>
    let regRr: UnsafeMutableBufferPointer<UInt8>
    let regType: UnsafeMutableBufferPointer<UInt8>
    let regKsr: UnsafeMutableBufferPointer<UInt8>
    let regVib: UnsafeMutableBufferPointer<UInt8>
    let key: UnsafeMutableBufferPointer<UInt8>
    let egKsl: UnsafeMutableBufferPointer<UInt8>
    let slotNum: UnsafeMutableBufferPointer<UInt8>
    let tremOn: UnsafeMutableBufferPointer<UInt8>            // 1 if trem == .tremolo
    let chanOf: UnsafeMutableBufferPointer<UInt8>            // owning channel index
    // Modulation source: kind 0=zero, 1=slot out, 2=slot fbmod; modOp = op index.
    let modKind: UnsafeMutableBufferPointer<UInt8>
    let modOp: UnsafeMutableBufferPointer<UInt8>

    // Per-channel configuration (synced from AoS).
    let fNum: UnsafeMutableBufferPointer<UInt16>
    let block: UnsafeMutableBufferPointer<UInt8>
    let fb: UnsafeMutableBufferPointer<UInt8>
    let ksv: UnsafeMutableBufferPointer<UInt8>
    let cha: UnsafeMutableBufferPointer<UInt16>
    let chb: UnsafeMutableBufferPointer<UInt16>
    let chc: UnsafeMutableBufferPointer<UInt16>
    let chd: UnsafeMutableBufferPointer<UInt16>
    // Channel output: up to four operator-index contributions; 0xFF = none.
    let outOp: UnsafeMutableBufferPointer<UInt8>             // length chanCount*4

    // Maps. opToSlot[op] = AoS slot index; slotToOp[slot] = SoA op index.
    let opToSlot: UnsafeMutableBufferPointer<UInt8>
    let slotToOp: UnsafeMutableBufferPointer<UInt8>

    private static func u8(_ n: Int) -> UnsafeMutableBufferPointer<UInt8> {
        let b = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: n); b.initialize(repeating: 0); return b
    }
    private static func u16(_ n: Int) -> UnsafeMutableBufferPointer<UInt16> {
        let b = UnsafeMutableBufferPointer<UInt16>.allocate(capacity: n); b.initialize(repeating: 0); return b
    }
    private static func u32(_ n: Int) -> UnsafeMutableBufferPointer<UInt32> {
        let b = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: n); b.initialize(repeating: 0); return b
    }
    private static func f(_ n: Int) -> UnsafeMutableBufferPointer<Float> {
        let b = UnsafeMutableBufferPointer<Float>.allocate(capacity: n); b.initialize(repeating: 0); return b
    }

    init() {
        let n = Self.opCount, c = Self.chanCount
        out = Self.f(n); fbmod = Self.f(n); prout = Self.f(n)
        egRout = Self.u16(n); egGen = Self.u8(n); egOut = Self.u16(n)
        pgPhase = Self.u32(n); pgPhaseOut = Self.u16(n); pgReset = Self.u32(n)
        regWf = Self.u8(n); regMult = Self.u8(n); regKsl = Self.u8(n); regTl = Self.u8(n)
        regAr = Self.u8(n); regDr = Self.u8(n); regSl = Self.u8(n); regRr = Self.u8(n)
        regType = Self.u8(n); regKsr = Self.u8(n); regVib = Self.u8(n); key = Self.u8(n)
        egKsl = Self.u8(n); slotNum = Self.u8(n); tremOn = Self.u8(n); chanOf = Self.u8(n)
        modKind = Self.u8(n); modOp = Self.u8(n)
        fNum = Self.u16(c); block = Self.u8(c); fb = Self.u8(c); ksv = Self.u8(c)
        cha = Self.u16(c); chb = Self.u16(c); chc = Self.u16(c); chd = Self.u16(c)
        outOp = Self.u8(c * 4)
        opToSlot = Self.u8(n); slotToOp = Self.u8(n)
    }

    deinit {
        out.deallocate(); fbmod.deallocate(); prout.deallocate()
        egRout.deallocate(); egGen.deallocate(); egOut.deallocate()
        pgPhase.deallocate(); pgPhaseOut.deallocate(); pgReset.deallocate()
        regWf.deallocate(); regMult.deallocate(); regKsl.deallocate(); regTl.deallocate()
        regAr.deallocate(); regDr.deallocate(); regSl.deallocate(); regRr.deallocate()
        regType.deallocate(); regKsr.deallocate(); regVib.deallocate(); key.deallocate()
        egKsl.deallocate(); slotNum.deallocate(); tremOn.deallocate(); chanOf.deallocate()
        modKind.deallocate(); modOp.deallocate()
        fNum.deallocate(); block.deallocate(); fb.deallocate(); ksv.deallocate()
        cha.deallocate(); chb.deallocate(); chc.deallocate(); chd.deallocate()
        outOp.deallocate(); opToSlot.deallocate(); slotToOp.deallocate()
    }
}

extension OPL3Chip {

    // MARK: - Maps and sync

    /// Builds the slot↔op index maps from the AoS routing. `op = (carrier ? 18 :
    /// 0) + channel`; a slot is a carrier when it is its channel's `slotz.1`.
    func simdBuildMaps() {
        for c in 0 ..< 18 {
            let s0 = channel[c].slotz.0
            let s1 = channel[c].slotz.1
            simd.slotToOp[s0] = UInt8(c)
            simd.slotToOp[s1] = UInt8(18 + c)
            simd.opToSlot[c] = UInt8(s0)
            simd.opToSlot[18 + c] = UInt8(s1)
        }
    }

    /// Copies configuration + modulation routing AoS→SoA for every operator and
    /// channel. Dynamic state is left untouched (it lives in the SoA). Cheap and
    /// run only when a register write has dirtied the config.
    func simdSyncConfig() {
        for op in 0 ..< 36 {
            let s = Int(simd.opToSlot[op])
            simd.regWf[op] = slot[s].regWf
            simd.regMult[op] = slot[s].regMult
            simd.regKsl[op] = slot[s].regKsl
            simd.regTl[op] = slot[s].regTl
            simd.regAr[op] = slot[s].regAr
            simd.regDr[op] = slot[s].regDr
            simd.regSl[op] = slot[s].regSl
            simd.regRr[op] = slot[s].regRr
            simd.regType[op] = slot[s].regType
            simd.regKsr[op] = slot[s].regKsr
            simd.regVib[op] = slot[s].regVib
            simd.key[op] = slot[s].key
            simd.egKsl[op] = slot[s].egKsl
            simd.slotNum[op] = slot[s].slotNum
            simd.chanOf[op] = UInt8(slot[s].channel)
            switch slot[s].trem {
                case .zero: simd.tremOn[op] = 0
                case .tremolo: simd.tremOn[op] = 1
            }
            switch slot[s].mod {
                case .zero: simd.modKind[op] = 0; simd.modOp[op] = 0
                case .slotOut(let i): simd.modKind[op] = 1; simd.modOp[op] = simd.slotToOp[i]
                case .slotFbmod(let i): simd.modKind[op] = 2; simd.modOp[op] = simd.slotToOp[i]
            }
        }
        for c in 0 ..< 18 {
            simd.fNum[c] = channel[c].fNum
            simd.block[c] = channel[c].block
            simd.fb[c] = channel[c].fb
            simd.ksv[c] = channel[c].ksv
            simd.cha[c] = channel[c].cha
            simd.chb[c] = channel[c].chb
            simd.chc[c] = channel[c].chc
            simd.chd[c] = channel[c].chd
            let outs = [channel[c].out.0, channel[c].out.1, channel[c].out.2, channel[c].out.3]
            for k in 0 ..< 4 {
                switch outs[k] {
                    case .slotOut(let i): simd.outOp[c * 4 + k] = simd.slotToOp[i]
                    case .slotFbmod(let i): simd.outOp[c * 4 + k] = simd.slotToOp[i]
                    case .zero: simd.outOp[c * 4 + k] = 0xFF
                }
            }
        }
    }

    /// Seeds the SoA dynamic state from the AoS slots (called once after reset).
    func simdSeedDynamic() {
        for op in 0 ..< 36 {
            let s = Int(simd.opToSlot[op])
            simd.out[op] = slot[s].out
            simd.fbmod[op] = slot[s].fbmod
            simd.prout[op] = slot[s].prout
            simd.egRout[op] = slot[s].egRout
            simd.egGen[op] = slot[s].egGen
            simd.egOut[op] = slot[s].egOut
            simd.pgPhase[op] = slot[s].pgPhase
            simd.pgPhaseOut[op] = slot[s].pgPhaseOut
            simd.pgReset[op] = slot[s].pgReset
        }
    }

    /// Resolves any pending seed/sync before a sample is generated.
    @inline(__always)
    func simdRefresh() {
        if simdNeedsSeed {
            simdBuildMaps()
            simdSyncConfig()
            simdSeedDynamic()
            simdNeedsSeed = false
            simdDirty = false
        } else if simdDirty {
            simdBuildMaps()
            simdSyncConfig()
            simdDirty = false
        }
    }

    // MARK: - Scalar per-operator pipeline on SoA (Stage A)

    /// Resolves an operator's modulation input value from the SoA.
    @inline(__always)
    func simdModValue(_ op: Int) -> Float {
        switch simd.modKind[op] {
            case 1: return simd.out[Int(simd.modOp[op])]
            case 2: return simd.fbmod[Int(simd.modOp[op])]
            default: return 0
        }
    }

    // Port of OPL3_EnvelopeCalc (opl3.c:387) onto the SoA, byte-identical logic.
    func simdEnvelopeCalc(_ op: Int) {
        let c = Int(simd.chanOf[op])
        var regRate: UInt8 = 0
        var reset: UInt8 = 0

        let tremVal: UInt8 = simd.tremOn[op] != 0 ? tremolo : 0
        let kslShiftAmount = OPL3Tables.kslshift[Int(simd.regKsl[op])]
        simd.egOut[op] = UInt16(truncatingIfNeeded:
            UInt32(simd.egRout[op])
            &+ (UInt32(simd.regTl[op]) << 2)
            &+ (UInt32(simd.egKsl[op]) >> UInt32(kslShiftAmount))
            &+ UInt32(tremVal))

        if simd.key[op] != 0 && simd.egGen[op] == OPL3Const.envRelease {
            reset = 1
            regRate = simd.regAr[op]
        } else {
            switch simd.egGen[op] {
                case OPL3Const.envAttack: regRate = simd.regAr[op]
                case OPL3Const.envDecay: regRate = simd.regDr[op]
                case OPL3Const.envSustain:
                    if simd.regType[op] == 0 { regRate = simd.regRr[op] }
                case OPL3Const.envRelease: regRate = simd.regRr[op]
                default: break
            }
        }

        simd.pgReset[op] = UInt32(reset)
        let ks = ksvOf(c) >> ((simd.regKsr[op] ^ 1) << 1)
        let nonzero = regRate != 0
        let rate = ks &+ (regRate << 2)
        var rateHi = rate >> 2
        let rateLo = rate & 0x03
        if rateHi & 0x10 != 0 { rateHi = 0x0f }

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
                if shift & 0x04 != 0 { shift = 0x03 }
                if shift == 0 { shift = egState }
            }
        }

        var egRout = simd.egRout[op]
        var egInc: Int16 = 0
        var egOff: UInt8 = 0
        if reset != 0 && rateHi == 0x0f { egRout = 0x00 }
        if (simd.egRout[op] & 0x1f8) == 0x1f8 { egOff = 1 }
        if simd.egGen[op] != OPL3Const.envAttack && reset == 0 && egOff != 0 { egRout = 0x1ff }

        switch simd.egGen[op] {
            case OPL3Const.envAttack:
                if simd.egRout[op] == 0 {
                    simd.egGen[op] = OPL3Const.envDecay
                } else if simd.key[op] != 0 && shift > 0 && rateHi != 0x0f {
                    egInc = Int16(truncatingIfNeeded: (~Int32(simd.egRout[op])) >> Int32(4 - Int(shift)))
                }
            case OPL3Const.envDecay:
                if (simd.egRout[op] >> 4) == UInt16(simd.regSl[op]) {
                    simd.egGen[op] = OPL3Const.envSustain
                } else if egOff == 0 && reset == 0 && shift > 0 {
                    egInc = Int16(1 << Int(shift - 1))
                }
            case OPL3Const.envSustain, OPL3Const.envRelease:
                if egOff == 0 && reset == 0 && shift > 0 {
                    egInc = Int16(1 << Int(shift - 1))
                }
            default: break
        }

        simd.egRout[op] = UInt16(truncatingIfNeeded: (Int32(egRout) + Int32(egInc)) & 0x1ff)
        if reset != 0 { simd.egGen[op] = OPL3Const.envAttack }
        if simd.key[op] == 0 { simd.egGen[op] = OPL3Const.envRelease }
    }

    /// Channel KSV — read from the AoS channel (config; unchanged by the hot loop).
    @inline(__always)
    func ksvOf(_ c: Int) -> UInt8 { channel[c].ksv }

    // Port of OPL3_PhaseGenerate (opl3.c:548) onto the SoA. Advances the noise
    // LFSR per operator exactly as the reference (so the rhythm operators see the
    // same noise at the same position).
    func simdPhaseGenerate(_ op: Int) {
        let c = Int(simd.chanOf[op])
        var fNum = simd.fNum[c]

        if simd.regVib[op] != 0 {
            var range = Int8((fNum >> 7) & 7)
            let vibpos = vibpos
            if vibpos & 3 == 0 { range = 0 }
            else if vibpos & 1 != 0 { range >>= 1 }
            range >>= vibshift
            if vibpos & 4 != 0 { range = -range }
            fNum = UInt16(truncatingIfNeeded: Int(fNum) &+ Int(range))
        }

        let basefreq = (UInt32(fNum) << UInt32(simd.block[c])) >> 1
        let phase = UInt16(truncatingIfNeeded: simd.pgPhase[op] >> 9)
        if simd.pgReset[op] != 0 { simd.pgPhase[op] = 0 }
        simd.pgPhase[op] = simd.pgPhase[op] &+ ((basefreq &* UInt32(OPL3Tables.mt[Int(simd.regMult[op])])) >> 1)

        let noise = self.noise
        simd.pgPhaseOut[op] = phase
        let sNum = simd.slotNum[op]
        if sNum == 13 {
            rmHHBit2 = UInt8((phase >> 2) & 1)
            rmHHBit3 = UInt8((phase >> 3) & 1)
            rmHHBit7 = UInt8((phase >> 7) & 1)
            rmHHBit8 = UInt8((phase >> 8) & 1)
        }
        if sNum == 17 && (rhy & 0x20) != 0 {
            rmTCBit3 = UInt8((phase >> 3) & 1)
            rmTCBit5 = UInt8((phase >> 5) & 1)
        }
        if rhy & 0x20 != 0 {
            let rmXor = (rmHHBit2 ^ rmHHBit7) | (rmHHBit3 ^ rmTCBit5) | (rmTCBit3 ^ rmTCBit5)
            switch sNum {
                case 13:
                    simd.pgPhaseOut[op] = UInt16(rmXor) << 9
                    if (UInt32(rmXor) ^ (noise & 1)) != 0 { simd.pgPhaseOut[op] |= 0xd0 }
                    else { simd.pgPhaseOut[op] |= 0x34 }
                case 16:
                    simd.pgPhaseOut[op] = UInt16(truncatingIfNeeded:
                        (UInt32(rmHHBit8) << 9) | ((UInt32(rmHHBit8) ^ (noise & 1)) << 8))
                case 17:
                    simd.pgPhaseOut[op] = (UInt16(rmXor) << 9) | 0x80
                default: break
            }
        }

        let nBit = UInt8(((noise >> 14) ^ noise) & 0x01)
        self.noise = (noise >> 1) | (UInt32(nBit) << 22)
    }

    // Port of OPL3_SlotGenerate (opl3.c:690) — float synthesis on the SoA.
    func simdSlotGenerate(_ op: Int) {
        let modVal = simdModValue(op)
        let phaseArg = Float(simd.pgPhaseOut[op]) + modVal
        let gain = OPL3FloatTables.gain[min(Int(simd.egOut[op]), 1023)]
        simd.out[op] = oplFloatWave(simd.regWf[op], phaseArg) * gain
    }

    // Port of OPL3_SlotCalcFB (opl3.c:695) — float feedback on the SoA.
    func simdSlotCalcFB(_ op: Int) {
        let c = Int(simd.chanOf[op])
        if simd.fb[c] != 0x00 {
            let sum = simd.prout[op] + simd.out[op]
            simd.fbmod[op] = sum * OPL3FloatTables.feedback[Int(simd.fb[c])]
        } else {
            simd.fbmod[op] = 0
        }
        simd.prout[op] = simd.out[op]
    }

    @inline(__always)
    func simdProcessSlot(_ s: Int) {
        let op = Int(simd.slotToOp[s])
        simdSlotCalcFB(op)
        simdEnvelopeCalc(op)
        simdPhaseGenerate(op)
        simdSlotGenerate(op)
    }

    @inline(__always)
    func simdClip(_ sample: Float) -> Int16 {
        if sample > 32767 { return 32767 }
        if sample < -32768 { return -32768 }
        return Int16(sample.rounded())
    }

    /// Sums a channel's resolved output contributions from the SoA.
    @inline(__always)
    func simdChannelAccm(_ c: Int) -> Float {
        var accm: Float = 0
        for k in 0 ..< 4 {
            let o = simd.outOp[c * 4 + k]
            if o != 0xFF { accm += simd.out[Int(o)] }
        }
        return accm
    }

    // MARK: - Stage B: branchless SIMD over melodic channel-lanes

    // Gather helpers. Indices are clamped to the array bound so a tail chunk
    // (count < 4) can over-read harmlessly; only `count` lanes are ever stored.
    @inline(__always)
    func L8(_ b: UnsafeMutableBufferPointer<UInt8>, _ i: Int, _ bnd: Int) -> SIMD4<Int32> {
        SIMD4(Int32(b[min(i, bnd)]), Int32(b[min(i + 1, bnd)]),
              Int32(b[min(i + 2, bnd)]), Int32(b[min(i + 3, bnd)]))
    }
    @inline(__always)
    func L16(_ b: UnsafeMutableBufferPointer<UInt16>, _ i: Int, _ bnd: Int) -> SIMD4<Int32> {
        SIMD4(Int32(b[min(i, bnd)]), Int32(b[min(i + 1, bnd)]),
              Int32(b[min(i + 2, bnd)]), Int32(b[min(i + 3, bnd)]))
    }
    @inline(__always)
    func LU32(_ b: UnsafeMutableBufferPointer<UInt32>, _ i: Int, _ bnd: Int) -> SIMD4<UInt32> {
        SIMD4(b[min(i, bnd)], b[min(i + 1, bnd)], b[min(i + 2, bnd)], b[min(i + 3, bnd)])
    }
    @inline(__always)
    func S16(_ b: UnsafeMutableBufferPointer<UInt16>, _ i: Int, _ v: SIMD4<Int32>, _ n: Int) {
        for l in 0 ..< n { b[i + l] = UInt16(truncatingIfNeeded: v[l]) }
    }
    @inline(__always)
    func S8(_ b: UnsafeMutableBufferPointer<UInt8>, _ i: Int, _ v: SIMD4<Int32>, _ n: Int) {
        for l in 0 ..< n { b[i + l] = UInt8(truncatingIfNeeded: v[l]) }
    }
    @inline(__always)
    func SU32(_ b: UnsafeMutableBufferPointer<UInt32>, _ i: Int, _ v: SIMD4<UInt32>, _ n: Int) {
        for l in 0 ..< n { b[i + l] = v[l] }
    }

    // Branchless SIMD port of OPL3_EnvelopeCalc (opl3.c:387) over four operators.
    // Integer math identical to the scalar version (no approximation), so the
    // envelope trajectories match bit-for-bit.
    func simdEnvVec(_ base: Int, _ count: Int) {
        let chanBase = base < 18 ? base : base - 18
        let z = SIMD4<Int32>(repeating: 0)
        let one = SIMD4<Int32>(repeating: 1)

        let egRout = L16(simd.egRout, base, 35)
        let regTl = L8(simd.regTl, base, 35)
        let egKsl = L8(simd.egKsl, base, 35)
        let regKsl = L8(simd.regKsl, base, 35)
        let tremOn = L8(simd.tremOn, base, 35)
        let key = L8(simd.key, base, 35)
        let egGen = L8(simd.egGen, base, 35)
        let regAr = L8(simd.regAr, base, 35)
        let regDr = L8(simd.regDr, base, 35)
        let regSl = L8(simd.regSl, base, 35)
        let regRr = L8(simd.regRr, base, 35)
        let regType = L8(simd.regType, base, 35)
        let regKsr = L8(simd.regKsr, base, 35)
        let ksv = L8(simd.ksv, chanBase, 17)

        let attackC = SIMD4<Int32>(repeating: Int32(OPL3Const.envAttack))
        let decayC = SIMD4<Int32>(repeating: Int32(OPL3Const.envDecay))
        let sustainC = SIMD4<Int32>(repeating: Int32(OPL3Const.envSustain))
        let releaseC = SIMD4<Int32>(repeating: Int32(OPL3Const.envRelease))

        let tremVal = SIMD4<Int32>(repeating: Int32(tremolo)).replacing(with: z, where: tremOn .== z)
        var kslShift = z
        kslShift.replace(with: SIMD4(repeating: 8), where: regKsl .== z)
        kslShift.replace(with: one, where: regKsl .== one)
        kslShift.replace(with: SIMD4(repeating: 2), where: regKsl .== SIMD4(repeating: 2))
        let egOut = egRout &+ (regTl &<< 2) &+ (egKsl &>> kslShift) &+ tremVal
        S16(simd.egOut, base, egOut, count)

        let isRelease = egGen .== releaseC
        let keyOn = key .!= z
        let resetMask = keyOn .& isRelease

        var regRate = z
        regRate.replace(with: regAr, where: egGen .== attackC)
        regRate.replace(with: regDr, where: egGen .== decayC)
        regRate.replace(with: regRr, where: (egGen .== sustainC) .& (regType .== z))
        regRate.replace(with: regRr, where: isRelease)
        regRate.replace(with: regAr, where: resetMask)

        let pgReset = z.replacing(with: one, where: resetMask)
        SU32(simd.pgReset, base, SIMD4<UInt32>(truncatingIfNeeded: pgReset), count)

        let ks = ksv &>> ((regKsr ^ one) &<< 1)
        let rate = ks &+ (regRate &<< 2)
        var rateHi = rate &>> 2
        let rateLo = rate & SIMD4(repeating: 3)
        rateHi.replace(with: SIMD4(repeating: 0x0f), where: (rateHi & SIMD4(repeating: 0x10)) .!= z)
        let egShift = rateHi &+ SIMD4(repeating: Int32(egAdd))

        var branchLo = z
        if egState != 0 {
            branchLo.replace(with: one, where: egShift .== SIMD4(repeating: 12))
            branchLo.replace(with: (rateLo &>> 1) & one, where: egShift .== SIMD4(repeating: 13))
            branchLo.replace(with: rateLo & one, where: egShift .== SIMD4(repeating: 14))
        }
        let st0 = Int32(OPL3Tables.egIncstep[0][Int(egTimerLo)])
        let st1 = Int32(OPL3Tables.egIncstep[1][Int(egTimerLo)])
        let st2 = Int32(OPL3Tables.egIncstep[2][Int(egTimerLo)])
        let st3 = Int32(OPL3Tables.egIncstep[3][Int(egTimerLo)])
        var stepV = SIMD4(repeating: st0)
        stepV.replace(with: SIMD4(repeating: st1), where: rateLo .== one)
        stepV.replace(with: SIMD4(repeating: st2), where: rateLo .== SIMD4(repeating: 2))
        stepV.replace(with: SIMD4(repeating: st3), where: rateLo .== SIMD4(repeating: 3))
        var branchHi = (rateHi & SIMD4(repeating: 3)) &+ stepV
        branchHi.replace(with: SIMD4(repeating: 3), where: (branchHi & SIMD4(repeating: 4)) .!= z)
        branchHi.replace(with: SIMD4(repeating: Int32(egState)), where: branchHi .== z)
        var shift = branchLo.replacing(with: branchHi, where: rateHi .>= SIMD4(repeating: 12))
        shift.replace(with: z, where: regRate .== z)

        var egRoutWork = egRout
        egRoutWork.replace(with: z, where: resetMask .& (rateHi .== SIMD4(repeating: 0x0f)))
        let notReset = pgReset .== z
        let notAttack = egGen .!= attackC
        let egOffMask = (egRout & SIMD4(repeating: 0x1f8)) .== SIMD4(repeating: 0x1f8)
        let notEgOff = (egRout & SIMD4(repeating: 0x1f8)) .!= SIMD4(repeating: 0x1f8)
        egRoutWork.replace(with: SIMD4(repeating: 0x1ff), where: notAttack .& notReset .& egOffMask)

        let shiftPos = shift .> z
        var egGenNew = egGen
        var egInc = z

        let attackMask = egGen .== attackC
        egGenNew.replace(with: decayC, where: attackMask .& (egRout .== z))
        let attackInc = (~egRout) &>> (SIMD4(repeating: 4) &- shift)
        egInc.replace(with: attackInc,
                      where: attackMask .& (egRout .!= z) .& keyOn .& shiftPos .& (rateHi .!= SIMD4(repeating: 0x0f)))

        let incShift = one &<< (shift &- one)
        let decayMask = egGen .== decayC
        let egRoutHi4 = egRout &>> 4
        egGenNew.replace(with: sustainC, where: decayMask .& (egRoutHi4 .== regSl))
        egInc.replace(with: incShift,
                      where: decayMask .& (egRoutHi4 .!= regSl) .& notEgOff .& notReset .& shiftPos)

        let srMask = ((egGen .== sustainC) .| isRelease) .& notEgOff .& notReset .& shiftPos
        egInc.replace(with: incShift, where: srMask)

        let egRoutNew = (egRoutWork &+ egInc) & SIMD4(repeating: 0x1ff)
        egGenNew.replace(with: attackC, where: resetMask)
        egGenNew.replace(with: releaseC, where: key .== z)
        S16(simd.egRout, base, egRoutNew, count)
        S8(simd.egGen, base, egGenNew, count)
    }

    // Branchless SIMD port of OPL3_PhaseGenerate (opl3.c:548) over four MELODIC
    // operators (no rhythm-section branch — those operators stay scalar). The
    // noise LFSR is advanced separately by the exact operator count.
    func simdPhaseVec(_ base: Int, _ count: Int) {
        let chanBase = base < 18 ? base : base - 18
        let z = SIMD4<Int32>(repeating: 0)

        let fNum = L16(simd.fNum, chanBase, 17)
        let block = L8(simd.block, chanBase, 17)
        let regVib = L8(simd.regVib, base, 35)
        let pgReset = LU32(simd.pgReset, base, 35)
        var pgPhase = LU32(simd.pgPhase, base, 35)

        var range = (fNum &>> 7) & SIMD4(repeating: 7)
        if (vibpos & 3) == 0 { range = z }
        else if (vibpos & 1) != 0 { range = range &>> 1 }
        range = range &>> SIMD4(repeating: Int32(vibshift))
        if (vibpos & 4) != 0 { range = z &- range }
        let fNumAdj = fNum.replacing(with: (fNum &+ range) & SIMD4(repeating: 0xffff), where: regVib .!= z)

        let fNumU = SIMD4<UInt32>(truncatingIfNeeded: fNumAdj)
        let blockU = SIMD4<UInt32>(truncatingIfNeeded: block)
        let basefreq = (fNumU &<< blockU) &>> 1

        let phaseOut = pgPhase &>> 9
        pgPhase.replace(with: SIMD4<UInt32>(repeating: 0), where: pgReset .!= SIMD4<UInt32>(repeating: 0))
        let mt = SIMD4<UInt32>(
            UInt32(OPL3Tables.mt[Int(simd.regMult[min(base, 35)])]),
            UInt32(OPL3Tables.mt[Int(simd.regMult[min(base + 1, 35)])]),
            UInt32(OPL3Tables.mt[Int(simd.regMult[min(base + 2, 35)])]),
            UInt32(OPL3Tables.mt[Int(simd.regMult[min(base + 3, 35)])]))
        pgPhase = pgPhase &+ ((basefreq &* mt) &>> 1)

        SU32(simd.pgPhase, base, pgPhase, count)
        for l in 0 ..< count { simd.pgPhaseOut[base + l] = UInt16(truncatingIfNeeded: phaseOut[l]) }
    }

    /// Advances the noise LFSR `times` steps (decoupled from the vectorised
    /// melodic operators, which never read it; preserves the per-operator
    /// advance count the scalar rhythm operators rely on).
    @inline(__always)
    func simdAdvanceNoise(_ times: Int) {
        var n = noise
        for _ in 0 ..< times {
            let nBit = ((n >> 14) ^ n) & 1
            n = (n >> 1) | (nBit << 22)
        }
        noise = n
    }

    /// Processes a contiguous run of `count` melodic operators (≤ a few),
    /// vectorising EG + phase in SIMD4 chunks; feedback and the waveform synthesis
    /// stay scalar per lane (the latter is an inherently per-lane table lookup).
    func simdProcessMelodicRun(_ start: Int, _ count: Int) {
        var done = 0
        while done < count {
            let base = start + done
            let n = min(4, count - done)
            for l in 0 ..< n { simdSlotCalcFB(base + l) }
            simdEnvVec(base, n)
            simdPhaseVec(base, n)
            for l in 0 ..< n { simdSlotGenerate(base + l) }
            done += n
        }
        simdAdvanceNoise(count)
    }

    @inline(__always)
    func simdMixPassA() {
        var mix0: Float = 0
        var mix1: Float = 0
        for ii in 0 ..< 18 {
            let accm = simdChannelAccm(ii)
            if simd.cha[ii] != 0 { mix0 += accm }
            if simd.chc[ii] != 0 { mix1 += accm }
        }
        mixbuff.0 = mix0
        mixbuff.2 = mix1
    }

    @inline(__always)
    func simdMixPassB() {
        var mix0: Float = 0
        var mix1: Float = 0
        for ii in 0 ..< 18 {
            let accm = simdChannelAccm(ii)
            if simd.chb[ii] != 0 { mix0 += accm }
            if simd.chd[ii] != 0 { mix1 += accm }
        }
        mixbuff.1 = mix0
        mixbuff.3 = mix1
    }

    // SoA + SIMD fork of OPL3_Generate4Ch (opl3.c:1111). Melodic operators run
    // through the vectorised pipeline; the rhythm section (channels 6–8, ops
    // 6/7/8/24/25/26) stays scalar in slot order. The two-pass mix, the slot
    // grouping and the channel-sample-delay quirk are preserved exactly; the
    // noise LFSR advances once per operator in slot order.
    func generate4Ch() -> (Int16, Int16, Int16, Int16) {
        simdRefresh()

        let buf1 = simdClip(mixbuff.1)
        let buf3 = simdClip(mixbuff.3)

        // Slots 0–14: melodic ch0–5 (both rows), then rhythm ch6–8 modulators.
        simdProcessMelodicRun(0, 6)         // ch0–5 modulators
        simdProcessMelodicRun(18, 6)        // ch0–5 carriers
        simdProcessSlot(12); simdProcessSlot(13); simdProcessSlot(14)

        simdMixPassA()

        // Slots 15–17: rhythm ch6–8 carriers.
        simdProcessSlot(15); simdProcessSlot(16); simdProcessSlot(17)

        let buf0 = simdClip(mixbuff.0)
        let buf2 = simdClip(mixbuff.2)

        // Slots 18–32: melodic ch9–17 modulators, then ch9–14 carriers.
        simdProcessMelodicRun(9, 9)         // ch9–17 modulators
        simdProcessMelodicRun(27, 6)        // ch9–14 carriers

        simdMixPassB()

        // Slots 33–35: melodic ch15–17 carriers.
        simdProcessMelodicRun(33, 3)

        if (timer & 0x3f) == 0x3f { tremolopos = (tremolopos &+ 1) % 210 }
        if tremolopos < 105 { tremolo = tremolopos >> tremoloshift }
        else { tremolo = (210 - tremolopos) >> tremoloshift }
        if (timer & 0x3ff) == 0x3ff { vibpos = (vibpos &+ 1) & 7 }
        timer = timer &+ 1

        if egState != 0 {
            var shift: UInt8 = 0
            while shift < 13 && ((egTimer >> UInt64(shift)) & 1) == 0 { shift += 1 }
            if shift > 12 { egAdd = 0 } else { egAdd = shift &+ 1 }
            egTimerLo = UInt8(egTimer & 0x3)
        }
        if egTimerrem != 0 || egState != 0 {
            if egTimer == 0xf_ffff_ffff { egTimer = 0; egTimerrem = 1 }
            else { egTimer = egTimer &+ 1; egTimerrem = 0 }
        }
        egState ^= 1

        while true {
            let cur = Int(writebufCur)
            if !(writebuf[cur].time <= writebufSamplecnt) { break }
            if writebuf[cur].reg & 0x200 == 0 { break }
            writebuf[cur].reg &= 0x1ff
            writeReg(writebuf[cur].reg, writebuf[cur].data)
            simdDirty = true
            writebufCur = (writebufCur &+ 1) % UInt32(OPL3Const.writeBufSize)
        }

        writebufSamplecnt = writebufSamplecnt &+ 1
        return (buf0, buf1, buf2, buf3)
    }
}
#endif  // OPL_SIMD
