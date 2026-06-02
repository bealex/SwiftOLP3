# Plan — SwiftOPL3

The goal: a pure-Swift, LGPL-2.1 OPL3 chip + Westwood ADL driver that plays *Dune II* `.ADL` music exactly as DOS AdLib did, built as a **faithful function-by-function transcription** of two reference implementations, with a test suite that proves fidelity.

Acceptance, in the user's words:
1. Carefully, function by function, rewrite everything in Swift — change nothing.
2. Implement the whole test suite; all cases pass.
3. Then test with Dune II music — how it sounds.

## Decisions (locked)

- **Chip reference:** Nuked-OPL3 (`opl3.c`/`opl3.h`). Bit-exact, integer-only, the gold standard.
- **Driver reference:** AdPlug `src/adl.cpp` (`CadlPlayer`), LGPL — transcription source. ScummVM Kyra `adlib.cpp` + NScumm.Audio (C#) — cross-reference/oracles.
- **Language:** pure Swift, Foundation-only core. No C in the build (the C references are oracles only).
- **License:** LGPL-2.1-or-later.
- **Logging:** Memoirs, routed through `OPLLog`, compiled out in release (`#if OPL_TRACE`).

## Phases

Each phase ends with its golden green and a commit. Within a phase, work in 2–3-function blocks.

### Phase 0 — bootstrap *(skeleton done)*
Package builds empty; Memoirs resolves; `References/` clone script; golden-generation scripts stubbed. Confirm `swift build` / `swift test` run.

### Phase 1 — OPL3 chip core  (`Sources/SwiftOPL3/`)
Transcribe Nuked-OPL3 in dependency order (detail in `Architecture/OPL3.md`):
1. **Tables** — `logsinrom[256]`, `exprom[256]`, `kslrom[16]`, `kslshift[4]`, multiplier `mt[16]`, EG increment/step tables, vibrato/tremolo tables, the rhythm/noise constants. Unit-test each (length + spot values).
2. **Types** — `opl3_slot`, `opl3_channel`, `opl3_chip` as Swift structs/classes with the exact fields and integer widths (`Int16`/`UInt16`/`Int32`/`UInt32` matching `Bit16s`/`Bit16u`/`Bit32s`/`Bit32u`).
3. **Envelope generator** — `OPL3_EnvelopeUpdateKSL`, `OPL3_EnvelopeCalc` (the EG state machine), rate computation.
4. **Phase generator** — `OPL3_PhaseGenerate`, vibrato.
5. **Slot / waveform** — the 8 waveform functions, `OPL3_SlotWrite20/40/60/80/E0`, `OPL3_SlotGenerate`, `OPL3_SlotCalcFB`.
6. **Channel / algorithm** — `OPL3_ChannelSetupAlg`, `OPL3_ChannelUpdateAlg`, `OPL3_ChannelUpdateRhythm`, `OPL3_ChannelWriteA0/B0/C0`, key on/off, 2-op/4-op, stereo pan.
7. **Top level** — `OPL3_Generate` (the per-sample core), `OPL3_Reset`, `OPL3_WriteReg` + `OPL3_WriteRegBuffered`, `OPL3_GenerateResampled`, `OPL3_GenerateStream`.

**Golden (Phase 1 close):** bit-exact PCM vs Nuked-OPL3 over a register-write script (Phase 2 harness).

### Phase 2 — chip golden harness  (`Scripts/` + `SwiftOPL3Tests/`)
`gen-chip-goldens.sh`: compile Nuked-OPL3, run a set of register-write scripts (a tone, a 4-op patch, rhythm mode, register sweeps), dump PCM to `Fixtures/*.pcm`. Swift tests feed the identical script to the port and assert **sample-for-sample equality** (`Int16`). See `Architecture/Testing.md`.

### Phase 3 — ADL v2 format parse  (`Documentation/Formats/ADL.md`)
Parse the version-2 header: track-pointer table, instrument table, per-program offsets for `DUNE*.ADL`. A `Formats`-style test dumping the table and asserting against a known-good reference (AdPlug `load()` output).

### Phase 4 — Westwood ADL driver  (`Sources/WestwoodADL/`)
Transcribe AdPlug `CadlPlayer`: the `Channel` state, `update()` tick, `setupPrograms`/`executePrograms`, `noteOn/Off`, the primary/secondary effects, and the **~75 `update_*` opcode callbacks** + the `_parserOpcodeTable`/`_callbackTable` dispatch arrays — verbatim. Every register write goes through the chip via `OPLLog`-tapped calls.

**Golden (Phase 4 close):** register-write **trace equivalence** — our driver produces the identical timed `(port, value, tick)` stream as AdPlug for each `.ADL` track. This is the primary parity bar; it isolates driver bugs from chip bugs.

### Phase 5 — end-to-end + listen
A small render tool: load `DUNEn.ADL`, run the driver at its tick rate driving the chip, render to a WAV at 44.1 kHz. Compare against an AdPlug-rendered WAV (same chip ⇒ near-exact; gate on tolerance/spectral if cores differ). **Then play it and judge by ear** — the user's final acceptance test. A thin `AVAudioSourceNode` host can live in a separate example target (out of the Foundation-only core).

## Out of scope (for now)

- OPL2-only (YM3812) quirks beyond what OPL3-in-OPL2-mode covers (Nuked-OPL3 handles OPL2 content via the non-`NEW` path).
- Other ADL versions (v1 EOB1, v3) beyond v2 — Dune II is v2. Add only if a fixture needs it.
- Integration into a host application — that wiring belongs in the consuming app behind a `MusicBackend`-style seam, depending on this package.
