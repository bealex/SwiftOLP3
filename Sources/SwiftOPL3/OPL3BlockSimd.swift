//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3BlockSimd.swift
//  SwiftOPL3 — EXPERIMENTAL block-generating, SIMD float synthesis engine
//  (compiled only under `-DOPL_BLOCKSIMD`).
//
//  ⚠️  NOT a faithful transcription, and NOT a port of DOSBox. This file breaks
//  the package's "bit-exact integer port of Nuked-OPL3" rule (CLAUDE.md) on
//  purpose, to measure whether a DBOPL-style block engine is faster on Apple
//  Silicon. The integer path (OPL3Generate/Phase/Envelope.swift) is the default
//  and is untouched; nothing here is reachable unless `OPL_BLOCKSIMD` is defined.
//
//  LICENSE NOTE — clean-room, NOT DBOPL.
//  DOSBox's OPL emulator (`dbopl.cpp`) is **GPL-2.0-or-later**; this package is
//  **LGPL-2.1**. A port/transcription of dbopl.cpp would be a derivative work and
//  would force this file (and any build using it) to GPL — incompatible with the
//  package license. So this engine is written *from scratch* against the Nuked /
//  YMF262 math the rest of the package already uses (an algorithm/idea, not a
//  copyrightable expression). The three DBOPL *techniques* it borrows — (1) hoist
//  the branchy per-sample decisions out of the inner loop via state dispatch,
//  (2) generate a *block* of samples per call, (3) amortise the slow LFOs per
//  block — are general architecture, not DBOPL code. dbopl.cpp was never opened
//  or consulted while writing this; `References/` holds only LGPL sources.
//
//  WHAT IT APPROXIMATES (vs. the integer Nuked chip it is measured against):
//   • Phase  — EXACT: a 23-bit integer accumulator (≈ OPL3_PhaseGenerate), so
//     pitch never drifts. Only the *increment* is recomputed per block (vibrato
//     is sampled per block, not per sample).
//   • Envelope — APPROXIMATED: a float attenuation advanced by a per-rate
//     *average* increment (`OPL3EGRates`, derived by simulating Nuked's global EG
//     clock once at startup), state-dispatched instead of the per-sample switch
//     of OPL3_EnvelopeCalc. This is the speed bet — the EG control logic is the
//     dominant cost (see Performance.md) and this replaces it with a few flops.
//   • Synthesis — APPROXIMATED: a branchless polynomial sine (≈0.07 % error, no
//     table gather) × a linear envelope gain, vectorised over the block. Replaces
//     the log-sine ROM + exponential ROM. Operator full-scale is kept at ±4084
//     (= integer OPL3_EnvelopeCalcExp(0)) so FM modulation depth is unchanged.
//   • Feedback / rhythm — scalar fallbacks (inherently serial: feedback is a
//     two-sample recurrence; rhythm drives a per-sample noise LFSR + bespoke
//     phase bits, ported from OPL3_PhaseGenerate's rhythm branch).
//
//  Accuracy is validated by `OPL3GoldenTests.goldenTolerance` (RMS vs the Nuked
//  PCM goldens); speed by `oplbench` (self-labels `block-simd-float32`).

#if OPL_BLOCKSIMD
import Foundation

// MARK: - Constants

private enum BlockConst {
    /// Operator full-scale, matched to the integer chip: OPL3_EnvelopeCalcExp(0)
    /// = exprom[0] << 1 = 4084. Keeping the peak identical makes the float output
    /// directly comparable to the Nuked golden and the FM depth unchanged.
    static let fullScale: Float = 4084

    /// Native samples synthesised per vectorised block. Capped further when a
    /// buffered register write is due, so register timing stays sample-accurate.
    /// 32 keeps the per-block LFO approximation (tremolo period 64, vibrato 1024)
    /// well under one step while giving the inner loop enough length to vectorise.
    static let maxBlock = 32

    /// SIMD lane count for the synthesis inner loop (one 128-bit NEON register is
    /// 4 floats; 8 lets the compiler schedule two registers deep).
    static let lanes = 8
}

// MARK: - Average EG-rate tables (derived from Nuked's clock, clean-room)

