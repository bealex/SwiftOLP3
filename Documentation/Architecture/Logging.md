# Logging — Memoirs, debug-only, zero-cost in release

The user's requirement: use **Memoirs** for logging, but **extract logging to a separate, static, debug-only function** that is **disabled in release**.

## The seam: `OPLLog`

All logging in both targets goes through one type — `OPLLog` (`Sources/SwiftOPL3/OPLLog.swift`). Nothing else imports Memoirs; nothing else calls `print`. Every body is wrapped in `#if OPL_TRACE`:

```swift
#if OPL_TRACE
import Memoirs
#endif

public enum OPLLog {
    @inline(__always)
    public static func reg(_ port: UInt16, _ value: UInt8) {
        #if OPL_TRACE
        emit("reg", "port=\(hex(port)) val=\(hex(value))")
        #endif
    }

    @inline(__always)
    public static func op(_ channel: Int, _ opcode: UInt8, _ name: @autoclosure () -> String) {
        #if OPL_TRACE
        emit("op", "ch=\(channel) op=\(hex(opcode)) \(name())")
        #endif
    }

    @inline(__always)
    public static func trace(_ label: StaticString, _ message: @autoclosure () -> String) {
        #if OPL_TRACE
        emit("\(label)", message())
        #endif
    }
}
```

Two properties make this satisfy the requirement:

1. **Zero cost in release.** With `OPL_TRACE` unset (the default / release), every method body is empty. `@inline(__always)` lets the optimiser delete the call entirely. The `@autoclosure` arguments are **never evaluated** when the body is empty, so even expensive trace-string construction costs nothing. Memoirs is never invoked.
2. **One place to change.** The Memoirs API lives only inside the `#if OPL_TRACE` `emit(...)` helper. If the Memoirs API or version changes, one function changes.

## The Memoirs integration point

Isolate the actual Memoirs calls in a single private helper, configured once:

```swift
#if OPL_TRACE
import Memoirs

extension OPLLog {
    // Configured once; immutable ⇒ Sendable-safe under strict concurrency (no global mutable state).
    private static let memoir: TracedMemoir = TracedMemoir(
        object: "OPL", memoir: PrintMemoir())   // TODO(setup): confirm Memoirs API + chosen Output

    static func emit(_ tracer: String, _ message: String) {
        memoir.debug("\(message)", tracers: [.label(tracer)])   // TODO(setup): match real Memoirs signature
    }
    static func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }
}
#endif
```

> The exact Memoirs constructor / log method names are a **`TODO(setup)`** for the fresh session — wire them once here against the resolved Memoirs version. Everything else stays as written.

## Rules

- **Logging never changes behaviour.** A faithful transcription must produce the identical result with `OPL_TRACE` on or off. Never branch on a log, never let a log mutate state, never let `@autoclosure` evaluation have side effects. Logging is observation only.
- **No `nonisolated(unsafe)` / no `@unchecked Sendable`.** Keep the memoir immutable (`static let`); if per-run configuration is ever needed, pass it in rather than mutating a global (matches the parent project's concurrency rules).
- **The two trace streams that matter** are `OPLLog.reg(...)` (every OPL register write — the driver↔chip seam, the parity stream for `WestwoodADLTests`) and `OPLLog.op(...)` (every driver opcode dispatch — for localizing a divergence). Tap exactly these; add `trace(...)` ad hoc while debugging.

## Enabling traces

- Manifest: uncomment `.define("OPL_TRACE", .when(configuration: .debug))` in `Package.swift`.
- One-off: `swift build -Xswiftc -DOPL_TRACE` / `swift test -Xswiftc -DOPL_TRACE`.
- Release ships with it **off** — verify with `swift build -c release` that Memoirs symbols are absent / unused.
