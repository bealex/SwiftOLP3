//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3FloatDSP.swift
//  SwiftOPL3 — EXPERIMENTAL floating-point synthesis fork (compiled only under
//  `-DOPL_FLOAT`).
//
//  ⚠️  NOT a faithful transcription. This file deliberately breaks the package's
//  "bit-exact integer port of Nuked-OPL3" rule (CLAUDE.md). It exists purely to
//  measure whether a floating-point DSP is faster on this hardware. The integer
//  path (OPL3Generate.swift / OPL3Phase.swift) is the default and is unchanged;
//  these definitions replace the per-sample synthesis arithmetic only when
//  `OPL_FLOAT` is defined, and produce *non*-bit-exact (idealized) output.
//
//  What changes vs. the integer chip, and what does NOT:
//   • UNCHANGED: register decode, the envelope-generator state machine
//     (`envelopeCalc`), the 23-bit phase accumulator (`phaseGenerate`), channel
//     routing, vibrato/tremolo/rhythm LFOs, the EG clock, and the timed write
//     buffer. All control flow stays integer and identical.
//   • CHANGED: the operator *value* path. Instead of the log-sine ROM + the
//     exponential ROM (which multiply by adding in the log domain), we compute a
//     real interpolated sine and multiply by a linear envelope gain. Modulation,
//     feedback and mixing become float adds/multiplies.
//
//  Scale is preserved so the FM chain is unaffected: an operator's full-scale
//  output is ±`fullScale` (= the integer `OPL3_EnvelopeCalcExp(0)` = exprom[0]<<1
//  = 0x7fa<<1 = 4084), and a sample is still added directly to a carrier's 10-bit
//  phase index (`pgPhaseOut + modVal`) exactly as in the integer build.

#if OPL_FLOAT || OPL_SIMD
import Foundation

/// Precomputed float tables — the float analogues of Nuked's `logsinrom`,
/// `exprom`, and the feedback / KSL shifts. Built once at first use.
///
/// They are backed by owned `UnsafeMutableBufferPointer`s (filled once, never
/// freed — process-lifetime constants) rather than Swift `[Float]`, for the same
/// reason the chip's `slot`/`channel` state is: it drops the per-lookup bounds
/// check from the hot loop. All indices are provably in range at the call sites
/// (sine: `& 1023`; gain: `min(egOut, 1023)`; feedback: fb ∈ 1…7). The buffers
/// are immutable after init, hence `nonisolated(unsafe)` is sound under strict
/// concurrency. (Measured: this recovers the bulk of the `-Ounchecked` win at a
/// plain `-O` build, without disabling safety checks everywhere else.)
enum OPL3FloatTables {

    /// Operator full-scale, matched to the integer chip: `OPL3_EnvelopeCalcExp(0)`
    /// = `(exprom[0] << 1) >> 0` = `0x7fa << 1` = 4084. Keeping the same peak
    /// amplitude makes the float output directly comparable to the Nuked golden
    /// (used by the tolerance test) and keeps phase-modulation depth identical.
    static let fullScale: Float = 4084

    /// One cycle of sine at the chip's 1024-steps-per-cycle phase resolution.
    /// Indexed by the (wrapped) integer phase; `interpSine` lerps between entries
    /// so the effective waveform is smooth ("real" float sine), not quantised.
    nonisolated(unsafe) static let sine: UnsafeMutableBufferPointer<Float> = {
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: 1024)
        for i in 0 ..< 1024 { buf[i] = Float(sin(2.0 * Double.pi * Double(i) / 1024.0)) }
        return buf
    }()

    /// Linear envelope gain for a 0…1023 attenuation index (the EG's `egOut`,
    /// clamped). `egOut` is in 1/32-octave units once the chip's `<< 3` is folded
    /// in, so gain = 2^(-egOut/32), scaled to full-scale. Mirrors the role of the
    /// exponential ROM, computed directly in float.
    nonisolated(unsafe) static let gain: UnsafeMutableBufferPointer<Float> = {
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: 1024)
        for i in 0 ..< 1024 { buf[i] = Float(exp2(-Double(i) / 32.0)) * fullScale }
        return buf
    }()

    /// Feedback scale per `fb` setting: the integer chip does `>> (9 - fb)`.
    /// `feedback[0]` is unused (fb == 0 takes the no-feedback branch).
    nonisolated(unsafe) static let feedback: UnsafeMutableBufferPointer<Float> = {
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: 8)
        for i in 0 ..< 8 { buf[i] = Float(exp2(-Double(9 - i))) }
        return buf
    }()
}

