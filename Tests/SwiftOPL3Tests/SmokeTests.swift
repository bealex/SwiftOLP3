//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Testing

@testable import SwiftOPL3

// Smoke test — basic construction + the OPLLog.reg tap. Deep coverage lives in
// the table / waveform / reset / register / envelope / phase / generate suites
// and the bit-exact golden. See Documentation/Architecture/Testing.md.

@Suite("OPL3 chip — smoke")
struct OPL3ChipSmokeTests {
    @Test("chip constructs and an un-keyed write leaves the chip idle (silent)")
    func construction() {
        #expect(OPL3Chip.nativeSampleRate == 49_716)
        let chip = OPL3Chip()
        chip.write(0x20, 0x01)  // exercises the OPLLog.reg tap; no key-on
        let (l, r) = chip.generate()
        // No note is keyed, so the chip is genuinely silent (not a stub).
        #expect(l == 0 && r == 0)
    }
}
