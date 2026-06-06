//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import SwiftOPL3
import Testing

@testable import WestwoodADL

// Skeleton smoke test — replaced/extended in Phase 3–4 by the ADL parse tests
// and the register-write trace-equivalence goldens vs AdPlug. See
// Documentation/Architecture/Testing.md §Driver.

@Suite("Westwood ADL — skeleton")
struct ADLPlayerSmokeTests {
    @Test("player constructs over a chip")
    func construction() {
        let player = ADLPlayer(chip: OPL3Chip())
        #expect(player.subsongCount == 0)  // stub; Phase 3 wires load()
        #expect(player.update() == false)  // stub; Phase 4 transcribes update()
    }
}