/// Per-`rate` average envelope increments, precomputed once by *simulating*
/// Nuked-OPL3's global EG clock (the `eg_timer`/`eg_state`/`eg_add` progression
/// in OPL3_Generate4Ch) and the per-operator `shift` computation in
/// OPL3_EnvelopeCalc. This collapses Nuked's per-sample, clock-phased switch into
/// a single average rate per `rate` value — the whole point of the fork.
///
/// `rate` here is Nuked's `ks + (reg_rate << 2)` (0…75); index clamped to 0…127.
enum OPL3EGRates {
    /// Average attenuation added per native sample in Decay / Sustain / Release
    /// (the linear states, Nuked `eg_inc = 1 << (shift-1)`).
    nonisolated(unsafe) static let linInc: UnsafeMutableBufferPointer<Float> = build().lin
    /// Average *fraction* of the remaining attenuation removed per native sample
    /// in Attack (Nuked `eg_inc = ~eg_rout >> (4-shift)` ≈ `-eg_rout · 2^(shift-4)`).
    nonisolated(unsafe) static let atkFrac: UnsafeMutableBufferPointer<Float> = build().atk

    private static func build() -> (lin: UnsafeMutableBufferPointer<Float>, atk: UnsafeMutableBufferPointer<Float>) {
        let count = 128
        let lin = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        let atk = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
        lin.initialize(repeating: 0)
        atk.initialize(repeating: 0)

        // Simulate the global EG clock for M native samples and record, for each
        // sample, the (egState, egAdd, egTimerLo) the operator path would see.
        let m = 1 << 15
        var egTimer: UInt64 = 0
        var egState: UInt8 = 0
        var egAdd: UInt8 = 0
        var egTimerLo: UInt8 = 0
        var egTimerrem: UInt8 = 0
        var states = [UInt8](repeating: 0, count: m)
        var adds = [UInt8](repeating: 0, count: m)
        var los = [UInt8](repeating: 0, count: m)
        for n in 0 ..< m {
            states[n] = egState
            adds[n] = egAdd
            los[n] = egTimerLo
            // OPL3_Generate4Ch clock tail (opl3.c:1230) — exact.
            if egState != 0 {
                var shift: UInt8 = 0
                while shift < 13 && ((egTimer >> UInt64(shift)) & 1) == 0 { shift += 1 }
                egAdd = shift > 12 ? 0 : shift &+ 1
                egTimerLo = UInt8(egTimer & 0x3)
            }
            if egTimerrem != 0 || egState != 0 {
                if egTimer == 0xf_ffff_ffff { egTimer = 0; egTimerrem = 1 }
                else { egTimer = egTimer &+ 1; egTimerrem = 0 }
            }
            egState ^= 1
        }

        let egIncstep = OPL3Tables.egIncstep
        // Built assuming the operator is *active* (Nuked's `nonzero` = "register
        // rate ≠ 0"). The register-rate==0 case (envelope frozen) is handled by the
        // caller (fillGain), because `nonzero` can't be recovered from the combined
        // `rate` value — two different (ks, regRate) pairs collapse to the same rate.
        for rate in 0 ..< count {
            let rr = UInt8(min(rate, 75))
            var rateHi = rr >> 2
            let rateLo = rr & 0x03
            if rateHi & 0x10 != 0 { rateHi = 0x0f }

            var linSum: Double = 0
            var atkSum: Double = 0
            for n in 0 ..< m {
                // OPL3_EnvelopeCalc shift computation (opl3.c:417), exact.
                var shift: UInt8 = 0
                if rateHi < 12 {
                    if states[n] != 0 {
                        switch rateHi &+ adds[n] {
                            case 12: shift = 1
                            case 13: shift = (rateLo >> 1) & 0x01
                            case 14: shift = rateLo & 0x01
                            default: break
                        }
                    }
                } else {
                    shift = (rateHi & 0x03) &+ egIncstep[Int(rateLo)][Int(los[n])]
                    if shift & 0x04 != 0 { shift = 0x03 }
                    if shift == 0 { shift = states[n] }
                }
                if shift > 0 {
                    linSum += Double(1 << Int(shift - 1))
                    if rateHi != 0x0f { atkSum += Double(exp2(Double(Int(shift) - 4))) }
                }
            }
            lin[rate] = Float(linSum / Double(m))
            atk[rate] = Float(atkSum / Double(m))
        }
        return (lin, atk)
    }
}

/// Linear-interpolated envelope gain: `2^(-egOut/32) · fullScale`. `egOut` is the
/// final attenuation (egRout + regTl·4 + KSL + tremolo) and is fractional here
/// (the float EG produces sub-integer attenuation), so we lerp between entries
/// rather than round — otherwise slow envelope ramps would quantise. Mirrors the
/// role of Nuked's exponential ROM, computed directly in float.
enum OPL3GainLUT {
    static let size = 1536
    nonisolated(unsafe) static let table: UnsafeMutableBufferPointer<Float> = {
        let buf = UnsafeMutableBufferPointer<Float>.allocate(capacity: size + 1)
        for i in 0 ... size {
            buf[i] = Float(exp2(-Double(i) / 32.0) * Double(BlockConst.fullScale))
        }
        return buf
    }()

