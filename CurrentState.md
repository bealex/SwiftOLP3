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

- **EXPERIMENTAL SIMD fork behind `-DOPL_SIMD` (off by default; integer build unchanged & bit-exact) — conclusive NEGATIVE result: ~50% slower.** A Struct-of-Arrays chip (`OPL3SimdDSP.swift`) that processes melodic channels as SIMD4 lanes. The faithful AoS register/reset/routing layer stays the source of truth (config synced AoS→SoA on write; dynamic state seeded once after reset). Operators reindexed `op=(carrier?18:0)+channel` so rows are contiguous. **Stage A** (scalar SoA, validated identical to float fork: 0.126%/0.999%/0.124%) already runs 6.46 s (46×) vs float fork 6.10 s (49×) — slower before SIMD, from sync + indirection + gather. **Stage B** (branchless integer SIMD4 EG + phase, bit-exact to scalar; scalar feedback/waveform/rhythm; noise advanced by exact count) is **9.34 s (32×) chip / 3.41 s (35×) render** — output identical (checksum 213203/-1522579862), just slower. Why: SIMD4 built from 4 scalar gathers per field, only 3 of 4 lanes active (channels group in 3s), branchless EG computes all paths, and it only touches the per-operator arithmetic (the minority of cost; the dominant integer control logic doesn't speed up). NEON has no gather + the FM/rhythm chain is serial. The Westwood driver is pure OPL2 (no 4-op; rhythm-mode noise LFSR is serial). **Verdict: SoA/SIMD-across-channels not worthwhile here; kept as a documented, validated negative result.** Build: `swift build -Xswiftc -DOPL_SIMD`. Full write-up (forks + measurements + DOSBox DBOPL comparison): **`Documentation/Architecture/Performance.md`** (also linked from `Overview.md`); change log in `Documentation/History/2026-06-04.md`.
- **EXPERIMENTAL float-DSP fork behind `-DOPL_FLOAT` (off by default; integer build unchanged & still bit-exact).** Evaluates whether 32-bit-float synthesis beats the integer log-domain chip. `OPLSample` typealias (`Int16`/`Float`) forks `Slot.out/fbmod/prout` + `mixbuff` + `sample(at:)`; new `OPL3FloatDSP.swift` reimplements slot generate / feedback / clip / mix with a real interpolated-sine LUT × linear gain (control logic — EG, phase, registers, LFOs, write buffer — shared/unchanged). Then applied the transferable matmul-article optimizations: float LUTs on owned `UnsafeMutableBufferPointer` (drops bounds checks) + FMA (`addingProduct`) on the sine lerp. **Finding: float is ~12% faster on pure chip DSP (43→49× RT at plain `-O`; ~14% / 50× with `-Ounchecked`) and ~6% on full render (47→50×).** Bounded because the integer envelope/phase control logic dominates and is untouched/unfloatable. (`-Ounchecked` keeps int bit-exact too, ~2% faster.) **Accuracy:** RMS vs Nuked golden 0.12–0.13% (tonal), 1.0% (rhythm), unchanged by FMA; validated by a new tolerance golden (`OPL3GoldenTests.goldenTolerance`, `#if OPL_FLOAT`). Both builds green (68 tests int incl. bit-exact; float suite incl. tolerance), zero warnings clean. Build float: `swift build -Xswiftc -DOPL_FLOAT`. **Verdict: real but modest speed for the loss of bit-exactness — kept as an opt-in experiment, not adopted.** See `Documentation/History/2026-06-04.md`.
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
