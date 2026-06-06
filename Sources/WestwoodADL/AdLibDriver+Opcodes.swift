//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  AdLibDriver+Opcodes.swift
//  WestwoodADL — the parser opcode callbacks, dispatch, and static ROM tables.
//
//  Faithful transcription of the `update_*` opcodes (adl.cpp:1439..2220), the
//  `_parserOpcodeTable` (adl.cpp:2226), and the data tables `_regOffset`,
//  `_freqTable`, `_unkTable2*`, `_pitchBendTables` (adl.cpp:2348..2511).
//  AdPlug commit 16442997. Opcode return codes: 0 = keep parsing, 1 = stop +
//  run effects, 2 = stop, no effects.
//
//  `values` is an index into `_soundData` (the C `const uint8 *values`); signed
//  reads use `Int8(bitPattern:)` / sign-extended 16-bit helpers, exactly as the
//  C casts to `int8`/`int16`.

extension AdLibDriver {
    @inline(__always)
    private func signed16LE(_ values: Int) -> Int {
        Int(Int16(bitPattern: UInt16(readLE16(values))))
    }

    func callParserOpcode(_ op: Int, _ c: Int, _ values: Int) -> Int {
        return switch op {
            case 0: update_setRepeat(c, values)
            case 1: update_checkRepeat(c, values)
            case 2: update_setupProgram(c, values)
            case 3: update_setNoteSpacing(c, values)
            case 4: update_jump(c, values)
            case 5: update_jumpToSubroutine(c, values)
            case 6: update_returnFromSubroutine(c, values)
            case 7: update_setBaseOctave(c, values)
            case 9: update_playRest(c, values)
            case 10: update_writeAdLib(c, values)
            case 11: update_setupNoteAndDuration(c, values)
            case 12: update_setBaseNote(c, values)
            case 13: update_setupSecondaryEffect1(c, values)
            case 14: update_stopOtherChannel(c, values)
            case 15: update_waitForEndOfProgram(c, values)
            case 16: update_setupInstrument(c, values)
            case 17: update_setupPrimaryEffectSlide(c, values)
            case 18: update_removePrimaryEffectSlide(c, values)
            case 19: update_setBaseFreq(c, values)
            case 21: update_setupPrimaryEffectVibrato(c, values)
            case 26: update_setPriority(c, values)
            case 28: update_setBeat(c, values)
            case 29: update_waitForNextBeat(c, values)
            case 30: update_setExtraLevel1(c, values)
            case 32: update_setupDuration(c, values)
            case 33: update_playNote(c, values)
            case 36: update_setFractionalNoteSpacing(c, values)
            case 38: update_setTempo(c, values)
            case 39: update_removeSecondaryEffect1(c, values)
            case 41: update_setChannelTempo(c, values)
            case 43: update_setExtraLevel3(c, values)
            case 44: update_setExtraLevel2(c, values)
            case 45: update_changeExtraLevel2(c, values)
            case 46: update_setAMDepth(c, values)
            case 47: update_setVibratoDepth(c, values)
            case 48: update_changeExtraLevel1(c, values)
            case 51: update_clearChannel(c, values)
            case 53: update_changeNoteRandomly(c, values)
            case 54: update_removePrimaryEffectVibrato(c, values)
            case 57: update_pitchBend(c, values)
            case 58: update_resetToGlobalTempo(c, values)
            case 59, 64: update_nop(c, values)
            case 60: update_setDurationRandomness(c, values)
            case 61: update_changeChannelTempo(c, values)
            case 63: updateCallback46(c, values)
            case 65: update_setupRhythmSection(c, values)
            case 66: update_playRhythmSection(c, values)
            case 67: update_removeRhythmSection(c, values)
            case 68: update_setRhythmLevel2(c, values)
            case 69: update_changeRhythmLevel1(c, values)
            case 70: update_setRhythmLevel1(c, values)
            case 71: update_setSoundTrigger(c, values)
            case 72: update_setTempoReset(c, values)
            case 73: updateCallback56(c, values)
            default: update_stopChannel(c, values)  // 8, 20, 22.. unused slots
        }
    }

    func update_setRepeat(_ c: Int, _ values: Int) -> Int {
        _channels[c].repeatCounter = _soundData[values]
        return 0
    }

    func update_checkRepeat(_ c: Int, _ values: Int) -> Int {
        _channels[c].repeatCounter = _channels[c].repeatCounter &- 1
        if _channels[c].repeatCounter != 0 {
            let add = signed16LE(values)
            if checkDataOffset(_channels[c].dataptr, add) != nil {
                _channels[c].dataptr = _channels[c].dataptr! + add
            }
        }
        return 0
    }