    @inline(__always)
    static func gain(_ egOut: Float) -> Float {
        let clamped = min(max(egOut, 0), Float(size) - 1)
        let i = Int(clamped)
        let f = clamped - Float(i)
        let a = table[i]
        return a.addingProduct(table[i + 1] - a, f)
    }
}

// MARK: - Branchless polynomial sine + the 8 OPL waveform shapes (SIMD)

/// Pointwise `|x|` for a SIMD vector (stdlib `SIMD` is not `Comparable`, so the
/// free `abs(_:)` doesn't apply — select `-x` where negative).
@inline(__always)
private func vabs(_ x: SIMD8<Float>) -> SIMD8<Float> {
    x.replacing(with: -x, where: x .< 0)
}

/// `sin(2π·turns)` via the classic two-term parabola approximation, refined once
/// (~0.07 % max error) — fully branchless and table-free, so it vectorises with
/// no gather (the reason the old LUT float fork could not go wide on NEON).
/// `turns` is the phase in cycles (phase index / 1024).
@inline(__always)
private func polySin(_ turns: SIMD8<Float>) -> SIMD8<Float> {
    // Wrap to [-0.5, 0.5] cycles, then x = 2·t ∈ [-1, 1] so sin(2π t) = sin(π x).
    let t = turns - (turns + 0.5).rounded(.down)
    let x = t + t
    // Parabola P ≈ sin(π x): P = 4x(1 - |x|)   (≈4 % error)
    let p = 4 * x * (1 - vabs(x))
    // One Newton-style refinement: Q = 0.225·(P·|P| - P) + P   (≈0.07 % error)
    return 0.225 * (p * vabs(p) - p) + p
}

/// One OPL waveform shape evaluated over a SIMD block. `phase` is the (modulated)
/// phase index in 1024-per-cycle units. Approximates OPL3_EnvelopeCalcSin0…7
/// (opl3.c:220…355): same shapes, polynomial sine instead of the log-sine ROM.
@inline(__always)
private func waveBlock(_ wf: UInt8, _ phase: SIMD8<Float>) -> SIMD8<Float> {
    let inv: Float = 1.0 / 1024.0
    let turns = phase * inv
    let frac = turns - turns.rounded(.down)         // cycle position [0,1)
    let zero = SIMD8<Float>(repeating: 0)
    switch wf {
        case 0:                                     // sine
            return polySin(turns)
        case 1:                                     // half sine (2nd half muted)
            return polySin(turns).replacing(with: zero, where: frac .>= 0.5)
        case 2:                                     // |sine|
            return vabs(polySin(turns))
        case 3:                                     // quarter sine (Q0, Q2)
            let q4 = frac * 4
            let oddQuarter = (q4 - 2 * (q4 * 0.5).rounded(.down)) .>= 1   // (floor(q4) & 1)
            return vabs(polySin(turns)).replacing(with: zero, where: oddQuarter)
        case 4:                                     // double-freq sine, 1st half
            return polySin(turns + turns).replacing(with: zero, where: frac .>= 0.5)
        case 5:                                     // double-freq |sine|, 1st half
            return vabs(polySin(turns + turns)).replacing(with: zero, where: frac .>= 0.5)
        case 6:                                     // square
            return SIMD8<Float>(repeating: 1).replacing(with: SIMD8<Float>(repeating: -1), where: frac .>= 0.5)
        default:                                    // 7 — log sawtooth (≈ exp ramp)
            let up = exp2Approx(-32 * frac)
            let down = -exp2Approx(-32 * (1 - frac))
            return up.replacing(with: down, where: frac .>= 0.5)
    }
}

/// Cheap SIMD `2^y` for y ≤ 0 (waveform 7 only). Accuracy here is irrelevant —
/// the sawtooth wave is barely used and the golden for it is silent.
@inline(__always)
private func exp2Approx(_ y: SIMD8<Float>) -> SIMD8<Float> {
    // 2^y ≈ via the float bit trick; clamp to avoid denormals.
    let yc = y.replacing(with: SIMD8(repeating: -32), where: y .< -32)
    var r = SIMD8<Float>(repeating: 1)
    for i in 0 ..< BlockConst.lanes { r[i] = Float(exp2(Double(yc[i]))) }
    return r
}

// MARK: - Per-operator dynamic state (float)

