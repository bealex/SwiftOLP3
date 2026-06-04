# Architecture — Overview

Two libraries, one direction of dependency. The driver drives the chip; the chip knows nothing of the driver.

```
.ADL bytes ──► [ WestwoodADL ] ──timed (port,value) writes──► [ SwiftOPL3 ] ──Int16 PCM──► host (AVAudioSourceNode / WAV)
               driver / sequencer                              YMF262 chip
               (AdPlug CadlPlayer port)                        (Nuked-OPL3 port)
```

## Targets

| Target | Role | Reference | Depends on |
|---|---|---|---|
| `SwiftOPL3` | OPL3 (YMF262) chip: register file → FM operators → PCM | Nuked-OPL3 `opl3.c/.h` | Foundation, Memoirs (trace only) |
| `WestwoodADL` | Westwood ADL driver: bytecode sequencer → register writes | AdPlug `adl.cpp` `CadlPlayer` | `SwiftOPL3`, Foundation, Memoirs (trace only) |

Both are Foundation-only and platform-agnostic. No audio I/O, no UI in the core — a host (this package's `adlrender` example, or a consuming app) feeds the PCM to `AVAudioEngine`.

## SwiftOPL3 — the chip

A faithful port of Nuked-OPL3. Public surface mirrors the C API:

```swift
public final class OPL3Chip {            // ≈ opl3_chip
    public init(sampleRate: UInt32)      // ≈ OPL3_Reset(&chip, samplerate)
    public func reset(sampleRate: UInt32)
    public func write(_ reg: UInt16, _ value: UInt8)            // ≈ OPL3_WriteReg
    public func writeBuffered(_ reg: UInt16, _ value: UInt8)    // ≈ OPL3_WriteRegBuffered (timed queue)
    public func generate() -> (Int16, Int16)                    // ≈ OPL3_Generate (one native-rate sample, L/R)
    public func generateResampled() -> (Int16, Int16)           // ≈ OPL3_GenerateResampled (to sampleRate)
    public func generateStream(into buffer: inout [Int16], frames: Int)
}
```

Native chip rate is **49 716 Hz** (= 14 318 181 / 288). `generateResampled` linearly interpolates to the requested `sampleRate`, exactly as `OPL3_GenerateResampled` does. Internals (slots, channels, EG/PG, tables) are `internal`, transcribed 1:1 from the C — see `OPL3.md`.

Integer-width mapping (must be exact — the DSP relies on wraparound):

| Nuked C | Swift |
|---|---|
| `Bit8u` / `Bit8s` | `UInt8` / `Int8` |
| `Bit16u` / `Bit16s` | `UInt16` / `Int16` |
| `Bit32u` / `Bit32s` | `UInt32` / `Int32` |
| `Bit64u` / `Bit64s` | `UInt64` / `Int64` |

Use `&+ &- &*` (overflow-wrapping operators) wherever the C relies on unsigned/signed wraparound, and explicit truncating conversions (`Int16(truncatingIfNeeded:)`) where C does implicit narrowing. **This is the single most error-prone part of the port** — see `Testing.md`.

## WestwoodADL — the driver

A faithful port of AdPlug `CadlPlayer`. Public surface:

```swift
public final class ADLPlayer {
    public init(chip: OPL3Chip)
    public func load(_ data: Data)                 // parse the .ADL (Formats/ADL.md)
    public var subsongCount: Int { get }
    public func rewind(subsong: Int)               // ≈ CadlPlayer::rewind
    @discardableResult public func update() -> Bool // ≈ CadlPlayer::update — one driver tick; false at end
    public var refreshRate: Double { get }          // ≈ getrefresh() — ticks/sec to schedule update()
}
```

The driver's only effect on the world is `chip.write(reg, val)`. All register writes funnel through one internal `writeOPL(_:_:)` that taps `OPLLog.reg(...)` — that tap is the trace stream the goldens align against AdPlug. The ~75 opcode callbacks, channel state, and dispatch tables are transcribed verbatim from `adl.cpp` (see `WestwoodADL.md`).

## Why this split

Verifying the driver and the chip independently is the whole point of the parity strategy:
- A **chip** divergence shows up as a PCM mismatch under a fixed register script — a DSP/transcription bug, not a sequencing bug.
- A **driver** divergence shows up as a register-write-stream mismatch — a sequencing bug, independent of any DSP rounding.

Mixing them (only ever checking final PCM of a full song) would make every bug ambiguous. Keep the seams clean.

## Logging seam

`OPLLog` (in `SwiftOPL3`) is the only logging entry point; both targets use it. Compiled out in release. See `Logging.md`.

## Performance & experimental DSP variants

The default chip is bit-exact integer. Experimental float (`OPL_FLOAT`) and SIMD-across-channels (`OPL_SIMD`) forks live behind compile flags (off by default). The performance investigation — where the per-sample time goes, what each fork measured, and how DOSBox's DBOPL emulator differs (and why we can't borrow it) — is written up in `Performance.md`.