    func update_setupProgram(_ c: Int, _ values: Int) -> Int {
        if _soundData[values] == 0xFF {
            return 0
        }

        let ptr = getProgram(Int(_soundData[values]))
        guard
            checkDataOffset(ptr, 2) != nil
        else {
            return 0
        }

        var p = ptr!
        let chan = Int(_soundData[p]); p += 1
        let priority = Int(_soundData[p]); p += 1

        if chan > 9 {
            return 0
        }

        if priority >= Int(_channels[chan].priority) {
            let dataptrBackUp = _channels[c].dataptr
            _programStartTimeout = 2
            initChannel(chan)
            _channels[chan].priority = UInt8(truncatingIfNeeded: priority)
            _channels[chan].dataptr = p
            _channels[chan].tempo = 0xFF
            _channels[chan].timer = 0xFF
            _channels[chan].duration = 1
            _channels[chan].volumeModifier = (chan <= 5) ? _musicVolume : _sfxVolume
            initAdlibChannel(chan)
            _channels[c].dataptr = dataptrBackUp
        }
        return 0
    }

    func update_setNoteSpacing(_ c: Int, _ values: Int) -> Int {
        _channels[c].spacing1 = _soundData[values]
        return 0
    }

    func update_jump(_ c: Int, _ values: Int) -> Int {
        let add = signed16LE(values)
        if _version == 1 {
            _channels[c].dataptr = checkDataOffset(0, add - 191)
        } else {
            _channels[c].dataptr = checkDataOffset(_channels[c].dataptr, add)
        }

        if _channels[c].dataptr == nil {
            return update_stopChannel(c, values)
        }
        if (_syncJumpMask & (UInt16(1) << UInt16(c))) != 0 {
            _channels[c].lock = true
        }
        if add < 0 {
            _channels[c].repeating = true
        }
        return 0
    }

    func update_jumpToSubroutine(_ c: Int, _ values: Int) -> Int {
        let add = signed16LE(values)
        if _channels[c].dataptrStackPos >= Channel.dataptrStackCount {
            return 0
        }

        _channels[c].setDataptrAtStack(_channels[c].dataptrStackPos, _channels[c].dataptr)
        _channels[c].dataptrStackPos += 1
        if _version < 3 {
            _channels[c].dataptr = checkDataOffset(0, add - 191)
        } else {
            _channels[c].dataptr = checkDataOffset(_channels[c].dataptr, add)
        }

        if _channels[c].dataptr == nil {
            _channels[c].dataptrStackPos -= 1
            _channels[c].dataptr = _channels[c].dataptrAtStack(_channels[c].dataptrStackPos)
        }
        return 0
    }

    func update_returnFromSubroutine(_ c: Int, _ values: Int) -> Int {
        if _channels[c].dataptrStackPos == 0 {
            return update_stopChannel(c, values)
        }

        _channels[c].dataptrStackPos -= 1
        _channels[c].dataptr = _channels[c].dataptrAtStack(_channels[c].dataptrStackPos)
        return 0
    }

    func update_setBaseOctave(_ c: Int, _ values: Int) -> Int {
        _channels[c].baseOctave = Int8(bitPattern: _soundData[values])
        return 0
    }

    func update_stopChannel(_ c: Int, _ values: Int) -> Int {
        _channels[c].priority = 0
        if _curChannel != 9 {
            noteOff()
        }
        _channels[c].dataptr = nil
        return 2
    }

    func update_playRest(_ c: Int, _ values: Int) -> Int {
        setupDuration(_soundData[values], c)
        noteOff()
        return _soundData[values] != 0 ? 1 : 0
    }

    func update_writeAdLib(_ c: Int, _ values: Int) -> Int {
        writeOPL(_soundData[values], _soundData[values + 1])
        return 0
    }

    func update_setupNoteAndDuration(_ c: Int, _ values: Int) -> Int {
        setupNote(_soundData[values], c)
        setupDuration(_soundData[values + 1], c)
        return _soundData[values + 1] != 0 ? 1 : 0
    }

    func update_setBaseNote(_ c: Int, _ values: Int) -> Int {
        _channels[c].baseNote = Int8(bitPattern: _soundData[values])
        return 0
    }

