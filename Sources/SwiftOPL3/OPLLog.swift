//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPLLog.swift
//  SwiftOPL3 — debug-only structured tracing seam.
//
//  All logging in SwiftOPL3 / WestwoodADL funnels through this one type.
//  Every body is gated on `OPL_TRACE`; with the flag unset (the default and
//  release), the methods are empty `@inline(__always)` no-ops — the optimiser
//  deletes the calls and the `@autoclosure` trace strings are never evaluated,
//  so Memoirs is never invoked and there is zero release cost.
//
//  See Documentation/Architecture/Logging.md. The Memoirs API lives only inside
//  the `#if OPL_TRACE` `emit(...)` helper below — change it in exactly one place.

#if OPL_TRACE
    import Memoirs
#endif

/// Compile-time-gated trace seam. Logging is observation only: it must never
/// change behaviour, branch the simulation, or have side effects in its
/// `@autoclosure` arguments. A faithful transcription produces identical output
/// with `OPL_TRACE` on or off.
public enum OPLLog {
    /// Every OPL register write — the driver↔chip seam and the parity stream the
    /// `WestwoodADLTests` trace goldens align against.
    @inline(__always)
    public static func reg(_ port: UInt16, _ value: UInt8) {
        #if OPL_TRACE
            emit("reg", "port=\(hex(port)) val=\(hex(value))")
        #endif
    }

    /// Every driver opcode dispatch — for localizing a trace divergence to a `update_*`.
    @inline(__always)
    public static func op(_ channel: Int, _ opcode: UInt8, _ name: @autoclosure () -> String) {
        #if OPL_TRACE
            emit("op", "ch=\(channel) op=\(hex(opcode)) \(name())")
        #endif
    }

    /// Ad-hoc tracing while debugging.
    @inline(__always)
    public static func trace(_ tracer: StaticString, _ message: @autoclosure () -> String) {
        #if OPL_TRACE
            emit("\(tracer)", message())
        #endif
    }
}

#if OPL_TRACE
    extension OPLLog {
        // Configured once; immutable ⇒ Sendable-safe under strict concurrency
        // (no global mutable state, per the project's concurrency rules).
        //
        // TODO(setup): confirm the Memoirs constructor + log signature against the
        // resolved Memoirs version and pick the desired Output.
        private static let memoir = TracedMemoir(object: "OPL", memoir: PrintMemoir())

        static func emit(_ tracer: String, _ message: String) {
            // TODO(setup): match the real Memoirs logging call.
            memoir.debug("\(message)", tracers: [ .label(tracer) ])
        }

        static func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
    }
#endif