/// The block engine's own per-operator state. Config (registers, routing) is read
/// straight from the chip's AoS `slot`/`channel` buffers at block start — no SoA
/// mirror — so only the *dynamic* values that the integer chip keeps in `Slot`
/// live here, as float.
private struct BlockOp {
    var phase: UInt32 = 0            // 23-bit phase accumulator (exact, like Nuked)
    var egRout: Float = 0x1ff        // envelope attenuation, 0…511 (float)
    var egGen: UInt8 = OPL3Const.envRelease
    var pgReset: Bool = false
    var key: UInt8 = 0
    var out1: Float = 0              // previous output (feedback recurrence)
    var out2: Float = 0             // output two samples ago
}

// MARK: - The engine

/// Drives `OPL3Chip`'s public surface under `-DOPL_BLOCKSIMD`. Holds the float
/// operator state, reads config from the chip's register layer, and fills a small
/// native-rate ring that `generate4Ch()` drains.
final class OPL3BlockEngine {
    private unowned let chip: OPL3Chip

    private var op = [BlockOp](repeating: BlockOp(), count: 36)
    private var active = [Bool](repeating: false, count: 36)

    // Per-block scratch (allocated once).
    private let gainBuf: UnsafeMutableBufferPointer<Float>      // 36 × maxBlock
    private let outBuf: UnsafeMutableBufferPointer<Float>       // 36 × maxBlock
    private let phaseArg: UnsafeMutableBufferPointer<Float>     // maxBlock

    // Native-rate output ring (interleaved buf0..3 per sample) that generate4Ch drains.
    private let ring: UnsafeMutableBufferPointer<Int16>         // maxBlock × 4
    private var ringHead = 0
    private var ringCount = 0

    // Right-channel one-sample delay carry (the channel-sample-delay quirk).
    private var pendRight1: Float = 0
    private var pendRight3: Float = 0
    // Each slot's output at the previous native sample — bridges block edges for
    // the left-mix staleness (slots ≥15) the channel-sample-delay quirk needs.
    private var carryOut = [Float](repeating: 0, count: 36)

    init(_ chip: OPL3Chip) {
        self.chip = chip
        gainBuf = .allocate(capacity: 36 * BlockConst.maxBlock); gainBuf.initialize(repeating: 0)
        outBuf = .allocate(capacity: 36 * BlockConst.maxBlock); outBuf.initialize(repeating: 0)
        phaseArg = .allocate(capacity: BlockConst.maxBlock); phaseArg.initialize(repeating: 0)
        ring = .allocate(capacity: BlockConst.maxBlock * 4); ring.initialize(repeating: 0)
    }

    deinit {
        gainBuf.deallocate(); outBuf.deallocate(); phaseArg.deallocate(); ring.deallocate()
    }

    /// Reseed dynamic state from the chip's AoS slots after a reset.
    func reseed() {
        for s in 0 ..< 36 {
            op[s] = BlockOp()
            op[s].phase = chip.slot[s].pgPhase
            op[s].egRout = Float(chip.slot[s].egRout)
            op[s].egGen = chip.slot[s].egGen
            op[s].key = chip.slot[s].key
        }
        ringHead = 0; ringCount = 0
        pendRight1 = 0; pendRight3 = 0
        for s in 0 ..< 36 { carryOut[s] = 0 }
    }

    // MARK: One native sample (drains the ring, refilling a block at a time)

    func generateNative() -> (Int16, Int16, Int16, Int16) {
        if ringCount == 0 { fillBlock() }
        let base = ringHead * 4
        let s = (ring[base], ring[base + 1], ring[base + 2], ring[base + 3])
        ringHead = (ringHead + 1) % BlockConst.maxBlock
        ringCount -= 1
        return s
    }

    /// Generate one block of native samples into the ring, capped so no buffered
    /// register write falls inside it (keeping register timing sample-accurate).
    private func fillBlock() {
        let t = plannedBlockLength()

        // Sync per-op key/egGen from the chip in case a register write changed
        // key-on state since the last block.
        for s in 0 ..< 36 {
            op[s].key = chip.slot[s].key
            // Mirror Nuked's key-off → release / key-on-from-release → attack edges.
            if op[s].key != 0 && op[s].egGen == OPL3Const.envRelease {
                op[s].egGen = OPL3Const.envAttack
                op[s].pgReset = true
            } else if op[s].key == 0 {
                op[s].egGen = OPL3Const.envRelease
            }
        }

        // Per-block LFOs (sampled once — the amortised approximation).
        let tremolo = chip.tremolo
        let rhythmOn = (chip.rhy & 0x20) != 0

        // Operator culling — the block engine's main speed lever (DBOPL culls too).
        // A released operator whose envelope has decayed to silence does no audible
        // work and modulates nothing (gain 0 ⇒ output 0), so skip its envelope +
        // synthesis entirely and leave its block output zeroed. On a sparse track
        // most of the 36 operators are idle at any instant; the integer chip runs
        // all of them every sample, this runs only the live ones.
        for s in 0 ..< 36 {
            active[s] = op[s].key != 0 || op[s].egRout < 0x1f8
            if !active[s] {
                let base = s * BlockConst.maxBlock
                for k in 0 ..< t { outBuf[base + k] = 0 }
            }
        }

        // 1) Envelope → gain[op][k]   (state-dispatched, scalar, cheap)
        for s in 0 ..< 36 where active[s] { fillGain(s, t, tremolo: tremolo) }

        // 2) Phase + synthesis → outBuf[op][k]   (slot order so modulators precede carriers)
        for s in 0 ..< 36 where active[s] { synth(s, t, rhythmOn: rhythmOn) }

        // 2b) The noise drums (HH/SD/TC), faithfully, per-sample (only under rhythm
        // mode — zero cost on melodic tracks, which is the common case).
        if rhythmOn { synthRhythm(t) }

        // 3) Mix the channel outputs into the ring (with the right-delay quirk).
        mix(t)

        // 4) Advance the slow clocks and drain due buffered writes.
        advanceClocks(t)

        ringHead = 0
        ringCount = t
    }

