//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  AdLibDriver.swift
//  WestwoodADL — the Westwood/Kyra AdLib bytecode sequencer.
//
//  Faithful transcription of AdPlug `AdLibDriver` (adl.cpp, the ScummVM/Kyra
//  driver port). AdPlug commit 16442997. Every register write funnels through
//  `writeOPL`, which taps `OPLLog.reg` and the injected `OPLRegisterSink` — that
//  stream is the trace the parity golden aligns against AdPlug. See
//  Documentation/Architecture/WestwoodADL.md.
//
//  Pointer model: Nuked-style. `const uint8 *dataptr` (a pointer into the
//  resident sound data) becomes an `Int?` index into `soundData` (nil = the C
//  nullptr "channel stopped"); `getProgram`/`checkDataOffset` return such
//  indices. The two effect function-pointers become small enums. Field names
//  track AdPlug to keep the transcription verifiable against adl.cpp:line.

import SwiftOPL3

/// The driver's single register-output choke point. The real sink forwards to an
/// `OPL3Chip`; tests inject a recorder to capture the timed write trace.
public protocol OPLRegisterSink: AnyObject {
    func writeRegister(_ reg: UInt8, _ value: UInt8)
}

final class AdLibDriver {
    enum PrimaryEffectKind { case none, slide, vibrato }
    enum SecondaryEffectKind { case none, effect1 }

    // ≈ AdLibDriver::Channel (adl.cpp:184). Defaults are the memset-0 state.
    struct Channel {
        var lock = false
        var repeating = false
        var opExtraLevel2: UInt8 = 0
        var dataptr: Int? = nil
        var duration: UInt8 = 0
        var repeatCounter: UInt8 = 0
        var baseOctave: Int8 = 0
        var priority: UInt8 = 0
        var dataptrStackPos: Int = 0
        // ≈ `const uint8 *dataptrStack[4]` (adl.cpp:184). A fixed 4-slot tuple, not
        // a Swift `[Int?]`, so `Channel` stays a trivial value type: `Channel()`
        // copies are a plain memcpy (no ARC), and `initChannel` — called per
        // note/program setup at the 72 Hz tick — no longer heap-allocates a stack
        // array each time. Real-time-audio safe: zero allocation on the tick path.
        var dataptrStack: (Int?, Int?, Int?, Int?) = (nil, nil, nil, nil)
        var baseNote: Int8 = 0
        var slideTempo: UInt8 = 0
        var slideTimer: UInt8 = 0
        var slideStep: Int16 = 0
        var vibratoStep: Int16 = 0
        var vibratoStepRange: UInt8 = 0
        var vibratoStepsCountdown: UInt8 = 0
        var vibratoNumSteps: UInt8 = 0
        var vibratoDelay: UInt8 = 0
        var vibratoTempo: UInt8 = 0
        var vibratoTimer: UInt8 = 0
        var vibratoDelayCountdown: UInt8 = 0
        var opExtraLevel1: UInt8 = 0
        var spacing2: UInt8 = 0
        var baseFreq: UInt8 = 0
        var tempo: UInt8 = 0
        var timer: UInt8 = 0
        var regAx: UInt8 = 0
        var regBx: UInt8 = 0
        var primaryEffect: PrimaryEffectKind = .none
        var secondaryEffect: SecondaryEffectKind = .none
        var fractionalSpacing: UInt8 = 0
        var opLevel1: UInt8 = 0
        var opLevel2: UInt8 = 0
        var opExtraLevel3: UInt8 = 0
        var twoChan: UInt8 = 0
        var unk39: UInt8 = 0
        var unk40: UInt8 = 0
        var spacing1: UInt8 = 0
        var durationRandomness: UInt8 = 0
        var secondaryEffectTempo: UInt8 = 0
        var secondaryEffectTimer: UInt8 = 0
        var secondaryEffectSize: Int8 = 0
        var secondaryEffectPos: Int8 = 0
        var secondaryEffectRegbase: UInt8 = 0
        var secondaryEffectData: UInt16 = 0
        var tempoReset: UInt8 = 0
        var rawNote: UInt8 = 0
        var pitchBend: Int8 = 0
        var volumeModifier: UInt8 = 0