    func update_setupSecondaryEffect1(_ c: Int, _ values: Int) -> Int {
        _channels[c].secondaryEffectTimer = _soundData[values]
        _channels[c].secondaryEffectTempo = _soundData[values]
        _channels[c].secondaryEffectSize = Int8(bitPattern: _soundData[values + 1])
        _channels[c].secondaryEffectPos = Int8(bitPattern: _soundData[values + 1])
        _channels[c].secondaryEffectRegbase = _soundData[values + 2]
        _channels[c].secondaryEffectData = UInt16(truncatingIfNeeded: readLE16(values + 3) - 191)
        _channels[c].secondaryEffect = .effect1

        let start = Int(_channels[c].secondaryEffectData) + Int(_channels[c].secondaryEffectSize)
        if start < 0 || start >= _soundData.count {
            _channels[c].secondaryEffect = .none
        }
        return 0
    }

    func update_stopOtherChannel(_ c: Int, _ values: Int) -> Int {
        if _soundData[values] > 9 {
            return 0
        }

        let dataptrBackUp = _channels[c].dataptr
        let other = Int(_soundData[values])
        _channels[other].duration = 0
        _channels[other].priority = 0
        _channels[other].dataptr = nil
        _channels[c].dataptr = dataptrBackUp
        return 0
    }

    func update_waitForEndOfProgram(_ c: Int, _ values: Int) -> Int {
        guard
            let ptr = getProgram(Int(_soundData[values]))
        else {
            return 0
        }

        let chan = Int(_soundData[ptr])
        if chan > 9 || _channels[chan].dataptr == nil {
            return 0
        }

        if _channels[chan].repeating {
            _channels[c].repeating = true
        }
        _channels[c].dataptr = _channels[c].dataptr! - 2
        return 2
    }

    func update_setupInstrument(_ c: Int, _ values: Int) -> Int {
        guard
            let instrument = getInstrument(Int(_soundData[values]))
        else {
            return 0
        }

        setupInstrument(_curRegOffset, instrument, c)
        return 0
    }

    func update_setupPrimaryEffectSlide(_ c: Int, _ values: Int) -> Int {
        _channels[c].slideTempo = _soundData[values]
        _channels[c].slideStep = Int16(bitPattern: UInt16(readBE16(values + 1)))
        _channels[c].primaryEffect = .slide
        _channels[c].slideTimer = 0xFF
        return 0
    }

    func update_removePrimaryEffectSlide(_ c: Int, _ values: Int) -> Int {
        _channels[c].primaryEffect = .none
        _channels[c].slideStep = 0
        return 0
    }

    func update_setBaseFreq(_ c: Int, _ values: Int) -> Int {
        _channels[c].baseFreq = _soundData[values]
        return 0
    }

    func update_setupPrimaryEffectVibrato(_ c: Int, _ values: Int) -> Int {
        _channels[c].vibratoTempo = _soundData[values]
        _channels[c].vibratoStepRange = _soundData[values + 1]
        _channels[c].vibratoStepsCountdown = _soundData[values + 2] &+ 1
        _channels[c].vibratoNumSteps = UInt8(truncatingIfNeeded: Int(_soundData[values + 2]) << 1)
        _channels[c].vibratoDelay = _soundData[values + 3]
        _channels[c].primaryEffect = .vibrato
        return 0
    }

    func update_setPriority(_ c: Int, _ values: Int) -> Int {
        _channels[c].priority = _soundData[values]
        return 0
    }

    func update_setBeat(_ c: Int, _ values: Int) -> Int {
        _beatDivider = _soundData[values] >> 1
        _beatDivCnt = _beatDivider
        _callbackTimer = 0xFF
        _beatCounter = 0
        _beatWaiting = 0
        return 0
    }

    func update_waitForNextBeat(_ c: Int, _ values: Int) -> Int {
        if (_beatCounter & _soundData[values]) != 0 && _beatWaiting != 0 {
            _beatWaiting = 0
            return 0
        }

        if (_beatCounter & _soundData[values]) == 0 {
            _beatWaiting = _beatWaiting &+ 1
        }

        _channels[c].dataptr = _channels[c].dataptr! - 2
        _channels[c].duration = 1
        return 2
    }

    func update_setExtraLevel1(_ c: Int, _ values: Int) -> Int {
        _channels[c].opExtraLevel1 = _soundData[values]
        adjustVolume(c)
        return 0
    }

    func update_setupDuration(_ c: Int, _ values: Int) -> Int {
        setupDuration(_soundData[values], c)
        return _soundData[values] != 0 ? 1 : 0
    }

    func update_playNote(_ c: Int, _ values: Int) -> Int {
        setupDuration(_soundData[values], c)
        noteOn(c)
        return _soundData[values] != 0 ? 1 : 0
    }

