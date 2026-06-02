//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3Chip.swift
//  SwiftOPL3 — public surface + internal state of the OPL3 (YMF262) chip core.
//
//  Faithful transcription of Nuked-OPL3 `opl3.c` / `opl3.h` (Nuke.YKT, LGPL-2.1,
//  version 1.8, pinned commit cfedb09e). The chip is a `final class` holding the
//  `slot[36]` / `channel[18]` arrays and all scalar state; the Nuked pointers are
//  modelled as indices (see OPL3Types.swift). Processing functions live in
//  extensions (OPL3*.swift) and mutate `slot[i]` / `channel[c]` in place.
//
//  Native sample rate is 49 716 Hz; `generateResampled()` interpolates to the
//  rate passed at `init`/`reset` exactly as `OPL3_GenerateResampled` does.

import Foundation

public final class OPL3Chip {

    /// Native OPL3 sample rate, 14318181 / 288.
    public static let nativeSampleRate: UInt32 = 49_716

    var sampleRate: UInt32

    // ≈ opl3_chip (opl3.h:114). `zeromod` is not stored: every reference to
    // `&chip->zeromod` is modelled by `SampleRef.zero` / `TremRef.zero`.
    //
    // Performance: the 36 slots / 18 channels are touched on the order of a
    // million times per second. Backing them with `UnsafeMutableBufferPointer`
    // rather than Swift `Array` removes the dynamic exclusivity-enforcement
    // (`swift_beginAccess`/`endAccess`), COW-uniqueness, and release-mode bounds
    // overhead that otherwise dominated the hot loop — call sites (`slot[i].x`)
    // are unchanged, and `Slot`/`Channel` are trivial value types so the raw
    // buffers need no deinitialization. Both are owned for the chip's lifetime.
    let channel: UnsafeMutableBufferPointer<Channel>
    let slot: UnsafeMutableBufferPointer<Slot>
    var timer: UInt16 = 0
    var egTimer: UInt64 = 0
    var egTimerrem: UInt8 = 0
    var egState: UInt8 = 0
    var egAdd: UInt8 = 0
    var egTimerLo: UInt8 = 0
    var newm: UInt8 = 0
    var nts: UInt8 = 0
    var rhy: UInt8 = 0
    var vibpos: UInt8 = 0
    var vibshift: UInt8 = 0
    var tremolo: UInt8 = 0
    var tremolopos: UInt8 = 0
    var tremoloshift: UInt8 = 0
    var noise: UInt32 = 0
    var mixbuff: (Int32, Int32, Int32, Int32) = (0, 0, 0, 0)
    var rmHHBit2: UInt8 = 0
    var rmHHBit3: UInt8 = 0
    var rmHHBit7: UInt8 = 0
    var rmHHBit8: UInt8 = 0
    var rmTCBit3: UInt8 = 0
    var rmTCBit5: UInt8 = 0

    // OPL3L resampler.
    var rateratio: Int32 = 0
    var samplecnt: Int32 = 0
    var oldsamples: (Int16, Int16, Int16, Int16) = (0, 0, 0, 0)
    var samples: (Int16, Int16, Int16, Int16) = (0, 0, 0, 0)

    // Timed write buffer.
    var writebufSamplecnt: UInt64 = 0
    var writebufCur: UInt32 = 0
    var writebufLast: UInt32 = 0
    var writebufLasttime: UInt64 = 0
    // Also an unsafe buffer: the drain loop reads `writebuf[cur].time` every
    // sample, so the array exclusivity/COW/bounds overhead showed up in the hot
    // path too. Owned for the chip's lifetime; `WriteBuf` is a trivial value type.
    let writebuf: UnsafeMutableBufferPointer<WriteBuf>

    /// ≈ `OPL3_Reset(&chip, samplerate)`.
    public init(sampleRate: UInt32 = OPL3Chip.nativeSampleRate) {
        channel = UnsafeMutableBufferPointer<Channel>.allocate(capacity: 18)
        channel.initialize(repeating: Channel())
        slot = UnsafeMutableBufferPointer<Slot>.allocate(capacity: 36)
        slot.initialize(repeating: Slot())
        writebuf = UnsafeMutableBufferPointer<WriteBuf>.allocate(capacity: OPL3Const.writeBufSize)
        writebuf.initialize(repeating: WriteBuf())
        self.sampleRate = sampleRate
        reset(sampleRate: sampleRate)
    }

