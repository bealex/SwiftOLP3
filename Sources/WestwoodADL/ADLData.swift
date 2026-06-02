//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  ADLData.swift
//  WestwoodADL — the .ADL file parser.
//
//  Faithful transcription of AdPlug `CadlPlayer::load` (adl.cpp:2767), the
//  version detection, and the driver's `getProgram`/`getInstrument` offset
//  lookups (adl.cpp:286/308). AdPlug commit 16442997.
//
//  Layout (v<4): the file's first 120 bytes are the subsong→program-id track
//  table; everything from offset 120 on is `soundData` — a program-offset table
//  (250 LE words), an instrument-offset table (250 LE words), then the bytecode
//  + instrument operator bytes. AdPlug cannot distinguish v2 (EOB2) from v3
//  (Kyra1/Dune II) and reports v3 for both; `numPrograms` is 250 either way.
//  See Documentation/Formats/ADL.md.

import Foundation

/// A parsed .ADL file. Holds the raw `soundData` resident (as AdPlug does) and
/// hands the driver byte-offsets into it.
struct ADLData {
    let version: Int
    let numsubsongs: Int
    let numPrograms: Int
    let soundData: [UInt8]
    let trackEntries: [UInt8]   // 500 bytes (tail set to 0xFF for v<4)

    @inline(__always)
    private static func readLE16(_ a: [UInt8], _ i: Int) -> Int {
        Int(a[i]) | (Int(a[i + 1]) << 8)
    }

    // adl.cpp:2767 CadlPlayer::load — version detection + soundData extraction.
    static func load(_ data: Data) -> ADLData? {
        let fileSize = data.count
        if fileSize < 720 {   // minimum file size of v1
            return nil
        }

        let bytes = [UInt8](data)
        var trackEntries = Array(bytes[0 ..< 500])

        // detect format version v4 vs v1/2/3
        var ofs = 500
        var version = 4
        for i in stride(from: 0, to: 500, by: 2) {
            let w = readLE16(trackEntries, i)
            if w >= 500 && w < 0xFFFF {
                version = 3   // actually 1, 2, or 3
                ofs = 120
                break
            }
        }

        let soundData = Array(bytes[ofs ..< fileSize])   // soundDataSize == fileSize - ofs
        // surplus: bytes [ofs, 500) of the file are actually soundData; the
        // remainder of trackEntries is cleared to 0xFF (matches the memset).
        for i in ofs ..< 500 {
            trackEntries[i] = 0xFF
        }

        var numPrograms: Int
        if version < 4 {
            numPrograms = 150   // for v1
            for i in stride(from: 0, to: numPrograms * 2, by: 2) {
                let w = readLE16(soundData, i)
                if w > 0 && w < 600 {       // minimum program/instrument offset for v1 is 600
                    return nil               // bad_data
                }
                if w > 0 && w < 1000 {      // minimum offset for v2/v3 is 1000
                    version = 1
                }
            }

            if version > 1 {
                if fileSize < 1120 {        // minimum size of v2/v3
                    return nil
                }
                numPrograms = 250
                for i in stride(from: 150 * 2, to: numPrograms * 2, by: 2) {
                    let w = readLE16(soundData, i)
                    if w > 0 && w < 1000 {
                        return nil
                    }
                }
            }
        } else {
            if fileSize < 2500 {            // minimum file size of v4
                return nil
            }
            numPrograms = 500
            for i in stride(from: 0, to: numPrograms * 2, by: 2) {
                let w = readLE16(soundData, i)
                if w > 0 && w < 2000 {      // minimum program offset for v4 is 2000
                    return nil
                }
            }
        }

        // find last subsong
        var numsubsongs = 0
        if version == 4 {
            var i = 2 * 250
            while i > 0 {
                if readLE16(trackEntries, i - 2) < numPrograms {
                    numsubsongs = i / 2
                    break
                }
                i -= 2
            }
        } else {
            var i = 120
            while i > 0 {
                if Int(trackEntries[i - 1]) < numPrograms {
                    numsubsongs = i
                    break
                }
                i -= 1
            }
        }

        // _numPrograms per setVersion(): v1→150, v4→500, else→250.
        let driverNumPrograms = (version == 1) ? 150 : ((version == 4) ? 500 : 250)
        return ADLData(
            version: version,
            numsubsongs: numsubsongs,
            numPrograms: driverNumPrograms,
            soundData: soundData,
            trackEntries: trackEntries
        )
    }

    // adl.cpp:2664 CadlPlayer::play — subsong → program/sound id.
    func soundId(subsong track: Int) -> Int? {
        guard track >= 0 && track < numsubsongs else {
            return nil
        }

        let soundId: Int
        if version == 4 {
            soundId = Self.readLE16(trackEntries, track << 1)
        } else {
            soundId = Int(trackEntries[track])
        }

        if (soundId == 0xFFFF && version == 4) || (soundId == 0xFF && version < 4) {
            return nil
        }

        return soundId
    }

    // adl.cpp:286 AdLibDriver::getProgram — program id → byte offset into soundData.
    func programOffset(_ progId: Int) -> Int? {
        if progId < 0 || progId >= soundData.count / 2 {
            return nil
        }

        let offset = Self.readLE16(soundData, 2 * progId)
        // 0 is invalid (points inside the offset table); also reject out-of-range.
        if offset == 0 || offset >= soundData.count {
            return nil
        }

        return offset
    }

    // adl.cpp:308 AdLibDriver::getInstrument — instrument id → byte offset.
    func instrumentOffset(_ instrumentId: Int) -> Int? {
        programOffset(numPrograms + instrumentId)
    }
}
