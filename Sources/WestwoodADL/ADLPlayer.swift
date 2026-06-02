//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  ADLPlayer.swift
//  WestwoodADL — public surface for the Westwood ADL music driver.
//
//  Faithful transcription of AdPlug `CadlPlayer` (adl.cpp:2544..2948). Drives an
//  `OPL3Chip` (or any `OPLRegisterSink`) by ticking the `AdLibDriver` at 72 Hz.
//  Lifecycle: `load` → `rewind(subsong:)` → repeated `update()` at `refreshRate`.
//  See Documentation/Architecture/WestwoodADL.md.

import Foundation
import SwiftOPL3

/// Forwards the driver's `writeOPL` to an `OPL3Chip` (≈ AdPlug's `Copl`).
final class ChipSink: OPLRegisterSink {
    let chip: OPL3Chip
    init(_ chip: OPL3Chip) { self.chip = chip }
    func writeRegister(_ reg: UInt8, _ value: UInt8) {
        chip.write(UInt16(reg), value)
    }
}

public final class ADLPlayer {

    private let chip: OPL3Chip
    private let sampleRate: UInt32
    private let sink: OPLRegisterSink
    private let driver = AdLibDriver()

    private var adl: ADLData?
    private var cursubsong = 0

    /// Drive the given chip directly.
    public init(chip: OPL3Chip) {
        self.chip = chip
        self.sampleRate = OPL3Chip.nativeSampleRate
        let sink = ChipSink(chip)
        self.sink = sink
        driver.sink = sink
    }

    /// Test/host seam: drive an arbitrary register sink (e.g. a recorder) and a
    /// chip used only for `rewind`'s `opl->init()`.
    init(chip: OPL3Chip, sink: OPLRegisterSink) {
        self.chip = chip
        self.sampleRate = OPL3Chip.nativeSampleRate
        self.sink = sink
        driver.sink = sink
    }

    /// ≈ `CadlPlayer::load`. Parses the `.ADL`, configures the driver, and
    /// rewinds to subsong 2 (AdPlug's default). Returns false on a bad file.
    @discardableResult
    public func load(_ data: Data) -> Bool {
        guard let parsed = ADLData.load(data) else {
            return false
        }

        adl = parsed
        driver.setVersion(parsed.version)
        driver.setSoundData(parsed.soundData)
        rewind(subsong: 2)
        return true
    }

    /// Number of selectable tracks. ≈ `CadlPlayer::getsubsongs()`.
    public var subsongCount: Int { adl?.numsubsongs ?? 0 }

    /// The currently selected subsong.
    public var subsong: Int { cursubsong }

    /// ≈ `CadlPlayer::rewind`.
    public func rewind(subsong: Int) {
        driver.initDriver()
        driver.stopAllChannels()
        chip.reset(sampleRate: sampleRate)
        sink.writeRegister(1, 32)

        var subsong = subsong
        if subsong >= (adl?.numsubsongs ?? 0) {
            subsong = 0
        }
        if subsong >= 0 {
            cursubsong = subsong
        }

        playSoundEffect(UInt16(truncatingIfNeeded: cursubsong), 0xFF)
    }

    /// One driver tick. ≈ `CadlPlayer::update()`. Returns false at end of track.
    @discardableResult
    public func update() -> Bool {
        driver.callback()
        for i in 0 ..< 10 where driver.isChannelPlaying(i) && !driver.isChannelRepeating(i) {
            return true
        }
        return false
    }

    /// Hz at which the host must call `update()`. ≈ `CadlPlayer::getrefresh()`.
    public var refreshRate: Double { 72.0 }

    /// The most recent `update_setSoundTrigger` value. ≈ `getSoundTrigger`.
    public var soundTrigger: Int { driver.soundTrigger }

    // adl.cpp:2664 CadlPlayer::play
    private func play(_ track: UInt16, _ volume: UInt8) {
        guard let adl, Int(track) < adl.numsubsongs else {
            return
        }

        let soundId: Int
        if adl.version == 4 {
            soundId = Int(adl.trackEntries[Int(track) << 1]) | (Int(adl.trackEntries[(Int(track) << 1) + 1]) << 8)
        } else {
            soundId = Int(adl.trackEntries[Int(track)])
        }

        if (soundId == 0xFFFF && adl.version == 4) || (soundId == 0xFF && adl.version < 4) {
            return
        }

        driver.startSound(soundId, Int(volume))
    }

    private func playSoundEffect(_ track: UInt16, _ volume: UInt8) {
        play(track, volume)
    }
}