    deinit {
        channel.deallocate()
        slot.deallocate()
        writebuf.deallocate()
    }

    // MARK: - Source resolution (the Nuked pointer dereferences)

    /// Resolves a `SampleRef` to the live `int16_t` it points at (`*slot->mod`,
    /// `*channel->out[k]`). `.zero` ≈ `*(&chip->zeromod)`.
    @inline(__always)
    func sample(at ref: SampleRef) -> Int16 {
        switch ref {
            case .zero: return 0
            case .slotOut(let i): return slot[i].out
            case .slotFbmod(let i): return slot[i].fbmod
        }
    }

    /// Resolves a `TremRef` to the live `uint8_t` it points at (`*slot->trem`).
    /// `.zero` ≈ `*(uint8_t*)&chip->zeromod`, which reads 0.
    @inline(__always)
    func tremValue(_ ref: TremRef) -> UInt8 {
        switch ref {
            case .zero: return 0
            case .tremolo: return tremolo
        }
    }

    // MARK: - Reset

    /// ≈ `OPL3_Reset` (opl3.c:1293).
    public func reset(sampleRate: UInt32) {
        self.sampleRate = sampleRate

        // memset(chip, 0, sizeof(opl3_chip)). Buffers are owned for the chip's
        // lifetime, so re-initialize their contents in place rather than realloc.
        for i in 0 ..< 18 { channel[i] = Channel() }
        for i in 0 ..< 36 { slot[i] = Slot() }
        timer = 0
        egTimer = 0
        egTimerrem = 0
        egState = 0
        egAdd = 0
        egTimerLo = 0
        newm = 0
        nts = 0
        rhy = 0
        vibpos = 0
        vibshift = 0
        tremolo = 0
        tremolopos = 0
        tremoloshift = 0
        noise = 0
        mixbuff = (0, 0, 0, 0)
        rmHHBit2 = 0
        rmHHBit3 = 0
        rmHHBit7 = 0
        rmHHBit8 = 0
        rmTCBit3 = 0
        rmTCBit5 = 0
        rateratio = 0
        samplecnt = 0
        oldsamples = (0, 0, 0, 0)
        samples = (0, 0, 0, 0)
        writebufSamplecnt = 0
        writebufCur = 0
        writebufLast = 0
        writebufLasttime = 0
        for i in 0 ..< OPL3Const.writeBufSize { writebuf[i] = WriteBuf() }

        for slotnum in 0 ..< 36 {
            slot[slotnum].mod = .zero
            slot[slotnum].egRout = 0x1ff
            slot[slotnum].egOut = 0x1ff
            slot[slotnum].egGen = OPL3Const.envRelease
            slot[slotnum].trem = .zero
            slot[slotnum].slotNum = UInt8(slotnum)
        }

        for channum in 0 ..< 18 {
            let localChSlot = Int(OPL3Tables.chSlot[channum])
            channel[channum].slotz.0 = localChSlot
            channel[channum].slotz.1 = localChSlot + 3
            slot[localChSlot].channel = channum
            slot[localChSlot + 3].channel = channum
            if channum % 9 < 3 {
                channel[channum].pair = channum + 3
            } else if channum % 9 < 6 {
                channel[channum].pair = channum - 3
            }

            channel[channum].out = ( .zero, .zero, .zero, .zero )
            channel[channum].chtype = OPL3Const.ch2op
            channel[channum].cha = 0xffff
            channel[channum].chb = 0xffff
            channel[channum].chNum = UInt8(channum)
            channelSetupAlg(channum)
        }

        noise = 1
        rateratio = Int32(truncatingIfNeeded: (sampleRate &<< OPL3Const.rsmFrac) / OPL3Const.nativeFreq)
        tremoloshift = 4
        vibshift = 1
    }

    // MARK: - Algorithm routing