    /// Samples until the next buffered write is due (so it lands on the correct
    /// sample), clamped to [1, maxBlock].
    private func plannedBlockLength() -> Int {
        var t = BlockConst.maxBlock
        let cur = Int(chip.writebufCur)
        let wb = chip.writebuf[cur]
        if wb.reg & 0x200 != 0 {
            let due = Int(clamping: wb.time >= chip.writebufSamplecnt ? wb.time - chip.writebufSamplecnt : 0)
            t = max(1, min(t, due == 0 ? 1 : due))
        }
        return t
    }

    // MARK: Envelope (the speed bet)

    /// Advance operator `s`'s float envelope across the block, writing the final
    /// gain (incl. regTl / KSL / tremolo) per sample into `gainBuf`. Approximates
    /// OPL3_EnvelopeCalc with `OPL3EGRates` average increments + state dispatch.
    private func fillGain(_ s: Int, _ t: Int, tremolo: UInt8) {
        let sl = chip.slot[s]
        let c = sl.channel
        let ch = chip.channel[c]

        // Static attenuation offset (regTl, KSL) added to egRout for the final egOut.
        let kslShift = OPL3Tables.kslshift[Int(sl.regKsl)]
        let tlKsl = Float(UInt32(sl.regTl) << 2) + Float(UInt32(sl.egKsl) >> UInt32(kslShift))
        let trem = sl.trem == .tremolo ? Float(tremolo) : 0
        let offset = tlKsl + trem

        // Key-scale rate (OPL3_EnvelopeCalc:443) — constant over the block.
        let ks = ch.ksv >> ((sl.regKsr ^ 1) << 1)

        var egRout = op[s].egRout
        var egGen = op[s].egGen
        let key = op[s].key

        let base = s * BlockConst.maxBlock
        for k in 0 ..< t {
            // Nuked computes eg_out from the attenuation BEFORE this sample's update
            // (OPL3_EnvelopeCalc:392) — a one-sample lag, so the first sample after
            // key-on is still at the pre-attack level (silent). Emit gain first,
            // then advance the envelope for the next sample.
            gainBuf[base + k] = OPL3GainLUT.gain(egRout + offset)

            // "Env off" sticky-silence edge (eg_rout high bits all set).
            let egOff = (UInt16(egRout) & 0x1f8) == 0x1f8

            switch egGen {
                case OPL3Const.envAttack:
                    let rateHi = min(Int(ks &+ (sl.regAr << 2)) >> 2, 0x0f)
                    if rateHi == 0x0f {
                        egRout = 0                           // instant attack
                    } else if key != 0 && sl.regAr != 0 {    // regRate==0 ⇒ frozen
                        egRout -= egRout * OPL3EGRates.atkFrac[Int(ks &+ (sl.regAr << 2)) & 127]
                    }
                    if egRout <= 0 { egRout = 0; egGen = OPL3Const.envDecay }

                case OPL3Const.envDecay:
                    if UInt16(egRout) >> 4 >= UInt16(sl.regSl) {
                        egGen = OPL3Const.envSustain
                    } else if !egOff && sl.regDr != 0 {
                        egRout += OPL3EGRates.linInc[Int(ks &+ (sl.regDr << 2)) & 127]
                    }

                case OPL3Const.envSustain:
                    if sl.regType == 0 && !egOff && sl.regRr != 0 {   // percussive → release-rate decay
                        egRout += OPL3EGRates.linInc[Int(ks &+ (sl.regRr << 2)) & 127]
                    }

                default:                                     // release
                    if !egOff && sl.regRr != 0 {
                        egRout += OPL3EGRates.linInc[Int(ks &+ (sl.regRr << 2)) & 127]
                    }
            }
            if egRout > 0x1ff { egRout = 0x1ff }
        }

        // pgReset (phase reset on key-on) is owned by the key-sync edge in
        // fillBlock and consumed/cleared in synth — fillGain must not touch it.
        op[s].egRout = egRout
        op[s].egGen = egGen
    }