    func update_setFractionalNoteSpacing(_ c: Int, _ values: Int) -> Int {
        _channels[c].fractionalSpacing = _soundData[values] & 7
        return 0
    }

    func update_setTempo(_ c: Int, _ values: Int) -> Int {
        _tempo = _soundData[values]
        return 0
    }

    func update_removeSecondaryEffect1(_ c: Int, _ values: Int) -> Int {
        _channels[c].secondaryEffect = .none
        return 0
    }

    func update_setChannelTempo(_ c: Int, _ values: Int) -> Int {
        _channels[c].tempo = _soundData[values]
        return 0
    }

    func update_setExtraLevel3(_ c: Int, _ values: Int) -> Int {
        _channels[c].opExtraLevel3 = _soundData[values]
        return 0
    }

    func update_setExtraLevel2(_ c: Int, _ values: Int) -> Int {
        if _soundData[values] > 9 {
            return 0
        }

        let channelBackUp = _curChannel
        _curChannel = Int(_soundData[values])
        let c2 = _curChannel
        _channels[c2].opExtraLevel2 = _soundData[values + 1]
        adjustVolume(c2)
        _curChannel = channelBackUp
        return 0
    }

    func update_changeExtraLevel2(_ c: Int, _ values: Int) -> Int {
        if _soundData[values] > 9 {
            return 0
        }

        let channelBackUp = _curChannel
        _curChannel = Int(_soundData[values])
        let c2 = _curChannel
        _channels[c2].opExtraLevel2 = _channels[c2].opExtraLevel2 &+ _soundData[values + 1]
        adjustVolume(c2)
        _curChannel = channelBackUp
        return 0
    }

    func update_setAMDepth(_ c: Int, _ values: Int) -> Int {
        if _soundData[values] & 1 != 0 {
            _vibratoAndAMDepthBits |= 0x80
        } else {
            _vibratoAndAMDepthBits &= 0x7F
        }

        writeOPL(0xBD, _vibratoAndAMDepthBits)
        return 0
    }

    func update_setVibratoDepth(_ c: Int, _ values: Int) -> Int {
        if _soundData[values] & 1 != 0 {
            _vibratoAndAMDepthBits |= 0x40
        } else {
            _vibratoAndAMDepthBits &= 0xBF
        }

        writeOPL(0xBD, _vibratoAndAMDepthBits)
        return 0
    }

    func update_changeExtraLevel1(_ c: Int, _ values: Int) -> Int {
        _channels[c].opExtraLevel1 = _channels[c].opExtraLevel1 &+ _soundData[values]
        adjustVolume(c)
        return 0
    }

    func update_clearChannel(_ c: Int, _ values: Int) -> Int {
        if _soundData[values] > 9 {
            return 0
        }

        let channelBackUp = _curChannel
        _curChannel = Int(_soundData[values])
        let dataptrBackUp = _channels[c].dataptr
        let c2 = _curChannel
        _channels[c2].duration = 0
        _channels[c2].priority = 0
        _channels[c2].dataptr = nil
        _channels[c2].opExtraLevel2 = 0

        if _curChannel != 9 {
            let regOff = AdLibDriver.regOffset[_curChannel]
            writeOPL(0xC0 + UInt8(_curChannel), 0x00)
            writeOPL(0x43 + regOff, 0x3F)
            writeOPL(0x83 + regOff, 0xFF)
            writeOPL(0xB0 + UInt8(_curChannel), 0x00)
        }

        _curChannel = channelBackUp
        _channels[c].dataptr = dataptrBackUp
        return 0
    }

    func update_changeNoteRandomly(_ c: Int, _ values: Int) -> Int {
        if _curChannel >= 9 {
            return 0
        }

        let mask = UInt16(readBE16(values))
        var note = UInt16((Int(_channels[c].regBx & 0x1F) << 8) | Int(_channels[c].regAx))
        note = note &+ (mask & getRandomNr())
        note |= (UInt16(_channels[c].regBx & 0x20) << 8)

        writeOPL(0xA0 + UInt8(_curChannel), UInt8(truncatingIfNeeded: note & 0xFF))
        writeOPL(0xB0 + UInt8(_curChannel), UInt8(truncatingIfNeeded: (note & 0xFF00) >> 8))
        return 0
    }

    func update_removePrimaryEffectVibrato(_ c: Int, _ values: Int) -> Int {
        _channels[c].primaryEffect = .none
        return 0
    }