/// Interpolated unit sine at a continuous 1024-per-cycle phase. Negative and
/// out-of-range phases wrap (`& 1023` on the truncated index, two's-complement).
/// The lerp uses a fused multiply-add (`addingProduct`) — the article's FMA
/// lesson; the one genuine mul-add site in this DSP.
@inline(__always)
func oplFloatSine(_ phase: Float) -> Float {
    let i = Int(phase.rounded(.down))
    let f = phase - Float(i)
    let a = OPL3FloatTables.sine[i & 1023]
    let b = OPL3FloatTables.sine[(i &+ 1) & 1023]
    return a.addingProduct(b - a, f)
}

/// Float analogue of the eight `OPL3_EnvelopeCalcSin*` shapes (opl3.c:220…355).
/// Returns a signed value in roughly [-1, 1]; the envelope gain is applied by the
/// caller. `phase` is the continuous (modulated) 1024-per-cycle phase index.
@inline(__always)
func oplFloatWave(_ wf: UInt8, _ phase: Float) -> Float {
    let cyc = phase * (1.0 / 1024.0)
    let frac = cyc - cyc.rounded(.down)         // cycle position in [0, 1)
    switch wf {
        case 0:                                 // sine
            return oplFloatSine(phase)
        case 1:                                 // half sine (mute 2nd half)
            return frac < 0.5 ? oplFloatSine(phase) : 0
        case 2:                                 // |sine|
            return abs(oplFloatSine(phase))
        case 3:                                 // quarter sine (active in Q0, Q2)
            let q = Int(frac * 4)
            return (q & 1) == 0 ? abs(oplFloatSine(phase)) : 0
        case 4:                                 // double-freq sine, 1st half only
            return frac < 0.5 ? oplFloatSine(phase * 2) : 0
        case 5:                                 // double-freq |sine|, 1st half
            return frac < 0.5 ? abs(oplFloatSine(phase * 2)) : 0
        case 6:                                 // square
            return frac < 0.5 ? 1 : -1
        default:                                // 7 — logarithmic sawtooth
            return frac < 0.5
                ? Float(exp2(-32.0 * Double(frac)))
                : -Float(exp2(-32.0 * Double(1.0 - frac)))
    }
}

// The AoS float chip methods below are the pure-OPL_FLOAT path. Under OPL_SIMD
// the SoA chip (OPL3SimdDSP.swift) supplies its own clipSample / generate4Ch, so
// only the tables + waveform helpers above are shared with the SIMD build.
#if OPL_FLOAT && !OPL_SIMD
extension OPL3Chip {

    // Float fork of OPL3_SlotGenerate (opl3.c:690). Real sine × linear gain in
    // place of log-sine ROM + exponential ROM.
    func slotGenerate(_ s: Int) {
        let modVal = sample(at: slot[s].mod)
        let phaseArg = Float(slot[s].pgPhaseOut) + modVal
        let gain = OPL3FloatTables.gain[min(Int(slot[s].egOut), 1023)]
        slot[s].out = oplFloatWave(slot[s].regWf, phaseArg) * gain
    }

    // Float fork of OPL3_SlotCalcFB (opl3.c:695). `>> (9 - fb)` → ×2^-(9-fb).
    func slotCalcFB(_ s: Int) {
        let c = slot[s].channel
        if channel[c].fb != 0x00 {
            let sum = slot[s].prout + slot[s].out
            slot[s].fbmod = sum * OPL3FloatTables.feedback[Int(channel[c].fb)]
        } else {
            slot[s].fbmod = 0
        }

        slot[s].prout = slot[s].out
    }