        // The `dataptrStack[4]` depth — replaces the former Array `.count`.
        static let dataptrStackCount = 4

        // Indexed access into the fixed `dataptrStack` tuple. `pos` is always in
        // 0..<4 at the call sites (guarded by `dataptrStackPos`), so the `default`
        // is slot 3.
        @inline(__always)
        func dataptrAtStack(_ pos: Int) -> Int? {
            return switch pos {
                case 0: dataptrStack.0
                case 1: dataptrStack.1
                case 2: dataptrStack.2
                default: dataptrStack.3
            }
        }

        @inline(__always)
        mutating func setDataptrAtStack(_ pos: Int, _ value: Int?) {
            switch pos {
                case 0: dataptrStack.0 = value
                case 1: dataptrStack.1 = value
                case 2: dataptrStack.2 = value
                default: dataptrStack.3 = value
            }
        }
    }

    struct QueueEntry {
        var data: Int? = nil
        var id: UInt8 = 0
        var volume: UInt8 = 0
    }

    // Strong, not `weak`: `writeOPL` (the choke point for *every* register write)
    // would otherwise pay an atomic weak-side-table load per write. There is no
    // retain cycle — ownership runs ADLPlayer → driver → sink → chip, and nothing
    // points back — so a strong reference is safe and removes that ARC traffic.
    var sink: OPLRegisterSink?

    var _curChannel = 0
    var _soundTrigger: UInt8 = 0
    var _rnd: UInt16 = 0x1234

    var _beatDivider: UInt8 = 0
    var _beatDivCnt: UInt8 = 0
    var _callbackTimer: UInt8 = 0xFF
    var _beatCounter: UInt8 = 0
    var _beatWaiting: UInt8 = 0
    var _opLevelBD: UInt8 = 0
    var _opLevelHH: UInt8 = 0
    var _opLevelSD: UInt8 = 0
    var _opLevelTT: UInt8 = 0
    var _opLevelCY: UInt8 = 0
    var _opExtraLevel1HH: UInt8 = 0
    var _opExtraLevel2HH: UInt8 = 0
    var _opExtraLevel1CY: UInt8 = 0
    var _opExtraLevel2CY: UInt8 = 0
    var _opExtraLevel2TT: UInt8 = 0
    var _opExtraLevel1TT: UInt8 = 0
    var _opExtraLevel1SD: UInt8 = 0
    var _opExtraLevel2SD: UInt8 = 0
    var _opExtraLevel1BD: UInt8 = 0
    var _opExtraLevel2BD: UInt8 = 0

    // Owned raw buffer, not `[UInt8]`: the data blob is read on essentially every
    // opcode and *written* by `adjustSfxData`. As a class-stored Array, each
    // `self._soundData[i] = …` write could COW-copy the whole blob (the buffer
    // briefly looks non-unique through the property access), and the read path
    // paid bounds/exclusivity checks. A raw buffer has no refcount, so neither
    // happens. The parsed `[UInt8]` is copied in by `setSoundData`; freed and
    // re-allocated there and in `deinit`.
    var _soundData = UnsafeMutableBufferPointer<UInt8>(start: nil, count: 0)

    // Owned raw buffer, not `[QueueEntry]` — same class-stored-Array COW reason as
    // `_channels`. Trivial element; allocated in `init`, freed in `deinit`.
    let _programQueue: UnsafeMutableBufferPointer<QueueEntry>
    var _programStartTimeout = 0
    var _programQueueStart = 0
    var _programQueueEnd = 0
    var _retrySounds = false

    var _sfxPointer: Int? = nil
    var _sfxPriority = 0
    var _sfxVelocity = 0

    // The hot one. As a class-stored `[Channel]`, every per-tick
    // `self._channels[c].field = …` made the buffer briefly non-unique through the
    // property load, so `beginCOWMutation` copied all 10 channels on each mutation
    // — the dominant cost in the Time Profiler (beginCOWMutation #1, plus
    // swift_allocObject). A raw buffer (a `let` holding a pointer, no refcount)
    // mutates in place: no COW, no allocation, no bounds/exclusivity checks. This
    // is the same model the chip uses for `slot`/`channel`. `Channel` is a trivial
    // value type (since `dataptrStack` became a tuple), so the buffer needs no
    // deinitialization. Allocated in `init`, freed in `deinit`.
    let _channels: UnsafeMutableBufferPointer<Channel>