    func update_pitchBend(_ c: Int, _ values: Int) -> Int {
        _channels[c].pitchBend = Int8(bitPattern: _soundData[values])
        setupNote(_channels[c].rawNote, c, true)
        return 0
    }

    func update_resetToGlobalTempo(_ c: Int, _ values: Int) -> Int {
        _channels[c].tempo = _tempo
        return 0
    }

    func update_nop(_ c: Int, _ values: Int) -> Int {
        return 0
    }

    func update_setDurationRandomness(_ c: Int, _ values: Int) -> Int {
        _channels[c].durationRandomness = _soundData[values]
        return 0
    }

    func update_changeChannelTempo(_ c: Int, _ values: Int) -> Int {
        let delta = Int(Int8(bitPattern: _soundData[values]))
        _channels[c].tempo = UInt8(clip(Int(_channels[c].tempo) + delta, 1, 255))
        return 0
    }

    func updateCallback46(_ c: Int, _ values: Int) -> Int {
        let entry = Int(_soundData[values + 1])
        if entry + 2 > AdLibDriver.unkTable2.count {
            return 0
        }

        _tablePtr1 = AdLibDriver.unkTable2[entry]
        _tablePtr2 = AdLibDriver.unkTable2[entry + 1]
        if _soundData[values] == 2 {
            writeOPL(0xA0, _tablePtr2[0])
        }
        return 0
    }

    func update_setupRhythmSection(_ c: Int, _ values: Int) -> Int {
        let channelBackUp = _curChannel
        let regOffsetBackUp = _curRegOffset

        _curChannel = 6
        _curRegOffset = AdLibDriver.regOffset[6]
        if let instrument = getInstrument(Int(_soundData[values])) {
            setupInstrument(_curRegOffset, instrument, c)
        }
        _opLevelBD = _channels[c].opLevel2

        _curChannel = 7
        _curRegOffset = AdLibDriver.regOffset[7]
        if let instrument = getInstrument(Int(_soundData[values + 1])) {
            setupInstrument(_curRegOffset, instrument, c)
        }
        _opLevelHH = _channels[c].opLevel1
        _opLevelSD = _channels[c].opLevel2

        _curChannel = 8
        _curRegOffset = AdLibDriver.regOffset[8]
        if let instrument = getInstrument(Int(_soundData[values + 2])) {
            setupInstrument(_curRegOffset, instrument, c)
        }
        _opLevelTT = _channels[c].opLevel1
        _opLevelCY = _channels[c].opLevel2

        _channels[6].regBx = _soundData[values + 3] & 0x2F
        writeOPL(0xB6, _channels[6].regBx)
        writeOPL(0xA6, _soundData[values + 4])

        _channels[7].regBx = _soundData[values + 5] & 0x2F
        writeOPL(0xB7, _channels[7].regBx)
        writeOPL(0xA7, _soundData[values + 6])

        _channels[8].regBx = _soundData[values + 7] & 0x2F
        writeOPL(0xB8, _channels[8].regBx)
        writeOPL(0xA8, _soundData[values + 8])

        _rhythmSectionBits = 0x20

        _curRegOffset = regOffsetBackUp
        _curChannel = channelBackUp
        return 0
    }

    func update_playRhythmSection(_ c: Int, _ values: Int) -> Int {
        writeOPL(0xBD, (_rhythmSectionBits & ~(_soundData[values] & 0x1F)) | 0x20)
        _rhythmSectionBits |= _soundData[values]
        writeOPL(0xBD, _vibratoAndAMDepthBits | 0x20 | _rhythmSectionBits)
        return 0
    }

    func update_removeRhythmSection(_ c: Int, _ values: Int) -> Int {
        _rhythmSectionBits = 0
        writeOPL(0xBD, _vibratoAndAMDepthBits)
        return 0
    }

    func update_setRhythmLevel2(_ c: Int, _ values: Int) -> Int {
        let ops = _soundData[values]
        let v = _soundData[values + 1]

        if ops & 1 != 0 {
            _opExtraLevel2HH = v
            writeOPL(0x51, checkValue(Int(v) + Int(_opLevelHH) + Int(_opExtraLevel1HH) + Int(_opExtraLevel2HH)))
        }
        if ops & 2 != 0 {
            _opExtraLevel2CY = v
            writeOPL(0x55, checkValue(Int(v) + Int(_opLevelCY) + Int(_opExtraLevel1CY) + Int(_opExtraLevel2CY)))
        }
        if ops & 4 != 0 {
            _opExtraLevel2TT = v
            writeOPL(0x52, checkValue(Int(v) + Int(_opLevelTT) + Int(_opExtraLevel1TT) + Int(_opExtraLevel2TT)))
        }
        if ops & 8 != 0 {
            _opExtraLevel2SD = v
            writeOPL(0x54, checkValue(Int(v) + Int(_opLevelSD) + Int(_opExtraLevel1SD) + Int(_opExtraLevel2SD)))
        }
        if ops & 16 != 0 {
            _opExtraLevel2BD = v
            writeOPL(0x53, checkValue(Int(v) + Int(_opLevelBD) + Int(_opExtraLevel1BD) + Int(_opExtraLevel2BD)))
        }
        return 0
    }

