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

- **EXPERIMENTAL block-SIMD float fork behind `-DOPL_BLOCKSIMD` (off by default; integer build unchanged & still bit-exact) — POSITIVE result: faster than the integer chip, rhythm modelled.** A clean-room, DBOPL-architecture-inspired block-generating SIMD float engine (`OPL3BlockSimd.swift`) that `OPL3Chip.generate4Ch()` delegates to under the flag. Reads config from the AoS register layer each block (no SoA mirror), keeps its own float state. Pieces: exact integer phase accumulator (per-block increment); state-dispatched float EG advanced by per-`rate` *average* increments (`OPL3EGRates`, derived by simulating Nuked's EG clock once at startup) instead of the per-sample switch, with Nuked's one-sample `eg_out` lag modelled; branchless polynomial sine (≈0.07 %, no gather) × gain LUT, `SIMD8<Float>` over the block; **idle-operator culling** (the main speed lever); scalar fallback for feedback; **faithful rhythm** (`synthRhythm`: noise LFSR advanced 36×/sample with snapshots at the slot-13/16 read points, rmHH/rmTC bit coupling in slot order, and the channel-sample-delay quirk in the mix). **Performance (best-of-3): chip DSP 2.78 s → 1.43 s (44× → 84×, ~1.95× — culling); render DUNE8 sub2 1.34 s → 1.12 s (45× → 53×, ~20 %, the representative figure).** **Accuracy:** sine_note 0.127 %, resample 0.126 %, rhythm 1.025 % RMS vs Nuked (all asserted). Both builds green (68 int incl. bit-exact; 65 under flag), zero warnings clean.
  - **LICENSE — clean-room, NOT a DBOPL port.** DOSBox's DBOPL (`dbopl.cpp`) is **GPL-2.0+**; this package is **LGPL-2.1**. A port would be a derivative work → GPL → defeats LGPL. Only DBOPL's *techniques* (state dispatch, block generation, per-block LFO, culling) are reused — architecture, not copyrightable expression. `dbopl.cpp` never opened; written against the package's Nuked/LGPL math. `References/` still LGPL-only.
  - The two earlier forks (`OPL_FLOAT`, `OPL_SIMD`) were removed and replaced by this one; they survive in git history (commit `12e2523`). Full write-up + license analysis + measurements: **`Documentation/Architecture/Performance.md`** (linked from `Overview.md`); change log in `Documentation/History/2026-06-04.md`. Build: `swift build -Xswiftc -DOPL_BLOCKSIMD`.
- **Driver ARC/allocation cleanup (real-time-audio safety).** Three steps, all output-bit-identical (render checksum 1434131890 unchanged), 68 tests green, zero warnings:
  1. `Channel.dataptrStack` `[Int?]` → fixed tuple `(Int?, Int?, Int?, Int?)` → `Channel` becomes a **trivial** value type; `initChannel` no longer heap-allocates per tick.
  2. `AdLibDriver.sink` `weak` → strong, dropping the atomic weak-load from `writeOPL`.
  3. **`_channels`/`_programQueue`/`_soundData` → owned `UnsafeMutableBufferPointer`** (chip's `slot`/`channel` model; enabled by step 1 making `Channel` trivial). **A CPU win, not an allocation win.** Driver-tick CPU ~4.9× (3.95 → 0.81 s for 14.4M ticks) by removing Swift `Array` bounds/exclusivity/COW-uniqueness-check/element-copy overhead (the symbols that topped the Time Profiler).
  - **Corrected mis-diagnosis (measured with `Scripts/count-allocs.sh`, a libmalloc `malloc_logger` interpose):** the driver tick **never allocated per-tick** — baseline and optimized both allocate a constant ~780 total regardless of run length; all startup. The profiler's `beginCOWMutation` was a uniqueness *check* on a uniquely-owned buffer (no copy), not a per-mutation COW allocation. The slow `driver` Allocations *instrument* run was VM-Tracker/instrument overhead on this macOS 26 beta, not app allocations. Use `count-allocs.sh` (exact, no GUI) over the Allocations instrument for this question.
  - Profiling harness: `oplbench` `driver` mode + `Scripts/record-traces.sh` (mode × instrument matrix → gitignored `Traces/`; Allocations rows kept short) + `Scripts/count-allocs.sh`.
  - Minor item left as-is: `pitchBendTables`/`unkTable2` `[[UInt8]]` indexing retains an inner `Array` per access (per-note, not per-tick). The chip hot loop was already allocation/ARC-free.
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
