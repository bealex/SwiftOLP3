//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3Waveforms.swift
//  SwiftOPL3 — the exponential converter and the 8 log-sine waveform functions.
//
//  Faithful transcription of `OPL3_EnvelopeCalcExp` (opl3.c:211) and
//  `OPL3_EnvelopeCalcSin0..7` (opl3.c:220..355) plus the `envelope_sin[8]`
//  dispatch table (opl3.c:357). Nuked-OPL3 v1.8, commit cfedb09e.
//
//  Integer-width notes: in C these take `(uint16_t phase, uint16_t envelope)` and
//  return `int16_t`. `out + (envelope << 3)` is computed in (promoted) `int` then
//  handed to `OPL3_EnvelopeCalcExp(uint32_t)`; we widen to `UInt32`. The trailing
//  `^ neg` (neg = 0 or 0xffff) negates via 16-bit one's-complement, so we XOR in
//  `Int32` and truncate to `Int16` — matching the implicit C narrowing exactly.

enum OPL3Waveforms {
    // opl3.c:211 OPL3_EnvelopeCalcExp
    static func envelopeCalcExp(_ level: UInt32) -> Int16 {
        var level = level
        if level > 0x1fff {
            level = 0x1fff
        }

        let value = Int32(OPL3Tables.exprom[Int(level & 0xff)])
        return Int16(truncatingIfNeeded: (value << 1) >> Int32(level >> 8))
    }

    // opl3.c:220 OPL3_EnvelopeCalcSin0
    static func envelopeCalcSin0(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var out: UInt16 = 0
        var neg: UInt16 = 0
        let phase = phase & 0x3ff
        if phase & 0x200 != 0 {
            neg = 0xffff
        }

        if phase & 0x100 != 0 {
            out = OPL3Tables.logsinrom[Int((phase & 0xff) ^ 0xff)]
        } else {
            out = OPL3Tables.logsinrom[Int(phase & 0xff)]
        }

        let value = envelopeCalcExp(UInt32(out) &+ (UInt32(envelope) << 3))
        return Int16(truncatingIfNeeded: Int32(value) ^ Int32(neg))
    }

    // opl3.c:240 OPL3_EnvelopeCalcSin1
    static func envelopeCalcSin1(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var out: UInt16 = 0
        let phase = phase & 0x3ff
        if phase & 0x200 != 0 {
            out = 0x1000
        } else if phase & 0x100 != 0 {
            out = OPL3Tables.logsinrom[Int((phase & 0xff) ^ 0xff)]
        } else {
            out = OPL3Tables.logsinrom[Int(phase & 0xff)]
        }

        return envelopeCalcExp(UInt32(out) &+ (UInt32(envelope) << 3))
    }

    // opl3.c:259 OPL3_EnvelopeCalcSin2
    static func envelopeCalcSin2(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var out: UInt16 = 0
        let phase = phase & 0x3ff
        if phase & 0x100 != 0 {
            out = OPL3Tables.logsinrom[Int((phase & 0xff) ^ 0xff)]
        } else {
            out = OPL3Tables.logsinrom[Int(phase & 0xff)]
        }

        return envelopeCalcExp(UInt32(out) &+ (UInt32(envelope) << 3))
    }

    // opl3.c:274 OPL3_EnvelopeCalcSin3
    static func envelopeCalcSin3(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var out: UInt16 = 0
        let phase = phase & 0x3ff
        if phase & 0x100 != 0 {
            out = 0x1000
        } else {
            out = OPL3Tables.logsinrom[Int(phase & 0xff)]
        }

        return envelopeCalcExp(UInt32(out) &+ (UInt32(envelope) << 3))
    }

    // opl3.c:289 OPL3_EnvelopeCalcSin4
    static func envelopeCalcSin4(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var out: UInt16 = 0
        var neg: UInt16 = 0
        let phase = phase & 0x3ff
        if (phase & 0x300) == 0x100 {
            neg = 0xffff
        }

        if phase & 0x200 != 0 {
            out = 0x1000
        } else if phase & 0x80 != 0 {
            out = OPL3Tables.logsinrom[Int(((phase ^ 0xff) << 1) & 0xff)]
        } else {
            out = OPL3Tables.logsinrom[Int((phase << 1) & 0xff)]
        }

        let value = envelopeCalcExp(UInt32(out) &+ (UInt32(envelope) << 3))
        return Int16(truncatingIfNeeded: Int32(value) ^ Int32(neg))
    }

    // opl3.c:313 OPL3_EnvelopeCalcSin5
    static func envelopeCalcSin5(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var out: UInt16 = 0
        let phase = phase & 0x3ff
        if phase & 0x200 != 0 {
            out = 0x1000
        } else if phase & 0x80 != 0 {
            out = OPL3Tables.logsinrom[Int(((phase ^ 0xff) << 1) & 0xff)]
        } else {
            out = OPL3Tables.logsinrom[Int((phase << 1) & 0xff)]
        }

        return envelopeCalcExp(UInt32(out) &+ (UInt32(envelope) << 3))
    }

    // opl3.c:332 OPL3_EnvelopeCalcSin6
    static func envelopeCalcSin6(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var neg: UInt16 = 0
        let phase = phase & 0x3ff
        if phase & 0x200 != 0 {
            neg = 0xffff
        }

        let value = envelopeCalcExp(UInt32(envelope) << 3)
        return Int16(truncatingIfNeeded: Int32(value) ^ Int32(neg))
    }

    // opl3.c:343 OPL3_EnvelopeCalcSin7
    static func envelopeCalcSin7(_ phase: UInt16, _ envelope: UInt16) -> Int16 {
        var out: UInt16 = 0
        var neg: UInt16 = 0
        var phase = phase & 0x3ff
        if phase & 0x200 != 0 {
            neg = 0xffff
            phase = (phase & 0x1ff) ^ 0x1ff
        }

        out = phase << 3
        let value = envelopeCalcExp(UInt32(out) &+ (UInt32(envelope) << 3))
        return Int16(truncatingIfNeeded: Int32(value) ^ Int32(neg))
    }

    // opl3.c:357 envelope_sin[8]
    static let envelopeSin: [@Sendable (UInt16, UInt16) -> Int16] = [
        envelopeCalcSin0,
        envelopeCalcSin1,
        envelopeCalcSin2,
        envelopeCalcSin3,
        envelopeCalcSin4,
        envelopeCalcSin5,
        envelopeCalcSin6,
        envelopeCalcSin7,
    ]
}