    func update_changeRhythmLevel1(_ c: Int, _ values: Int) -> Int {
        let ops = _soundData[values]
        let v = _soundData[values + 1]

        if ops & 1 != 0 {
            _opExtraLevel1HH = checkValue(Int(v) + Int(_opLevelHH) + Int(_opExtraLevel1HH) + Int(_opExtraLevel2HH))
            writeOPL(0x51, _opExtraLevel1HH)
        }
        if ops & 2 != 0 {
            _opExtraLevel1CY = checkValue(Int(v) + Int(_opLevelCY) + Int(_opExtraLevel1CY) + Int(_opExtraLevel2CY))
            writeOPL(0x55, _opExtraLevel1CY)
        }
        if ops & 4 != 0 {
            _opExtraLevel1TT = checkValue(Int(v) + Int(_opLevelTT) + Int(_opExtraLevel1TT) + Int(_opExtraLevel2TT))
            writeOPL(0x52, _opExtraLevel1TT)
        }
        if ops & 8 != 0 {
            _opExtraLevel1SD = checkValue(Int(v) + Int(_opLevelSD) + Int(_opExtraLevel1SD) + Int(_opExtraLevel2SD))
            writeOPL(0x54, _opExtraLevel1SD)
        }
        if ops & 16 != 0 {
            _opExtraLevel1BD = checkValue(Int(v) + Int(_opLevelBD) + Int(_opExtraLevel1BD) + Int(_opExtraLevel2BD))
            writeOPL(0x53, _opExtraLevel1BD)
        }
        return 0
    }

    func update_setRhythmLevel1(_ c: Int, _ values: Int) -> Int {
        let ops = _soundData[values]
        let v = _soundData[values + 1]

        if ops & 1 != 0 {
            _opExtraLevel1HH = v
            writeOPL(0x51, checkValue(Int(v) + Int(_opLevelHH) + Int(_opExtraLevel2HH)))
        }
        if ops & 2 != 0 {
            _opExtraLevel1CY = v
            writeOPL(0x55, checkValue(Int(v) + Int(_opLevelCY) + Int(_opExtraLevel2CY)))
        }
        if ops & 4 != 0 {
            _opExtraLevel1TT = v
            writeOPL(0x52, checkValue(Int(v) + Int(_opLevelTT) + Int(_opExtraLevel2TT)))
        }
        if ops & 8 != 0 {
            _opExtraLevel1SD = v
            writeOPL(0x54, checkValue(Int(v) + Int(_opLevelSD) + Int(_opExtraLevel2SD)))
        }
        if ops & 16 != 0 {
            _opExtraLevel1BD = v
            writeOPL(0x53, checkValue(Int(v) + Int(_opLevelBD) + Int(_opExtraLevel2BD)))
        }
        return 0
    }

    func update_setSoundTrigger(_ c: Int, _ values: Int) -> Int {
        _soundTrigger = _soundData[values]
        return 0
    }

    func update_setTempoReset(_ c: Int, _ values: Int) -> Int {
        _channels[c].tempoReset = _soundData[values]
        return 0
    }

    func updateCallback56(_ c: Int, _ values: Int) -> Int {
        _channels[c].unk39 = _soundData[values]
        _channels[c].unk40 = _soundData[values + 1]
        return 0
    }
}

// MARK: - Static tables (adl.cpp:2226..2511)

extension AdLibDriver {
    // _parserOpcodeTable value-counts, index = opcode (adl.cpp:2226).
    static let parserOpcodeValues: [Int] = [
        1, 2, 1, 1, 2, 2, 0, 1, 0, 1, 2, 2, 1, 5, 1, 1,
        1, 3, 0, 1, 0, 4, 0, 0, 0, 0, 1, 0, 1, 1, 1, 0,
        1, 1, 0, 0, 1, 0, 1, 0, 0, 1, 0, 1, 2, 2, 1, 1,
        1, 0, 0, 1, 0, 2, 0, 0, 0, 1, 0, 0, 1, 1, 0, 2,
        0, 9, 1, 0, 2, 2, 2, 1, 1, 2, 0,
    ]