    // MARK: Phase + synthesis

    private func synth(_ s: Int, _ t: Int, rhythmOn: Bool) {
        let sl = chip.slot[s]

        // The noise drums (HH/SD/TC) are processed per-sample by synthRhythm under
        // rhythm mode — skip them here so their phase/output isn't computed twice.
        if rhythmOn && (sl.slotNum == 13 || sl.slotNum == 16 || sl.slotNum == 17) { return }

        let ch = chip.channel[sl.channel]
        let inc = phaseIncrement(s)
        if op[s].pgReset { op[s].phase = 0; op[s].pgReset = false }
        let base = s * BlockConst.maxBlock

        // Feedback operators are a two-sample recurrence → scalar.
        if ch.fb != 0 && sl.mod == .slotFbmod(s) {
            synthFeedback(s, t, inc: inc, wf: sl.regWf, fbScale: exp2f(-Float(9 - Int(ch.fb))))
            return
        }

        // Resolve the modulation source to a flat buffer offset once (hoisting the
        // SampleRef switch out of the per-sample loop). The fb!=0 case took the
        // scalar path above, so here mod is either none or another slot's output.
        let modSrc: Int
        switch sl.mod {
            case .slotOut(let i): modSrc = i * BlockConst.maxBlock
            default: modSrc = -1
        }

        // Build phaseArg[k] = pgPhaseOut(k) + modulation(k), then vectorise.
        for k in 0 ..< t {
            let pout = Float((op[s].phase >> 9) & 0x3ff)
            op[s].phase = op[s].phase &+ inc
            phaseArg[k] = modSrc < 0 ? pout : pout + outBuf[modSrc + k]
        }

        let wf = sl.regWf
        var k = 0
        while k + BlockConst.lanes <= t {
            var pv = SIMD8<Float>()
            var gv = SIMD8<Float>()
            for j in 0 ..< BlockConst.lanes { pv[j] = phaseArg[k + j]; gv[j] = gainBuf[base + k + j] }
            let ov = waveBlock(wf, pv) * gv
            for j in 0 ..< BlockConst.lanes { outBuf[base + k + j] = ov[j] }
            k += BlockConst.lanes
        }
        // Tail (block lengths capped by writes aren't always lane-multiples).
        while k < t {
            let ov = waveBlock(wf, SIMD8<Float>(repeating: phaseArg[k]))
            outBuf[base + k] = ov[0] * gainBuf[base + k]
            k += 1
        }

        op[s].out1 = outBuf[base + t - 1]
        op[s].out2 = t >= 2 ? outBuf[base + t - 2] : op[s].out1
    }

    /// Per-block integer phase increment ≈ OPL3_PhaseGenerate (vibrato sampled per
    /// block). Shared by the melodic, feedback and rhythm synthesis paths.
    @inline(__always)
    private func phaseIncrement(_ s: Int) -> UInt32 {
        let sl = chip.slot[s]
        let ch = chip.channel[sl.channel]
        var fNum = ch.fNum
        if sl.regVib != 0 {
            var range = Int8((fNum >> 7) & 7)
            let vp = chip.vibpos
            if vp & 3 == 0 { range = 0 } else if vp & 1 != 0 { range >>= 1 }
            range >>= chip.vibshift
            if vp & 4 != 0 { range = -range }
            fNum = UInt16(truncatingIfNeeded: Int(fNum) &+ Int(range))
        }
        let basefreq = (UInt32(fNum) << UInt32(ch.block)) >> 1
        return (basefreq &* UInt32(OPL3Tables.mt[Int(sl.regMult)])) >> 1
    }

    /// Scalar synthesis for a self-feedback operator (a two-sample recurrence that
    /// can't vectorise): mod = (out[n-1] + out[n-2]) · 2^-(9-fb), ≈ OPL3_SlotCalcFB.
    private func synthFeedback(_ s: Int, _ t: Int, inc: UInt32, wf: UInt8, fbScale: Float) {
        let base = s * BlockConst.maxBlock
        var out1 = op[s].out1
        var out2 = op[s].out2
        for k in 0 ..< t {
            let pout = Float((op[s].phase >> 9) & 0x3ff)
            op[s].phase = op[s].phase &+ inc
            let v = waveBlock(wf, SIMD8<Float>(repeating: pout + (out1 + out2) * fbScale))[0] * gainBuf[base + k]
            outBuf[base + k] = v
            out2 = out1
            out1 = v
        }
        op[s].out1 = out1
        op[s].out2 = out2
    }