    var _vibratoAndAMDepthBits: UInt8 = 0
    var _rhythmSectionBits: UInt8 = 0

    var _curRegOffset: UInt8 = 0
    var _tempo: UInt8 = 0

    var _tablePtr1: [UInt8] = []
    var _tablePtr2: [UInt8] = []

    var _syncJumpMask: UInt16 = 0

    var _musicVolume: UInt8 = 0xFF
    var _sfxVolume: UInt8 = 0xFF

    var _numPrograms = 0
    var _version = 0

    var soundTrigger: Int { Int(_soundTrigger) }

    init() {
        _channels = UnsafeMutableBufferPointer<Channel>.allocate(capacity: 10)
        _channels.initialize(repeating: Channel())
        _programQueue = UnsafeMutableBufferPointer<QueueEntry>.allocate(capacity: 16)
        _programQueue.initialize(repeating: QueueEntry())
    }

    deinit {
        _channels.deallocate()
        _programQueue.deallocate()
        if _soundData.baseAddress != nil {
            _soundData.deallocate()
        }
    }

    // MARK: - Setup / public-ish surface (adl.cpp:586..)

    func setVersion(_ v: Int) {
        _version = v
        _numPrograms = (v == 1) ? 150 : ((v == 4) ? 500 : 250)
    }

    func initDriver() {
        resetAdLibState()
    }