    // _regOffset (adl.cpp:2348).
    static let regOffset: [UInt8] = [
        0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12,
    ]

    // _freqTable (adl.cpp:2356).
    static let freqTable: [UInt16] = [
        0x0134, 0x0147, 0x015A, 0x016F, 0x0184, 0x019C, 0x01B4, 0x01CE, 0x01E9,
        0x0207, 0x0225, 0x0246,
    ]

    // _unkTable2_1 (adl.cpp:2375).
    static let unkTable2_1: [UInt8] = [
        0x50, 0x50, 0x4F, 0x4F, 0x4E, 0x4E, 0x4D, 0x4D,
        0x4C, 0x4C, 0x4B, 0x4B, 0x4A, 0x4A, 0x49, 0x49,
        0x48, 0x48, 0x47, 0x47, 0x46, 0x46, 0x45, 0x45,
        0x44, 0x44, 0x43, 0x43, 0x42, 0x42, 0x41, 0x41,
        0x40, 0x40, 0x3F, 0x3F, 0x3E, 0x3E, 0x3D, 0x3D,
        0x3C, 0x3C, 0x3B, 0x3B, 0x3A, 0x3A, 0x39, 0x39,
        0x38, 0x38, 0x37, 0x37, 0x36, 0x36, 0x35, 0x35,
        0x34, 0x34, 0x33, 0x33, 0x32, 0x32, 0x31, 0x31,
        0x30, 0x30, 0x2F, 0x2F, 0x2E, 0x2E, 0x2D, 0x2D,
        0x2C, 0x2C, 0x2B, 0x2B, 0x2A, 0x2A, 0x29, 0x29,
        0x28, 0x28, 0x27, 0x27, 0x26, 0x26, 0x25, 0x25,
        0x24, 0x24, 0x23, 0x23, 0x22, 0x22, 0x21, 0x21,
        0x20, 0x20, 0x1F, 0x1F, 0x1E, 0x1E, 0x1D, 0x1D,
        0x1C, 0x1C, 0x1B, 0x1B, 0x1A, 0x1A, 0x19, 0x19,
        0x18, 0x18, 0x17, 0x17, 0x16, 0x16, 0x15, 0x15,
        0x14, 0x14, 0x13, 0x13, 0x12, 0x12, 0x11, 0x11,
        0x10, 0x10,
    ]