    // MARK: Rhythm percussion (faithful per-sample noise + bit coupling)

    @inline(__always)
    private func advanceNoise() {
        let noise = chip.noise
        let nBit = UInt32(((noise >> 14) ^ noise) & 0x01)
        chip.noise = (noise >> 1) | (nBit << 22)
    }

    /// The rhythm phase-bit XOR network (opl3.c:569).
    @inline(__always)
    private func rmXorBits() -> UInt8 {
        (chip.rmHHBit2 ^ chip.rmHHBit7) | (chip.rmHHBit3 ^ chip.rmTCBit5) | (chip.rmTCBit3 ^ chip.rmTCBit5)
    }

    @inline(__always)
    private func waveScalar(_ wf: UInt8, _ phase: Float) -> Float {
        waveBlock(wf, SIMD8<Float>(repeating: phase))[0]
    }

    /// Process the three noise drums (HH=13, SD=16, TC=17) per sample, faithfully
    /// reproducing OPL3_PhaseGenerate's rhythm branch — which a block-vectorised
    /// melodic path cannot, because it depends on the global noise LFSR and the
    /// rmHH/rmTC phase-bit cross-coupling, both of which are strictly per-sample.
    ///
    /// Per sample the LFSR is advanced exactly 36 times (Nuked advances it once per
    /// operator, in slot order), snapshotting `noise & 1` at the points slots
    /// 13/16/17 read it. The three slots are then processed in slot order, so the
    /// bit coupling matches: slot 13 sets the rmHH bits and reads rmTC from the
    /// *previous* sample (slot 17 runs after it); slots 16/17 read this sample's
    /// rmHH bits; slot 17 sets the rmTC bits then reads the freshly-updated XOR.
    /// BD (12/15) and TT (14) carry no noise and stay on the block path.
    private func synthRhythm(_ t: Int) {
        let inc13 = phaseIncrement(13), inc16 = phaseIncrement(16), inc17 = phaseIncrement(17)
        if op[13].pgReset { op[13].phase = 0; op[13].pgReset = false }
        if op[16].pgReset { op[16].phase = 0; op[16].pgReset = false }
        if op[17].pgReset { op[17].phase = 0; op[17].pgReset = false }
        let wf13 = chip.slot[13].regWf, wf16 = chip.slot[16].regWf, wf17 = chip.slot[17].regWf
        let b13 = 13 * BlockConst.maxBlock, b16 = 16 * BlockConst.maxBlock, b17 = 17 * BlockConst.maxBlock

        for k in 0 ..< t {
            // Advance the shared LFSR 36×/sample; snapshot the two read points
            // (HH reads after 13 advances, SD after 16; TC reads no noise).
            for _ in 0 ..< 13 { advanceNoise() }; let n13 = chip.noise & 1
            for _ in 0 ..< 3  { advanceNoise() }; let n16 = chip.noise & 1
            for _ in 0 ..< 20 { advanceNoise() }

            // HH (13): sets rmHH bits from its phase; rmXor reads last sample's rmTC.
            let ph13 = UInt16((op[13].phase >> 9) & 0x3ff)
            op[13].phase = op[13].phase &+ inc13
            chip.rmHHBit2 = UInt8((ph13 >> 2) & 1); chip.rmHHBit3 = UInt8((ph13 >> 3) & 1)
            chip.rmHHBit7 = UInt8((ph13 >> 7) & 1); chip.rmHHBit8 = UInt8((ph13 >> 8) & 1)
            if active[13] {
                let rmXor = rmXorBits()
                var p = UInt16(rmXor) << 9
                if (UInt32(rmXor) ^ n13) != 0 { p |= 0xd0 } else { p |= 0x34 }
                outBuf[b13 + k] = waveScalar(wf13, Float(p)) * gainBuf[b13 + k]
            }

            // SD (16): phase output from rmHHBit8 + noise.
            op[16].phase = op[16].phase &+ inc16
            if active[16] {
                let p = UInt16(truncatingIfNeeded: (UInt32(chip.rmHHBit8) << 9) | ((UInt32(chip.rmHHBit8) ^ n16) << 8))
                outBuf[b16 + k] = waveScalar(wf16, Float(p)) * gainBuf[b16 + k]
            }

            // TC (17): sets rmTC bits from its phase, then reads the updated rmXor.
            let ph17 = UInt16((op[17].phase >> 9) & 0x3ff)
            op[17].phase = op[17].phase &+ inc17
            chip.rmTCBit3 = UInt8((ph17 >> 3) & 1); chip.rmTCBit5 = UInt8((ph17 >> 5) & 1)
            if active[17] {
                let p = (UInt16(rmXorBits()) << 9) | 0x80
                outBuf[b17 + k] = waveScalar(wf17, Float(p)) * gainBuf[b17 + k]
            }
        }
    }