    func setSoundData(_ data: [UInt8]) {
        _programQueueStart = 0
        _programQueueEnd = 0
        _programQueue[0] = QueueEntry()
        _sfxPointer = nil

        // Copy the parsed bytes into an owned raw buffer (see `_soundData` decl).
        if _soundData.baseAddress != nil {
            _soundData.deallocate()
        }
        if data.isEmpty {
            _soundData = UnsafeMutableBufferPointer<UInt8>(start: nil, count: 0)
        } else {
            let buf = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: data.count)
            _ = buf.initialize(from: data)
            _soundData = buf
        }
    }

    func startSound(_ track: Int, _ volume: Int) {
        guard
            let trackData = getProgram(track)
        else {
            return
        }

        if _programQueueEnd == _programQueueStart && _programQueue[_programQueueEnd].data != nil {
            return
        }

        _programQueue[_programQueueEnd] = QueueEntry(
            data: trackData,
            id: UInt8(truncatingIfNeeded: track),
            volume: UInt8(truncatingIfNeeded: volume)
        )
        _programQueueEnd = (_programQueueEnd + 1) & 15
    }

    func isChannelPlaying(_ channel: Int) -> Bool {
        _channels[channel].dataptr != nil
    }

    func isChannelRepeating(_ i: Int) -> Bool {
        _channels[i].repeating
    }

    func stopAllChannels() {
        for channel in 0 ... 9 {
            _curChannel = channel
            _channels[_curChannel].priority = 0
            _channels[_curChannel].dataptr = nil
            if channel != 9 {
                noteOff()
            }
        }
        _retrySounds = false
        _programQueueStart = 0
        _programQueueEnd = 0
        _programQueue[0] = QueueEntry()
        _programStartTimeout = 0
    }

    // MARK: - Helpers

    @inline(__always)
    func clip(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        v < lo ? lo : (v > hi ? hi : v)
    }

    // checkValue (adl.cpp:260) — CLIP<int16>(val, 0, 0x3F).
    @inline(__always)
    func checkValue(_ v: Int) -> UInt8 {
        UInt8(clip(v, 0, 0x3F))
    }

    // advance (adl.cpp:266) — timer += tempo, returns wraparound.
    @inline(__always)
    func advance(_ timer: inout UInt8, _ tempo: UInt8) -> Bool {
        let old = timer
        timer = timer &+ tempo
        return timer < old
    }

    // checkDataOffset (adl.cpp:272) — bounds-checked pointer arithmetic.
    func checkDataOffset(_ ptr: Int?, _ n: Int) -> Int? {
        guard
            let offset = ptr
        else {
            return nil
        }

        if n >= -offset && n <= _soundData.count - offset {
            return ptr! + n
        }
        return nil
    }

    // getProgram (adl.cpp:286).
    func getProgram(_ progId: Int) -> Int? {
        if progId < 0 || progId >= _soundData.count / 2 {
            return nil
        }

        let offset = readLE16(2 * progId)
        if offset == 0 || offset >= _soundData.count {
            return nil
        }
        return offset
    }

    func getInstrument(_ instrumentId: Int) -> Int? {
        getProgram(_numPrograms + instrumentId)
    }

    @inline(__always)
    func readLE16(_ idx: Int) -> Int {
        Int(_soundData[idx]) | (Int(_soundData[idx + 1]) << 8)
    }

    @inline(__always)
    func readBE16(_ idx: Int) -> Int {
        (Int(_soundData[idx]) << 8) | Int(_soundData[idx + 1])
    }

    // getRandomNr (adl.cpp:1030).
    func getRandomNr() -> UInt16 {
        _rnd = _rnd &+ 0x9248
        let lowBits = _rnd & 7
        _rnd >>= 3
        _rnd |= (lowBits << 13)
        return _rnd
    }

    // writeOPL (adl.cpp:943) — the single OPL output choke point + trace tap.
    func writeOPL(_ reg: UInt8, _ val: UInt8) {
        OPLLog.reg(UInt16(reg), val)
        sink?.writeRegister(reg, val)
    }

    // MARK: - State init (adl.cpp:917..)

    func resetAdLibState() {
        _rnd = 0x1234
        writeOPL(0x01, 0x20)
        writeOPL(0x08, 0x00)
        writeOPL(0xBD, 0x00)
        initChannel(9)
        for loop in stride(from: 8, through: 0, by: -1) {
            writeOPL(0x40 + AdLibDriver.regOffset[loop], 0x3F)
            writeOPL(0x43 + AdLibDriver.regOffset[loop], 0x3F)
            initChannel(loop)
        }
    }

    // initChannel (adl.cpp:948).
    func initChannel(_ i: Int) {
        let backupEL2 = _channels[i].opExtraLevel2
        _channels[i] = Channel()
        _channels[i].opExtraLevel2 = backupEL2
        _channels[i].tempo = 0xFF
        _channels[i].priority = 0
        _channels[i].primaryEffect = .none
        _channels[i].secondaryEffect = .none
        _channels[i].spacing1 = 1
        _channels[i].lock = false
        _channels[i].repeating = false
    }

    // noteOff (adl.cpp:964) — operates on the current channel.
    func noteOff() {
        if _curChannel >= 9 {
            return
        }
        if _rhythmSectionBits != 0 && _curChannel >= 6 {
            return
        }

        _channels[_curChannel].regBx &= 0xDF
        writeOPL(0xB0 + UInt8(_curChannel), _channels[_curChannel].regBx)
    }

    // initAdlibChannel (adl.cpp:984).
    func initAdlibChannel(_ chan: Int) {
        if chan >= 9 {
            return
        }
        if _rhythmSectionBits != 0 && chan >= 6 {
            return
        }

        let offset = AdLibDriver.regOffset[chan]
        writeOPL(0x60 + offset, 0xFF)
        writeOPL(0x63 + offset, 0xFF)
        writeOPL(0x80 + offset, 0xFF)
        writeOPL(0x83 + offset, 0xFF)
        writeOPL(0xB0 + UInt8(chan), 0x00)
        writeOPL(0xB0 + UInt8(chan), 0x20)
    }

    // setupDuration (adl.cpp:1038).
    func setupDuration(_ duration: UInt8, _ c: Int) {
        if _channels[c].durationRandomness != 0 {
            let r = Int(getRandomNr()) & Int(_channels[c].durationRandomness)
            _channels[c].duration = duration &+ UInt8(truncatingIfNeeded: r)
            return
        }
        if _channels[c].fractionalSpacing != 0 {
            _channels[c].spacing2 = (duration >> 3) &* _channels[c].fractionalSpacing
        }
        _channels[c].duration = duration
    }

    // setupNote (adl.cpp:1052) — uses _curChannel for the OPL writes.
    func setupNote(_ rawNote: UInt8, _ c: Int, _ flag: Bool = false) {
        if _curChannel >= 9 {
            return
        }

        _channels[c].rawNote = rawNote

        var note = Int(Int8(truncatingIfNeeded: Int(rawNote & 0x0F) + Int(_channels[c].baseNote)))
        var octave = Int(Int8(truncatingIfNeeded: ((Int(rawNote) + Int(_channels[c].baseOctave)) >> 4) & 0x0F))

        if note >= 12 {
            octave += note / 12
            note %= 12
        } else if note < 0 {
            let octaves = -(note + 1) / 12 + 1
            octave -= octaves
            note += 12 * octaves
        }

        var freq = Int(AdLibDriver.freqTable[note]) + Int(_channels[c].baseFreq)

        if _channels[c].pitchBend != 0 || flag {
            let indexNote = clip(Int(rawNote & 0x0F), 0, 11)
            if _channels[c].pitchBend >= 0 {
                let table = AdLibDriver.pitchBendTables[indexNote + 2]
                freq += Int(table[clip(Int(_channels[c].pitchBend), 0, 31)])
            } else {
                let table = AdLibDriver.pitchBendTables[indexNote]
                freq -= Int(table[clip(-Int(_channels[c].pitchBend), 0, 31)])
            }
        }

        octave = clip(octave, 0, 7) << 2

        _channels[c].regAx = UInt8(truncatingIfNeeded: freq & 0xFF)
        _channels[c].regBx =
            (_channels[c].regBx & 0x20) | UInt8(truncatingIfNeeded: octave)
            | UInt8(truncatingIfNeeded: (freq >> 8) & 0x03)

        writeOPL(0xA0 + UInt8(_curChannel), _channels[c].regAx)
        writeOPL(0xB0 + UInt8(_curChannel), _channels[c].regBx)
    }

    // setupInstrument (adl.cpp:1115) — `regOffset`/`c` may differ from _curChannel
    // (rhythm section); the 0xC0 write + the >=9 guard use _curChannel.
    func setupInstrument(_ regOffset: UInt8, _ dataptr: Int?, _ c: Int) {
        if _curChannel >= 9 {
            return
        }
        guard
            var p = checkDataOffset(dataptr, 11) != nil ? dataptr : nil
        else {
            return
        }

        writeOPL(0x20 + regOffset, _soundData[p]); p += 1
        writeOPL(0x23 + regOffset, _soundData[p]); p += 1

        let temp = _soundData[p]; p += 1
        writeOPL(0xC0 + UInt8(_curChannel), temp)
        _channels[c].twoChan = temp & 1

        writeOPL(0xE0 + regOffset, _soundData[p]); p += 1
        writeOPL(0xE3 + regOffset, _soundData[p]); p += 1

        _channels[c].opLevel1 = _soundData[p]; p += 1
        _channels[c].opLevel2 = _soundData[p]; p += 1

        writeOPL(0x40 + regOffset, calculateOpLevel1(c))
        writeOPL(0x43 + regOffset, calculateOpLevel2(c))

        writeOPL(0x60 + regOffset, _soundData[p]); p += 1
        writeOPL(0x63 + regOffset, _soundData[p]); p += 1

        writeOPL(0x80 + regOffset, _soundData[p]); p += 1
        writeOPL(0x83 + regOffset, _soundData[p]); p += 1
    }

    // noteOn (adl.cpp:1170).
    func noteOn(_ c: Int) {
        if _curChannel >= 9 {
            return
        }

        _channels[c].regBx |= 0x20
        writeOPL(0xB0 + UInt8(_curChannel), _channels[c].regBx)

        let shift = 9 - clip(Int(_channels[c].vibratoStepRange), 0, 9)
        let freq = ((Int(_channels[c].regBx) << 8) | Int(_channels[c].regAx)) & 0x3FF
        _channels[c].vibratoStep = Int16(truncatingIfNeeded: (freq >> shift) & 0xFF)
        _channels[c].vibratoDelayCountdown = _channels[c].vibratoDelay
    }

    // adjustVolume (adl.cpp:1190).
    func adjustVolume(_ c: Int) {
        if _curChannel >= 9 {
            return
        }

        writeOPL(0x43 + AdLibDriver.regOffset[_curChannel], calculateOpLevel2(c))
        if _channels[c].twoChan != 0 {
            writeOPL(0x40 + AdLibDriver.regOffset[_curChannel], calculateOpLevel1(c))
        }
    }

    // calculateOpLevel1 (adl.cpp:1373) — reproduces the documented uint8 wrap "bug".
    func calculateOpLevel1(_ c: Int) -> UInt8 {
        var value = _channels[c].opLevel1 & 0x3F

        if _channels[c].twoChan != 0 {
            value = value &+ _channels[c].opExtraLevel1
            value = value &+ _channels[c].opExtraLevel2

            var level3 = UInt16(_channels[c].opExtraLevel3 ^ 0x3F) &* UInt16(_channels[c].volumeModifier)
            if level3 != 0 {
                level3 = level3 &+ 0x3F
                level3 >>= 8
            }

            value = value &+ UInt8(truncatingIfNeeded: level3 ^ 0x3F)
        }

        value = value > 0x3F ? 0x3F : value
        if _channels[c].volumeModifier == 0 {
            value = 0x3F
        }

        return value | (_channels[c].opLevel1 & 0xC0)
    }

    // calculateOpLevel2 (adl.cpp:1411).
    func calculateOpLevel2(_ c: Int) -> UInt8 {
        var value = _channels[c].opLevel2 & 0x3F

        value = value &+ _channels[c].opExtraLevel1
        value = value &+ _channels[c].opExtraLevel2

        var level3 = UInt16(_channels[c].opExtraLevel3 ^ 0x3F) &* UInt16(_channels[c].volumeModifier)
        if level3 != 0 {
            level3 = level3 &+ 0x3F
            level3 >>= 8
        }

        value = value &+ UInt8(truncatingIfNeeded: level3 ^ 0x3F)

        value = value > 0x3F ? 0x3F : value
        if _channels[c].volumeModifier == 0 {
            value = 0x3F
        }

        return value | (_channels[c].opLevel2 & 0xC0)
    }

    // MARK: - Effects (adl.cpp:1219..)

    func primaryEffectSlide(_ c: Int) {
        if _curChannel >= 9 {
            return
        }
        if !advance(&_channels[c].slideTimer, _channels[c].slideTempo) {
            return
        }

        var freq = Int16(truncatingIfNeeded: ((Int(_channels[c].regBx) & 0x03) << 8) | Int(_channels[c].regAx))
        var octave = _channels[c].regBx & 0x1C
        let noteOn = _channels[c].regBx & 0x20

        freq &+= Int16(clip(Int(_channels[c].slideStep), -0x3FF, 0x3FF))

        if _channels[c].slideStep >= 0 && freq >= 734 {
            freq >>= 1
            if (freq & 0x3FF) == 0 {
                freq += 1
            }
            octave = octave &+ 4
        } else if _channels[c].slideStep < 0 && freq < 388 {
            if freq < 0 {
                freq = 0
            }
            freq <<= 1
            if (freq & 0x3FF) == 0 {
                freq -= 1
            }
            octave = octave &- 4
        }

        _channels[c].regAx = UInt8(truncatingIfNeeded: Int(freq) & 0xFF)
        _channels[c].regBx = noteOn | (octave & 0x1C) | UInt8(truncatingIfNeeded: (Int(freq) >> 8) & 0x03)

        writeOPL(0xA0 + UInt8(_curChannel), _channels[c].regAx)
        writeOPL(0xB0 + UInt8(_curChannel), _channels[c].regBx)
    }

    func primaryEffectVibrato(_ c: Int) {
        if _curChannel >= 9 {
            return
        }

        if _channels[c].vibratoDelayCountdown != 0 {
            _channels[c].vibratoDelayCountdown -= 1
            return
        }

        if advance(&_channels[c].vibratoTimer, _channels[c].vibratoTempo) {
            _channels[c].vibratoStepsCountdown = _channels[c].vibratoStepsCountdown &- 1
            if _channels[c].vibratoStepsCountdown == 0 {
                _channels[c].vibratoStep = -_channels[c].vibratoStep
                _channels[c].vibratoStepsCountdown = _channels[c].vibratoNumSteps
            }

            var freq = ((Int(_channels[c].regBx) << 8) | Int(_channels[c].regAx)) & 0x3FF
            freq += Int(_channels[c].vibratoStep)

            _channels[c].regAx = UInt8(truncatingIfNeeded: freq & 0xFF)
            _channels[c].regBx = (_channels[c].regBx & 0xFC) | UInt8(truncatingIfNeeded: freq >> 8)

            writeOPL(0xA0 + UInt8(_curChannel), _channels[c].regAx)
            writeOPL(0xB0 + UInt8(_curChannel), _channels[c].regBx)
        }
    }

    func secondaryEffect1(_ c: Int) {
        if _curChannel >= 9 {
            return
        }

        if advance(&_channels[c].secondaryEffectTimer, _channels[c].secondaryEffectTempo) {
            _channels[c].secondaryEffectPos -= 1
            if _channels[c].secondaryEffectPos < 0 {
                _channels[c].secondaryEffectPos = _channels[c].secondaryEffectSize
            }

            let idx = Int(_channels[c].secondaryEffectData) + Int(_channels[c].secondaryEffectPos)
            writeOPL(_channels[c].secondaryEffectRegbase + _curRegOffset, _soundData[idx])
        }
    }

    // MARK: - Timer callback / program execution (adl.cpp:655..)

    func callback() {
        if _programStartTimeout != 0 {
            _programStartTimeout -= 1
        } else {
            setupPrograms()
        }
        executePrograms()

        if advance(&_callbackTimer, _tempo) {
            _beatDivCnt = _beatDivCnt &- 1
            if _beatDivCnt == 0 {
                _beatDivCnt = _beatDivider
                _beatCounter = _beatCounter &+ 1
            }
        }
    }

    func setupPrograms() {
        let entry = _programQueueStart  // index of the QueueEntry &entry
        var ptr = _programQueue[entry].data

        if _programQueueStart == _programQueueEnd && ptr == nil {
            return
        }

        var retrySound = QueueEntry()
        if _programQueue[entry].id == 0 {
            _retrySounds = true
        } else if _retrySounds {
            retrySound = _programQueue[entry]
        }

        let entryVolume = _programQueue[entry].volume
        _programQueue[entry].data = nil
        _programQueueStart = (_programQueueStart + 1) & 15

        guard
            checkDataOffset(ptr, 2) != nil
        else {
            return
        }

        let chan = Int(_soundData[ptr!])
        if chan > 9 || (chan < 9 && checkDataOffset(ptr, 4) == nil) {
            return
        }

        adjustSfxData(ptr!, Int(entryVolume))

        let priority = Int(_soundData[ptr! + 1])
        ptr = ptr! + 2

        if priority >= Int(_channels[chan].priority) {
            initChannel(chan)
            _channels[chan].priority = UInt8(truncatingIfNeeded: priority)
            _channels[chan].dataptr = ptr
            _channels[chan].tempo = 0xFF
            _channels[chan].timer = 0xFF
            _channels[chan].duration = 1

            if chan <= 5 {
                _channels[chan].volumeModifier = _musicVolume
            } else {
                _channels[chan].volumeModifier = _sfxVolume
            }

            initAdlibChannel(chan)
            _programStartTimeout = 2
            retrySound = QueueEntry()
        }

        if retrySound.data != nil {
            startSound(Int(retrySound.id), Int(retrySound.volume))
        }
    }

    func adjustSfxData(_ ptr: Int, _ volume: Int) {
        if let sfx = _sfxPointer {
            _soundData[sfx + 1] = UInt8(truncatingIfNeeded: _sfxPriority)
            _soundData[sfx + 3] = UInt8(truncatingIfNeeded: _sfxVelocity)
            _sfxPointer = nil
        }

        if _soundData[ptr] == 9 {
            return
        }

        _sfxPointer = ptr
        _sfxPriority = Int(_soundData[ptr + 1])
        _sfxVelocity = Int(_soundData[ptr + 3])

        if volume != 0xFF {
            if _version >= 3 {
                let newVal = ((((Int(_soundData[ptr + 3])) + 63) * volume) >> 8) & 0xFF
                _soundData[ptr + 3] = UInt8(truncatingIfNeeded: -newVal + 63)
                _soundData[ptr + 1] = UInt8(truncatingIfNeeded: (Int(_soundData[ptr + 1]) * volume) >> 8)
            } else {
                let newVal = ((_sfxVelocity << 2) ^ 0xFF) * volume
                _soundData[ptr + 3] = UInt8(truncatingIfNeeded: (newVal >> 10) ^ 0x3F)
                _soundData[ptr + 1] = UInt8(truncatingIfNeeded: newVal >> 11)
            }
        }
    }

    func executePrograms() {
        if _syncJumpMask != 0 {
            _curChannel = 9
            while _curChannel >= 0 {
                if (_syncJumpMask & (1 << _curChannel)) != 0 && _channels[_curChannel].dataptr != nil
                        && !_channels[_curChannel].lock {
                    break
                }
                _curChannel -= 1
            }

            if _curChannel < 0 {
                _curChannel = 9
                while _curChannel >= 0 {
                    if (_syncJumpMask & (1 << _curChannel)) != 0 {
                        _channels[_curChannel].lock = false
                    }
                    _curChannel -= 1
                }
            }
        }

        _curChannel = 9
        while _curChannel >= 0 {
            defer { _curChannel -= 1 }
            let c = _curChannel

            if _channels[c].dataptr == nil {
                continue
            }
            if _channels[c].lock && (_syncJumpMask & (1 << c)) != 0 {
                continue
            }

            if c == 9 {
                _curRegOffset = 0
            } else {
                _curRegOffset = AdLibDriver.regOffset[c]
            }

            if _channels[c].tempoReset != 0 {
                _channels[c].tempo = _tempo
            }

            var result = 1
            if advance(&_channels[c].timer, _channels[c].tempo) {
                _channels[c].duration = _channels[c].duration &- 1
                if _channels[c].duration != 0 {
                    if _channels[c].duration == _channels[c].spacing2 {
                        noteOff()
                    }
                    if _channels[c].duration == _channels[c].spacing1 && c != 9 {
                        noteOff()
                    }
                } else {
                    result = 0
                }
            }

            while result == 0 && _channels[c].dataptr != nil {
                var opcode: UInt8 = 0xFF
                if checkDataOffset(_channels[c].dataptr, 1) != nil {
                    let cur = _channels[c].dataptr!
                    opcode = _soundData[cur]
                    _channels[c].dataptr = cur + 1
                }

                if opcode & 0x80 != 0 {
                    let op = clip(Int(opcode & 0x7F), 0, AdLibDriver.parserOpcodeValues.count - 1)
                    let valuesCount = AdLibDriver.parserOpcodeValues[op]

                    guard
                        checkDataOffset(_channels[c].dataptr, valuesCount) != nil
                    else {
                        result = update_stopChannel(c, 0)
                        break
                    }

                    let valuesIdx = _channels[c].dataptr!
                    _channels[c].dataptr = valuesIdx + valuesCount
                    result = callParserOpcode(op, c, valuesIdx)
                } else {
                    guard
                        checkDataOffset(_channels[c].dataptr, 1) != nil
                    else {
                        result = update_stopChannel(c, 0)
                        break
                    }

                    let cur = _channels[c].dataptr!
                    let duration = _soundData[cur]
                    _channels[c].dataptr = cur + 1
                    setupNote(opcode, c)
                    noteOn(c)
                    setupDuration(duration, c)
                    result = duration != 0 ? 1 : 0
                }
            }

            if result == 1 {
                switch _channels[c].primaryEffect {
                    case .slide: primaryEffectSlide(c)
                    case .vibrato: primaryEffectVibrato(c)
                    case .none: break
                }
                switch _channels[c].secondaryEffect {
                    case .effect1: secondaryEffect1(c)
                    case .none: break
                }
            }
        }
    }
}