    // _unkTable2_2 (adl.cpp:2396) — note the verbatim 0x6F quirk at index 95.
    static let unkTable2_2: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F,
        0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
        0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F,
        0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
        0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F,
        0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47,
        0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
        0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57,
        0x58, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x6F,
        0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67,
        0x68, 0x69, 0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F,
        0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77,
        0x78, 0x79, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F,
    ]

    // _unkTable2_3 (adl.cpp:2415).
    static let unkTable2_3: [UInt8] = [
        0x40, 0x40, 0x40, 0x3F, 0x3F, 0x3F, 0x3E, 0x3E,
        0x3E, 0x3D, 0x3D, 0x3D, 0x3C, 0x3C, 0x3C, 0x3B,
        0x3B, 0x3B, 0x3A, 0x3A, 0x3A, 0x39, 0x39, 0x39,
        0x38, 0x38, 0x38, 0x37, 0x37, 0x37, 0x36, 0x36,
        0x36, 0x35, 0x35, 0x35, 0x34, 0x34, 0x34, 0x33,
        0x33, 0x33, 0x32, 0x32, 0x32, 0x31, 0x31, 0x31,
        0x30, 0x30, 0x30, 0x2F, 0x2F, 0x2F, 0x2E, 0x2E,
        0x2E, 0x2D, 0x2D, 0x2D, 0x2C, 0x2C, 0x2C, 0x2B,
        0x2B, 0x2B, 0x2A, 0x2A, 0x2A, 0x29, 0x29, 0x29,
        0x28, 0x28, 0x28, 0x27, 0x27, 0x27, 0x26, 0x26,
        0x26, 0x25, 0x25, 0x25, 0x24, 0x24, 0x24, 0x23,
        0x23, 0x23, 0x22, 0x22, 0x22, 0x21, 0x21, 0x21,
        0x20, 0x20, 0x20, 0x1F, 0x1F, 0x1F, 0x1E, 0x1E,
        0x1E, 0x1D, 0x1D, 0x1D, 0x1C, 0x1C, 0x1C, 0x1B,
        0x1B, 0x1B, 0x1A, 0x1A, 0x1A, 0x19, 0x19, 0x19,
        0x18, 0x18, 0x18, 0x17, 0x17, 0x17, 0x16, 0x16,
        0x16, 0x15,
    ]

    // _unkTable2 (adl.cpp:2364) — 1,2,1,2,3,2.
    static let unkTable2: [[UInt8]] = [
        unkTable2_1, unkTable2_2, unkTable2_1, unkTable2_2, unkTable2_3, unkTable2_2,
    ]

    // _pitchBendTables (adl.cpp:2440).
    static let pitchBendTables: [[UInt8]] = [
        [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
            0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21,
        ],
        [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x07, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11,
            0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x22, 0x24,
        ],
        [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x12, 0x13,
            0x14, 0x15, 0x16, 0x17, 0x19, 0x1A, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x24, 0x25, 0x26,
        ],
        [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x12, 0x13,
            0x14, 0x15, 0x16, 0x17, 0x18, 0x1A, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x23, 0x25, 0x27, 0x28,
        ],
        [
            0x00, 0x01, 0x02, 0x03, 0x04, 0x06, 0x08, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x13, 0x15,
            0x16, 0x17, 0x18, 0x19, 0x1B, 0x1D, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x28, 0x2A,
        ],
        [
            0x00, 0x01, 0x02, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15,
            0x16, 0x17, 0x18, 0x19, 0x1B, 0x1D, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x25, 0x27, 0x29, 0x2B, 0x2D,
        ],
        [
            0x00, 0x01, 0x02, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15,
            0x16, 0x17, 0x18, 0x1A, 0x1C, 0x1E, 0x21, 0x24, 0x25, 0x26, 0x27, 0x29, 0x2B, 0x2D, 0x2F, 0x30,
        ],
        [
            0x00, 0x01, 0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x18,
            0x19, 0x1A, 0x1C, 0x1D, 0x1F, 0x21, 0x23, 0x25, 0x26, 0x27, 0x29, 0x2B, 0x2D, 0x2F, 0x30, 0x32,
        ],
        [
            0x00, 0x01, 0x02, 0x04, 0x06, 0x08, 0x0A, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x14, 0x17, 0x1A,
            0x19, 0x1A, 0x1C, 0x1E, 0x20, 0x22, 0x25, 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2F, 0x31, 0x33, 0x35,
        ],
        [
            0x00, 0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0E, 0x0F, 0x10, 0x12, 0x14, 0x16, 0x18, 0x1A, 0x1B,
            0x1C, 0x1D, 0x1E, 0x20, 0x22, 0x24, 0x26, 0x29, 0x2A, 0x2C, 0x2E, 0x30, 0x32, 0x34, 0x36, 0x39,
        ],
        [
            0x00, 0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0E, 0x0F, 0x10, 0x12, 0x14, 0x16, 0x19, 0x1B, 0x1E,
            0x1F, 0x21, 0x23, 0x25, 0x27, 0x29, 0x2B, 0x2D, 0x2E, 0x2F, 0x31, 0x32, 0x34, 0x36, 0x39, 0x3C,
        ],
        [
            0x00, 0x01, 0x03, 0x05, 0x07, 0x0A, 0x0C, 0x0F, 0x10, 0x11, 0x13, 0x15, 0x17, 0x19, 0x1B, 0x1E,
            0x1F, 0x20, 0x22, 0x24, 0x26, 0x28, 0x2B, 0x2E, 0x2F, 0x30, 0x32, 0x34, 0x36, 0x39, 0x3C, 0x3F,
        ],
        [
            0x00, 0x02, 0x04, 0x06, 0x08, 0x0B, 0x0D, 0x10, 0x11, 0x12, 0x14, 0x16, 0x18, 0x1B, 0x1E, 0x21,
            0x22, 0x23, 0x25, 0x27, 0x29, 0x2C, 0x2F, 0x32, 0x33, 0x34, 0x36, 0x38, 0x3B, 0x34, 0x41, 0x44,
        ],
        [
            0x00, 0x02, 0x04, 0x06, 0x08, 0x0B, 0x0D, 0x11, 0x12, 0x13, 0x15, 0x17, 0x1A, 0x1D, 0x20, 0x23,
            0x24, 0x25, 0x27, 0x29, 0x2C, 0x2F, 0x32, 0x35, 0x36, 0x37, 0x39, 0x3B, 0x3E, 0x41, 0x44, 0x47,
        ],
    ]
}
