//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Foundation
import Testing
import SwiftOPL3
@testable import WestwoodADL

// Real-track driver golden — trace equivalence vs AdPlug on an actual (audible)
// Dune II .ADL through the full public path. The oracle (Scripts/gen-adl-traces.sh,
// song harness) runs AdPlug's real CadlPlayer (load → rewind → update) over
// Resources/Music/DUNE8.ADL subsong 2 and dumps every writeOPL to
// Fixtures/DUNE8.2.trace. This test loads the same file through ADLPlayer with a
// recording sink and asserts the (reg, val) stream matches index-for-index — over
// 1000+ writes of a real melody (key-ons, instrument loads, volume envelopes).
//
// Skips when the .ADL asset (game data, not committed) or the trace is absent.

private final class Recorder: OPLRegisterSink {
    var writes: [(UInt8, UInt8)] = []
    func writeRegister(_ reg: UInt8, _ value: UInt8) { writes.append((reg, value)) }
}

@Suite("ADL song golden — trace equivalence vs AdPlug (real DUNE8.ADL)")
struct ADLSongTraceTests {

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/WestwoodADLTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    @Test("DUNE8.ADL subsong 2: ADLPlayer matches AdPlug's writeOPL stream over 600 ticks")
    func dune8Subsong2() throws {
        let subsong = 2
        let ticks = 600

        let adlURL = packageRoot().appendingPathComponent("Resources/Music/DUNE8.ADL")
        let traceURL = Bundle.module.url(forResource: "DUNE8.2", withExtension: "trace", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "DUNE8.2", withExtension: "trace")

        guard
            let traceURL,
            let songData = try? Data(contentsOf: adlURL),
            let traceText = try? String(contentsOf: traceURL, encoding: .utf8)
        else {
            return  // asset or fixture absent — skip
        }

        var golden: [(UInt8, UInt8)] = []
        for line in traceText.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2,
                  let reg = UInt8(parts[0], radix: 16),
                  let val = UInt8(parts[1], radix: 16)
            else { continue }
            golden.append((reg, val))
        }
        #expect(golden.count > 30)

        let recorder = Recorder()
        let chip = OPL3Chip()
        let player = ADLPlayer(chip: chip, sink: recorder)
        #expect(player.load(songData))         // internal rewind(2)
        recorder.writes.removeAll()            // capture from the explicit rewind onward
        player.rewind(subsong: subsong)
        for _ in 0 ..< ticks {
            _ = player.update()
        }

        #expect(recorder.writes.count == golden.count,
                "write count \(recorder.writes.count) != golden \(golden.count)")

        var firstDivergence = -1
        for i in 0 ..< min(recorder.writes.count, golden.count)
        where recorder.writes[i].0 != golden[i].0 || recorder.writes[i].1 != golden[i].1 {
            firstDivergence = i
            break
        }
        if firstDivergence >= 0 {
            let s = recorder.writes[firstDivergence]
            let g = golden[firstDivergence]
            let ours = "(\(String(s.0, radix: 16)),\(String(s.1, radix: 16)))"
            let want = "(\(String(g.0, radix: 16)),\(String(g.1, radix: 16)))"
            Issue.record("first divergence at index \(firstDivergence): ours=\(ours) golden=\(want)")
        }
        #expect(firstDivergence == -1)
    }
}
