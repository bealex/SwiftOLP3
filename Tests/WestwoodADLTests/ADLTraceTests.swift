//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

import Foundation
import Testing
@testable import WestwoodADL

// Driver golden — register-write trace equivalence vs AdPlug. The instrumented
// AdPlug AdLibDriver (Scripts/gen-adl-traces.sh) drives a synthetic .ADL sound
// block and dumps every writeOPL as "RR VV" hex to Fixtures/synth_track.trace,
// alongside the soundData (synth_track.bin). This test drives the *ported*
// AdLibDriver with the identical call sequence over the same bytes and asserts
// the (reg, val) stream matches index-for-index — the primary driver parity bar.
// See Documentation/Architecture/Testing.md §Driver. Skips if the fixture is absent.

private final class RecordingSink: OPLRegisterSink {
    var writes: [(UInt8, UInt8)] = []
    func writeRegister(_ reg: UInt8, _ value: UInt8) {
        writes.append((reg, value))
    }
}

@Suite("AdLib driver golden — trace equivalence vs AdPlug")
struct ADLTraceTests {

    private func fixture(_ name: String, _ ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: ext)
    }

    @Test("synth_track: ported AdLibDriver emits AdPlug's exact writeOPL stream")
    func synthTrackTrace() throws {
        guard
            let binURL = fixture("synth_track", "bin"),
            let traceURL = fixture("synth_track", "trace"),
            let binData = try? Data(contentsOf: binURL),
            let traceText = try? String(contentsOf: traceURL, encoding: .utf8)
        else {
            return  // fixtures not generated on this checkout — skip
        }

        // Parse the golden "RR VV" hex lines.
        var golden: [(UInt8, UInt8)] = []
        for line in traceText.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2,
                  let reg = UInt8(parts[0], radix: 16),
                  let val = UInt8(parts[1], radix: 16)
            else { continue }
            golden.append((reg, val))
        }
        #expect(golden.count > 0)

        // Drive the ported driver with the identical sequence as the C harness.
        let sink = RecordingSink()
        let driver = AdLibDriver()
        driver.sink = sink
        driver.setVersion(3)
        driver.setSoundData([UInt8](binData))
        driver.initDriver()
        driver.stopAllChannels()
        driver.startSound(2, 0xFF)
        for _ in 0 ..< 40 {
            driver.callback()
        }

        #expect(sink.writes.count == golden.count, "write count \(sink.writes.count) != golden \(golden.count)")

        var firstDivergence = -1
        for i in 0 ..< min(sink.writes.count, golden.count)
        where sink.writes[i].0 != golden[i].0 || sink.writes[i].1 != golden[i].1 {
            firstDivergence = i
            break
        }
        if firstDivergence >= 0 {
            let s = sink.writes[firstDivergence]
            let g = golden[firstDivergence]
            let ours = "(\(String(s.0, radix: 16)),\(String(s.1, radix: 16)))"
            let want = "(\(String(g.0, radix: 16)),\(String(g.1, radix: 16)))"
            Issue.record("first divergence at index \(firstDivergence): ours=\(ours) golden=\(want)")
        }
        #expect(firstDivergence == -1)
    }
}
