//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing

@testable import WestwoodADL

// AdLibDriver internals parity — the data tables and the PRNG. The full
// behavioural golden is the register-write trace-equivalence test (slice 5).

@Suite("AdLibDriver — tables + PRNG parity")
struct AdLibDriverTests {
    @Test("parser opcode value-counts table has 75 entries")
    func opcodeValues() {
        #expect(AdLibDriver.parserOpcodeValues.count == 75)
        #expect(AdLibDriver.parserOpcodeValues[0] == 1)  // setRepeat
        #expect(AdLibDriver.parserOpcodeValues[13] == 5)  // setupSecondaryEffect1
        #expect(AdLibDriver.parserOpcodeValues[65] == 9)  // setupRhythmSection
        #expect(AdLibDriver.parserOpcodeValues[74] == 0)  // stopChannel
    }

    @Test("regOffset / freqTable")
    func tables() {
        #expect(AdLibDriver.regOffset == [ 0x00, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x10, 0x11, 0x12 ])
        #expect(AdLibDriver.freqTable.count == 12)
        #expect(AdLibDriver.freqTable[0] == 0x0134)
        #expect(AdLibDriver.freqTable[11] == 0x0246)
    }

    @Test("unkTable2 structure + the verbatim 0x6F quirk")
    func unkTables() {
        #expect(AdLibDriver.unkTable2.count == 6)
        #expect(AdLibDriver.unkTable2_1.count == 130)
        #expect(AdLibDriver.unkTable2_2.count == 128)
        #expect(AdLibDriver.unkTable2_3.count == 130)
        // adl.cpp:2408 — index 95 is 0x6F, not 0x5F ("no don't ask me WHY").
        #expect(AdLibDriver.unkTable2_2[95] == 0x6F)
    }

    @Test("pitchBendTables: 14 rows of 32")
    func pitchBend() {
        #expect(AdLibDriver.pitchBendTables.count == 14)
        #expect(AdLibDriver.pitchBendTables.allSatisfy { $0.count == 32 })
        #expect(AdLibDriver.pitchBendTables[0][0] == 0x00)
        #expect(AdLibDriver.pitchBendTables[13][31] == 0x47)
    }

    @Test("getRandomNr: seeded 0x1234, deterministic LCG-style sequence")
    func randomNr() {
        let driver = AdLibDriver()
        // Hand-computed from adl.cpp:1030 with _rnd=0x1234:
        // _rnd += 0x9248 → 0xA47C; low3=4; >>3 → 0x148F; | (4<<13) → 0x948F.
        #expect(driver.getRandomNr() == 0x948F)

        // Determinism: a second fresh driver yields the identical sequence.
        let a = AdLibDriver(), b = AdLibDriver()
        for _ in 0 ..< 64 {
            #expect(a.getRandomNr() == b.getRandomNr())
        }
    }
}