    // Float fork of OPL3_ClipSample (opl3.c:1090). Round-to-nearest, then clamp.
    @inline(__always)
    func clipSample(_ sample: Float) -> Int16 {
        if sample > 32767 { return 32767 }
        if sample < -32768 { return -32768 }
        return Int16(sample.rounded())
    }

    // Float fork of OPL3_Generate4Ch (opl3.c:1111). The slot-sweep split, the
    // "FM output one sample later on the left" quirk, the LFO/EG clock and the
    // timed-write drain are copied verbatim from the integer build; only the mix
    // accumulators are float and the `accm & cha` pan-mask trick becomes a
    // multiply by {0, 1} (cha/chb/chc/chd are always 0xffff or 0 — opl3.c:977).
    func generate4Ch() -> (Int16, Int16, Int16, Int16) {
        let buf1 = clipSample(mixbuff.1)
        let buf3 = clipSample(mixbuff.3)

        for ii in 0 ..< 15 {
            processSlot(ii)
        }

        var mix0: Float = 0
        var mix1: Float = 0
        for ii in 0 ..< 18 {
            let out = channel[ii].out
            let accm = sample(at: out.0) + sample(at: out.1) + sample(at: out.2) + sample(at: out.3)
            if channel[ii].cha != 0 { mix0 += accm }
            if channel[ii].chc != 0 { mix1 += accm }
        }

        mixbuff.0 = mix0
        mixbuff.2 = mix1

        for ii in 15 ..< 18 {
            processSlot(ii)
        }

        let buf0 = clipSample(mixbuff.0)
        let buf2 = clipSample(mixbuff.2)

        for ii in 18 ..< 33 {
            processSlot(ii)
        }

        mix0 = 0
        mix1 = 0
        for ii in 0 ..< 18 {
            let out = channel[ii].out
            let accm = sample(at: out.0) + sample(at: out.1) + sample(at: out.2) + sample(at: out.3)
            if channel[ii].chb != 0 { mix0 += accm }
            if channel[ii].chd != 0 { mix1 += accm }
        }

        mixbuff.1 = mix0
        mixbuff.3 = mix1

        for ii in 33 ..< 36 {
            processSlot(ii)
        }

        if (timer & 0x3f) == 0x3f {
            tremolopos = (tremolopos &+ 1) % 210
        }
        if tremolopos < 105 {
            tremolo = tremolopos >> tremoloshift
        } else {
            tremolo = (210 - tremolopos) >> tremoloshift
        }

        if (timer & 0x3ff) == 0x3ff {
            vibpos = (vibpos &+ 1) & 7
        }

        timer = timer &+ 1

        if egState != 0 {
            var shift: UInt8 = 0
            while shift < 13 && ((egTimer >> UInt64(shift)) & 1) == 0 {
                shift += 1
            }

            if shift > 12 {
                egAdd = 0
            } else {
                egAdd = shift &+ 1
            }

            egTimerLo = UInt8(egTimer & 0x3)
        }

        if egTimerrem != 0 || egState != 0 {
            if egTimer == 0xf_ffff_ffff {
                egTimer = 0
                egTimerrem = 1
            } else {
                egTimer = egTimer &+ 1
                egTimerrem = 0
            }
        }

        egState ^= 1

        while true {
            let cur = Int(writebufCur)
            if !(writebuf[cur].time <= writebufSamplecnt) {
                break
            }
            if writebuf[cur].reg & 0x200 == 0 {
                break
            }

            writebuf[cur].reg &= 0x1ff
            writeReg(writebuf[cur].reg, writebuf[cur].data)
            writebufCur = (writebufCur &+ 1) % UInt32(OPL3Const.writeBufSize)
        }

        writebufSamplecnt = writebufSamplecnt &+ 1
        return (buf0, buf1, buf2, buf3)
    }
}
#endif  // OPL_FLOAT && !OPL_SIMD
#endif  // OPL_FLOAT || OPL_SIMD
