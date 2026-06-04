//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3Types.swift
//  SwiftOPL3 — the chip's internal state types, transcribed from `opl3.h`.
//
//  Faithful transcription of `_opl3_slot` / `_opl3_channel` (opl3.h:53, :85) and
//  the supporting enums/constants from `opl3.c`. Nuked-OPL3 v1.8, commit cfedb09e.
//
//  Pointer model (see Documentation/Architecture/OPL3.md §Types): Nuked uses raw
//  pointers — `int16_t *mod`, `uint8_t *trem`, `int16_t *out[4]`, and the
//  back-references `slot->channel` / `channel->pair`. We model every one of these
//  as an *index* into the chip's `slot`/`channel` arrays (or a `.zero` sentinel
//  standing in for `&chip->zeromod`), resolved through the owning `OPL3Chip`.
//  This matches the C array layout, avoids retain cycles, and keeps everything
//  value-typed under strict concurrency.
//
//  Field names track the C (`egRout` ⇐ `eg_rout`, …) to keep the transcription
//  verifiable against `opl3.c:line`; this overrides the usual no-abbreviation
//  style for this faithful-port package.

// EXPERIMENTAL — `OPL_FLOAT` floating-point DSP fork (off by default).
//
// This package is normally a *bit-exact integer* transcription of Nuked-OPL3
// (see CLAUDE.md "faithful transcription" rule). Building with `-DOPL_FLOAT`
// swaps the per-sample synthesis arithmetic to 32-bit float — a deliberately
// non-faithful, idealized variant used only to evaluate whether floating-point
// DSP is faster on this hardware. The integer path is the default and is left
// untouched; nothing here changes unless `OPL_FLOAT` is defined.
//
// `OPLSample` is the per-operator sample / modulation type. In the integer
// build it is the Nuked `int16_t`; in the float build it is `Float`, kept at
// the *same numeric scale* (operator full-scale ≈ ±4084) so that the FM
// phase-modulation chain (`pgPhaseOut + modVal`) and the feedback shift behave
// identically — only the synthesis math (sine, exp→gain, mix) becomes float.
// See OPL3FloatDSP.swift.
#if OPL_FLOAT || OPL_SIMD
public typealias OPLSample = Float
#else
public typealias OPLSample = Int16
#endif

/// A reference to an `int16_t` modulation/output source. Models a Nuked
/// `int16_t *` that points at `&chip->zeromod`, a slot's `out`, or a slot's
/// `fbmod`. Resolved by `OPL3Chip.sample(at:)`.
enum SampleRef: Equatable {
    case zero
    case slotOut(Int)
    case slotFbmod(Int)
}

/// A reference to the tremolo source. Models the Nuked `uint8_t *trem` that
/// points at `&chip->tremolo` or `(uint8_t*)&chip->zeromod` (which reads 0).
enum TremRef: Equatable {
    case zero
    case tremolo
}

/// Per-operator state. ≈ `opl3_slot` (opl3.h:53).
struct Slot {
    // Cross-references (Nuked pointers → indices).
    var channel: Int = 0            // ≈ slot->channel (index into chip.channel)
    var mod: SampleRef = .zero      // ≈ slot->mod   (int16_t*)
    var trem: TremRef = .zero       // ≈ slot->trem  (uint8_t*)

    var out: OPLSample = 0
    var fbmod: OPLSample = 0
    var prout: OPLSample = 0
    var egRout: UInt16 = 0
    var egOut: UInt16 = 0
    var egInc: UInt8 = 0            // vestigial in v1.8 (declared, unused) — kept for fidelity
    var egGen: UInt8 = 0
    var egRate: UInt8 = 0           // vestigial in v1.8 (declared, unused) — kept for fidelity
    var egKsl: UInt8 = 0
    var regVib: UInt8 = 0
    var regType: UInt8 = 0
    var regKsr: UInt8 = 0
    var regMult: UInt8 = 0
    var regKsl: UInt8 = 0
    var regTl: UInt8 = 0
    var regAr: UInt8 = 0
    var regDr: UInt8 = 0
    var regSl: UInt8 = 0
    var regRr: UInt8 = 0
    var regWf: UInt8 = 0
    var key: UInt8 = 0
    var pgReset: UInt32 = 0
    var pgPhase: UInt32 = 0
    var pgPhaseOut: UInt16 = 0
    var slotNum: UInt8 = 0
}

/// Per-channel state. ≈ `opl3_channel` (opl3.h:85).
struct Channel {
    // Fixed tuples (not arrays) so `Channel` is a trivial value type with no
    // heap storage / ARC — the hot loop touches `channel[c]` millions of times
    // per second. ≈ channel->slotz[2] / channel->out[4].
    var slotz: (Int, Int) = (0, 0)         // indices into chip.slot
    var pair: Int = -1                     // ≈ channel->pair (index, -1 = NULL)
    var out: (SampleRef, SampleRef, SampleRef, SampleRef) = (.zero, .zero, .zero, .zero)

    var chtype: UInt8 = 0
    var fNum: UInt16 = 0
    var block: UInt8 = 0
    var fb: UInt8 = 0
    var con: UInt8 = 0
    var alg: UInt8 = 0
    var ksv: UInt8 = 0
    var cha: UInt16 = 0
    var chb: UInt16 = 0
    var chc: UInt16 = 0
    var chd: UInt16 = 0
    var chNum: UInt8 = 0
}

/// A pending timed register write. ≈ `opl3_writebuf` (opl3.h:108).
struct WriteBuf {
    var time: UInt64 = 0
    var reg: UInt16 = 0
    var data: UInt8 = 0
}

/// The named constants Nuked defines at file scope in `opl3.c` / `opl3.h`.
enum OPL3Const {
    // Channel types — opl3.c:56 enum.
    static let ch2op: UInt8 = 0
    static let ch4op: UInt8 = 1
    static let ch4op2: UInt8 = 2
    static let chDrum: UInt8 = 3

    // Envelope key types — opl3.c:65 enum.
    static let egkNorm: UInt8 = 0x01
    static let egkDrum: UInt8 = 0x02

    // Envelope generator phase — opl3.c:368 enum envelope_gen_num.
    static let envAttack: UInt8 = 0
    static let envDecay: UInt8 = 1
    static let envSustain: UInt8 = 2
    static let envRelease: UInt8 = 3

    // opl3.c:52 / opl3.h:46.
    static let rsmFrac: UInt32 = 10
    static let writeBufSize: Int = 1024
    static let writeBufDelay: UInt64 = 2

    static let nativeFreq: UInt32 = 49_716
}
