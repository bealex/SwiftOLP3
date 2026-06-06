//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Foundation
import Testing

@testable import WestwoodADL

// ADL parser parity — exercises ADLData.load (≈ CadlPlayer::load, adl.cpp:2767)
// and the program/instrument offset lookups with a synthetic v2/v3 file we
// control. A real DUNE*.ADL golden (dumped from the instrumented AdPlug harness)
// is added under Phase 4/5; this locks the version detection + offset arithmetic.

@Suite("ADL parser — AdPlug load() parity")
struct ADLDataTests {
    private static func setLE16(_ a: inout [UInt8], _ i: Int, _ v: Int) {
        a[i] = UInt8(v & 0xFF)
        a[i + 1] = UInt8((v >> 8) & 0xFF)
    }

    /// A minimal but valid v2/v3 file: 2 subsongs (program ids 5 and 8), with
    /// program + instrument offset tables. soundData index = fileOffset - 120.
    private static func makeV3File() -> Data {
        var f = [UInt8](repeating: 0, count: 1200)
        // Track table: subsong 0 → program 5, subsong 1 → program 8, rest unused.
        f[0] = 5
        f[1] = 8
        for i in 2 ..< 120 { f[i] = 0xFF }
        // Program offset table lives at soundData[0..500] == file[120..620].
        Self.setLE16(&f, 120 + 2 * 5, 1000)  // program 5 → soundData offset 1000
        Self.setLE16(&f, 120 + 2 * 8, 1010)  // program 8 → soundData offset 1010
        // Instrument offset table at soundData[500..1000]; instrument 0 = program 250.
        Self.setLE16(&f, 120 + 500 + 2 * 0, 1020)
        return Data(f)
    }

    @Test("v3 detection, subsong count, and offsets")
    func parseV3() throws {
        let adl = try #require(ADLData.load(Self.makeV3File()))
        #expect(adl.version == 3)  // AdPlug reports v2 (Dune II) as v3
        #expect(adl.numPrograms == 250)
        #expect(adl.numsubsongs == 2)
        #expect(adl.soundData.count == 1200 - 120)

        #expect(adl.soundId(subsong: 0) == 5)
        #expect(adl.soundId(subsong: 1) == 8)
        #expect(adl.soundId(subsong: 2) == nil)  // out of range

        #expect(adl.programOffset(5) == 1000)
        #expect(adl.programOffset(8) == 1010)
        #expect(adl.programOffset(6) == nil)  // offset 0 → invalid
        #expect(adl.instrumentOffset(0) == 1020)
    }

    @Test("trackEntries tail is cleared to 0xFF past the 120-byte table")
    func trackEntryTail() throws {
        let adl = try #require(ADLData.load(Self.makeV3File()))
        #expect(adl.trackEntries.count == 500)
        #expect(adl.trackEntries[120] == 0xFF)
        #expect(adl.trackEntries[499] == 0xFF)
        #expect(adl.trackEntries[0] == 5)
    }

    @Test("files below the v1 minimum are rejected")
    func tooSmall() {
        #expect(ADLData.load(Data([UInt8](repeating: 0, count: 700))) == nil)
    }

    @Test("bad program offset (0 < w < 600) is rejected as corrupt")
    func badData() {
        var f = [UInt8](repeating: 0, count: 1200)
        f[0] = 5
        for i in 1 ..< 120 { f[i] = 0xFF }
        // Force a version-3 detection via a high word in the track region,
        // then place an illegal program offset (500, which is in (0,600)).
        Self.setLE16(&f, 120 + 2 * 5, 500)
        #expect(ADLData.load(Data(f)) == nil)
    }
}