    // MARK: Mix

    // The channel-sample-delay quirk, faithfully (≈ OPL3_Generate4Ch's 4-group
    // split). Nuked computes the LEFT mix (mixbuff.0/.2, cha/chc) after processing
    // only slots 0..14, so a channel output that references a slot ≥15 reads the
    // *previous* sample there; the RIGHT mix (mixbuff.1/.3, chb/chd) is computed
    // after slots 0..32 (slots 33..35 stale) and then output one sample later.
    // Channel 0 (slots 0,3) is unaffected — which is why the tonal goldens were
    // already exact — but the rhythm channels 6/7/8 use slots 15/16/17, so getting
    // this right is what makes percussion track Nuked.
    private func mix(_ t: Int) {
        for k in 0 ..< t {
            var cha: Float = 0, chb: Float = 0, chc: Float = 0, chd: Float = 0
            for c in 0 ..< 18 {
                let ch = chip.channel[c]
                let o = ch.out
                let left = outRef(o.0, k, 14) + outRef(o.1, k, 14) + outRef(o.2, k, 14) + outRef(o.3, k, 14)
                let right = outRef(o.0, k, 32) + outRef(o.1, k, 32) + outRef(o.2, k, 32) + outRef(o.3, k, 32)
                if ch.cha != 0 { cha += left }
                if ch.chc != 0 { chc += left }
                if ch.chb != 0 { chb += right }
                if ch.chd != 0 { chd += right }
            }
            let dst = k * 4
            ring[dst + 0] = clip(cha)
            ring[dst + 1] = clip(pendRight1)   // right lags one sample
            ring[dst + 2] = clip(chc)
            ring[dst + 3] = clip(pendRight3)
            pendRight1 = chb
            pendRight3 = chd
        }
        for s in 0 ..< 36 { carryOut[s] = outBuf[s * BlockConst.maxBlock + t - 1] }
    }

    /// Resolve a channel-output `SampleRef` for the mix. Slots with index above
    /// `freshThru` hold the *previous* sample's value at this point in Nuked's
    /// slot sweep (the channel-sample-delay quirk); `carryOut` bridges block edges.
    @inline(__always)
    private func outRef(_ ref: SampleRef, _ k: Int, _ freshThru: Int) -> Float {
        switch ref {
            case .zero: return 0
            case .slotOut(let i):
                if i <= freshThru { return outBuf[i * BlockConst.maxBlock + k] }
                return k > 0 ? outBuf[i * BlockConst.maxBlock + k - 1] : carryOut[i]
            case .slotFbmod(let i): return op[i].out1   // rarely routed to output
        }
    }

    @inline(__always)
    private func clip(_ v: Float) -> Int16 {
        if v > 32767 { return 32767 }
        if v < -32768 { return -32768 }
        return Int16(v.rounded())
    }

    // MARK: Clocks + buffered-write drain

    private func advanceClocks(_ t: Int) {
        for _ in 0 ..< t {
            if (chip.timer & 0x3f) == 0x3f { chip.tremolopos = (chip.tremolopos &+ 1) % 210 }
            if chip.tremolopos < 105 { chip.tremolo = chip.tremolopos >> chip.tremoloshift }
            else { chip.tremolo = (210 - chip.tremolopos) >> chip.tremoloshift }
            if (chip.timer & 0x3ff) == 0x3ff { chip.vibpos = (chip.vibpos &+ 1) & 7 }
            chip.timer = chip.timer &+ 1

            chip.writebufSamplecnt = chip.writebufSamplecnt &+ 1
            while true {
                let cur = Int(chip.writebufCur)
                let wb = chip.writebuf[cur]
                if !(wb.time <= chip.writebufSamplecnt) { break }
                if wb.reg & 0x200 == 0 { break }
                chip.writebuf[cur].reg &= 0x1ff
                chip.writeReg(chip.writebuf[cur].reg, chip.writebuf[cur].data)
                chip.writebufCur = (chip.writebufCur &+ 1) % UInt32(OPL3Const.writeBufSize)
            }
        }
    }
}

private extension Int {
    init(clamping v: UInt64) { self = v > UInt64(Int.max) ? Int.max : Int(v) }
}
#endif  // OPL_BLOCKSIMD