    /// ≈ `OPL3_ChannelSetupAlg` (opl3.c:848). Wires `slot.mod` / `channel.out`
    /// per the channel's algorithm. `&chip->zeromod` ⇒ `.zero`.
    func channelSetupAlg(_ c: Int) {
        let s0 = channel[c].slotz.0
        let s1 = channel[c].slotz.1

        if channel[c].chtype == OPL3Const.chDrum {
            if channel[c].chNum == 7 || channel[c].chNum == 8 {
                slot[s0].mod = .zero
                slot[s1].mod = .zero
                return
            }

            switch channel[c].alg & 0x01 {
                case 0x00:
                    slot[s0].mod = .slotFbmod(s0)
                    slot[s1].mod = .slotOut(s0)
                default:    // 0x01
                    slot[s0].mod = .slotFbmod(s0)
                    slot[s1].mod = .zero
            }
            return
        }

        if channel[c].alg & 0x08 != 0 {
            return
        }

        if channel[c].alg & 0x04 != 0 {
            let p = channel[c].pair
            let ps0 = channel[p].slotz.0
            let ps1 = channel[p].slotz.1
            channel[p].out = ( .zero, .zero, .zero, .zero )
            switch channel[c].alg & 0x03 {
                case 0x00:
                    slot[ps0].mod = .slotFbmod(ps0)
                    slot[ps1].mod = .slotOut(ps0)
                    slot[s0].mod = .slotOut(ps1)
                    slot[s1].mod = .slotOut(s0)
                    channel[c].out = ( .slotOut(s1), .zero, .zero, .zero )
                case 0x01:
                    slot[ps0].mod = .slotFbmod(ps0)
                    slot[ps1].mod = .slotOut(ps0)
                    slot[s0].mod = .zero
                    slot[s1].mod = .slotOut(s0)
                    channel[c].out = ( .slotOut(ps1), .slotOut(s1), .zero, .zero )
                case 0x02:
                    slot[ps0].mod = .slotFbmod(ps0)
                    slot[ps1].mod = .zero
                    slot[s0].mod = .slotOut(ps1)
                    slot[s1].mod = .slotOut(s0)
                    channel[c].out = ( .slotOut(ps0), .slotOut(s1), .zero, .zero )
                default:    // 0x03
                    slot[ps0].mod = .slotFbmod(ps0)
                    slot[ps1].mod = .zero
                    slot[s0].mod = .slotOut(ps1)
                    slot[s1].mod = .zero
                    channel[c].out = ( .slotOut(ps0), .slotOut(s0), .slotOut(s1), .zero )
            }
        } else {
            switch channel[c].alg & 0x01 {
                case 0x00:
                    slot[s0].mod = .slotFbmod(s0)
                    slot[s1].mod = .slotOut(s0)
                    channel[c].out = ( .slotOut(s1), .zero, .zero, .zero )
                default:    // 0x01
                    slot[s0].mod = .slotFbmod(s0)
                    slot[s1].mod = .zero
                    channel[c].out = ( .slotOut(s0), .slotOut(s1), .zero, .zero )
            }
        }
    }

    // MARK: - Public surface (write/generate dispatch arrives in later slices)

    /// ≈ `OPL3_WriteReg`. Taps the register-trace seam.
    public func write(_ reg: UInt16, _ value: UInt8) {
        OPLLog.reg(reg, value)
        writeReg(reg, value)
    }

    /// ≈ `OPL3_WriteRegBuffered` (timed write queue).
    public func writeBuffered(_ reg: UInt16, _ value: UInt8) {
        OPLLog.reg(reg, value)
        writeRegBuffered(reg, value)
    }

    /// ≈ `OPL3_Generate` — one native-rate stereo sample (buf[0], buf[1]).
    public func generate() -> (left: Int16, right: Int16) {
        let s = generate4Ch()
        return (s.0, s.1)
    }

    /// ≈ `OPL3_GenerateResampled` — one sample at the configured `sampleRate`.
    public func generateResampled() -> (left: Int16, right: Int16) {
        let s = generate4ChResampled()
        return (s.0, s.1)
    }

    /// ≈ `OPL3_GenerateStream` — fill `buffer` with `frames` interleaved L/R
    /// resampled stereo samples (`buffer.count` must be ≥ `frames * 2`).
    public func generateStream(into buffer: inout [Int16], frames: Int) {
        for i in 0 ..< frames {
            let s = generateResampled()
            buffer[i * 2] = s.left
            buffer[i * 2 + 1] = s.right
        }
    }
}
