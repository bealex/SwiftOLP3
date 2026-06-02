//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing
@testable import SwiftOPL3

// Table parity unit tests — assert each ported table's length and several spot
// values against the `opl3.c` literals (Nuked-OPL3 v1.8, commit cfedb09e). A
// transcription typo surfaces here before it poisons every render.
// See Documentation/Architecture/Testing.md §table unit tests.

@Suite("OPL3 tables — Nuked-OPL3 parity")
struct OPL3TablesTests {

    @Test("logsinrom: 256 entries, endpoints and interior spot values")
    func logsinrom() {
        let table = OPL3Tables.logsinrom
        #expect(table.count == 256)
        #expect(table[0] == 0x859)            // opl3.c:76
        #expect(table[7] == 0x471)            // opl3.c:76 (end of first row)
        #expect(table[128] == 0x07f)          // opl3.c:92 (start of row 17)
        #expect(table[255] == 0x000)          // opl3.c:107 (last entry)
    }

    @Test("exprom: 256 entries, endpoints and interior spot values")
    func exprom() {
        let table = OPL3Tables.exprom
        #expect(table.count == 256)
        #expect(table[0] == 0x7fa)            // opl3.c:115
        #expect(table[8] == 0x7cf)            // opl3.c:116 (start of row 2)
        #expect(table[128] == 0x5a4)          // opl3.c:131 (start of row 17)
        #expect(table[255] == 0x400)          // opl3.c:146 (last entry)
    }

    @Test("mt: 16 entries, ×2 frequency multipliers")
    func mt() {
        let table = OPL3Tables.mt
        #expect(table.count == 16)
        #expect(table[0] == 1)                // 1/2 stored ×2
        #expect(table[1] == 2)                // 1
        #expect(table[10] == 20)              // 10
        #expect(table[11] == 20)              // 10 (repeat, not 22)
        #expect(table[14] == 30)              // 15
        #expect(table[15] == 30)
    }

    @Test("kslrom + kslshift")
    func ksl() {
        #expect(OPL3Tables.kslrom.count == 16)
        #expect(OPL3Tables.kslrom[0] == 0)
        #expect(OPL3Tables.kslrom[1] == 32)
        #expect(OPL3Tables.kslrom[15] == 64)
        #expect(OPL3Tables.kslshift == [ 8, 1, 2, 0 ])
    }

    @Test("egIncstep: 4×4 envelope generator constants")
    func egIncstep() {
        let table = OPL3Tables.egIncstep
        #expect(table.count == 4)
        #expect(table.allSatisfy { $0.count == 4 })
        #expect(table[0] == [ 0, 0, 0, 0 ])
        #expect(table[1] == [ 1, 0, 0, 0 ])
        #expect(table[2] == [ 1, 0, 1, 0 ])
        #expect(table[3] == [ 1, 1, 1, 0 ])
    }

    @Test("adSlot: 0x20 entries, signed, -1 sentinels")
    func adSlot() {
        let table = OPL3Tables.adSlot
        #expect(table.count == 0x20)
        #expect(table[0] == 0)
        #expect(table[5] == 5)
        #expect(table[6] == -1)               // gap
        #expect(table[8] == 6)
        #expect(table[21] == 17)
        #expect(table[22] == -1)
        #expect(table[31] == -1)
    }

    @Test("chSlot: 18 entries, channel → base slot")
    func chSlot() {
        let table = OPL3Tables.chSlot
        #expect(table.count == 18)
        #expect(table[0] == 0)
        #expect(table[3] == 6)
        #expect(table[9] == 18)
        #expect(table[17] == 32)
    }
}
