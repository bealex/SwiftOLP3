# CurrentState — SwiftOPL3

> Operational resume point. **Read this first.** Update after every task.

## Active task

**Project goal met.** Phases 1–5 are transcribed and verified against the goldens on **real Dune II music**:
- Chip: bit-exact PCM vs Nuked-OPL3 (5 fixtures incl. 4-op/rhythm/resampler).
- Driver: register-write trace equivalence vs AdPlug — synthetic track *and* **real `DUNE8.ADL` subsong 2 (1178 writes, index-for-index)** through the full public `ADLPlayer` path.
- End-to-end: `adlrender` renders real tracks to WAV; `Renders/DUNE8_sub2.wav` + `Renders/DUNE1_sub2.wav` (45 s, audible). **68 tests green, zero warnings.**

To actually listen: `swift build` then
`.build/.../adlrender Resources/Music/DUNE8.ADL 2 45 out.wav` (subsong 2 of DUNE8 is musical; subsongs 0/2/3/4/6 vary per file — 0-based, AdPlug default is 2). Renders land in `Renders/` (gitignored).

Optional next steps (polish, not blockers):
1. Sweep more subsongs/files into the trace golden (parameterise `ADLSongTraceTests`); confirm the ADL track ↔ Dune II `g_table_musics` song-index mapping (OpenDUNE) so the right subsong plays per game event.
2. More chip golden scripts (feedback sweep, EG-edge values).
3. An `AVAudioSourceNode` live-playback host (separate example target, or in a consuming app behind a `MusicBackend`-style seam).

**Locked design decision:** index-based pointer model in both the chip (`SampleRef`/`TremRef`, see `OPL3Types.swift`) and the driver (`dataptr` → `Int?`, effect fn-pointers → enums, `writeOPL` → `OPLRegisterSink`, see `AdLibDriver.swift`).

## Ordered queue (next up)

- **P1 ✅ DONE** OPL3 chip core — bit-exact PCM vs Nuked-OPL3 (verified, 5 fixtures).
- **P2 ✅ DONE** Chip golden harness — `chip_golden_harness.c` + `gen-chip-goldens.sh` emit `sine`/`waveforms`/`fourop`/`rhythm`/`resample44k`; `OPL3GoldenTests` is parameterised + green. (Could add feedback/EG-edge scripts.)
- **P3 ✅ DONE** ADL v2 parse — `ADLData` (`CadlPlayer::load` transcription) + `ADLDataTests`.
- **P4 ✅ DONE** Westwood ADL driver — `AdLibDriver` (+opcodes) + `ADLPlayer`; golden = **register-write trace equivalence vs AdPlug**, on a synthetic track (`ADLTraceTests`) AND a real `DUNE8.ADL` subsong 2 via AdPlug's full `CadlPlayer` load path (`ADLSongTraceTests`, 1178 writes index-for-index).
- **P5 ✅ DONE** End-to-end — `adlrender` example target renders `.ADL`→WAV (driver→chip→PCM); real Dune II tracks produce audible, deterministic output (`ADLPlayerTests`). Rendered `Renders/DUNE8_sub2.wav`, `Renders/DUNE1_sub2.wav` to listen.

## Recently completed

- **Phase 4 driver + Phase 5 first light.** `AdLibDriver` (+`AdLibDriver+Opcodes`) and `ADLPlayer` fully transcribe AdPlug `AdLibDriver`/`CadlPlayer`. Driver verified by **trace equivalence vs AdPlug** (`ADLTraceTests`, 56-write synthetic track incl. key-on/pitchBend/slide). End-to-end synthetic `.ADL` → `ADLPlayer` → `OPL3Chip` renders audible+deterministic PCM (`ADLPlayerTests`).
- **Phase 3 ADL parser.** `ADLData.load` (`CadlPlayer::load`) + offset lookups; `ADLDataTests`.
- **Phase 2 chip golden completed.** 5 bit-exact PCM fixtures (sine/waveforms/fourop/rhythm/resample) via `chip_golden_harness.c`; parameterised `OPL3GoldenTests`.
- **Phase 1 (chip core) — ALL of it**, bit-exact vs Nuked (index-based pointer model; channel-sample-delay quirk reproduced).
- **Phase 0 bootstrap closed.** Memoirs (`bealex/memoirs-ios`, pinned `2.0.0 ..< 2.1.0`), references cloned, Nuked pinned @ `cfedb09e` (v1.8), AdPlug @ `16442997`.

## Test status

**68 tests green** across 15 suites (`swift test`); zero warnings on clean build in both default and `-DOPL_TRACE` configs. Coverage: chip tables/waveforms/reset/registers/EG/phase/generate + 5 bit-exact PCM goldens; ADL parser; driver tables/PRNG; **driver trace-equivalence vs AdPlug (synthetic + real DUNE8.ADL)**; end-to-end ADLPlayer→chip→PCM incl. a real audible Dune II track. (`DUNE*.trace` fixtures regenerate via `gen-adl-traces.sh` when the assets are present; they + `/Resources/` + `/Renders/` are gitignored as game-derived.)

## Notes / open items

- **Memoirs resolved** — `https://github.com/bealex/memoirs-ios.git`, product `Memoirs`, identity `memoirs-ios`, pinned `2.0.0 ..< 2.1.0` (2.1+ needs macOS 15). The `OPLLog.swift` Memoirs API (`TracedMemoir`/`PrintMemoir`/`.debug`/`.label`) compiles under `-DOPL_TRACE` against 2.0.x.
- **Sandbox note:** `swift` commands need `TMPDIR="$PWD/.build/tmp"` set (the default `/tmp` sandbox path rejects executing the compiled manifest).
- **ADL track ↔ song index** mapping: verify the ADL track table indexes 1:1 with the XMIDI sequence index used by Dune II's `g_table_musics` (OpenDUNE).
- `.ADL` test assets are copyrighted game data (not included). Place your own `DUNE*.ADL` under `Resources/Music/` (gitignored) for the real-track trace + render; the suite skips gracefully when they are absent.
