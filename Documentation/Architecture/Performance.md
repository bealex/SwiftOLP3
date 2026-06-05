# Architecture — Performance & the block-SIMD float fork

The shipping chip (`SwiftOPL3`, default build) is a **bit-exact integer** transcription of Nuked-OPL3. This document records the performance investigation around it: where the per-sample time goes, the one experimental DSP fork kept behind a compile flag (**off by default**, the integer chip is untouched and stays the bit-exact golden), what it measures, and — central to this fork — **the license analysis that dictated how it had to be written**.

**One-line conclusion:** the per-operator cost is dominated by *branchy integer control logic* (the envelope-generator state machine + phase generator), not by the synthesis arithmetic. A DBOPL-style block engine that (a) replaces the per-sample EG switch with state dispatch + average-rate tables, (b) culls idle operators, and (c) vectorises the synthesis over the time axis with a polynomial sine, beats the integer chip — **~20 % on a real track, ~1.95× on sparse content** — at the cost of bit-exactness (≈0.13 % RMS on tonal, ≈1 % on rhythm). Because DOSBox's DBOPL is **GPL**, this engine had to be written **clean-room** from the Nuked/LGPL math.

## License analysis — why this fork is clean-room, not a DBOPL port

DOSBox's OPL emulator, **DBOPL** (`dbopl.cpp` / `dbopl.h`), is the canonical "fast block-generating" OPL3. It is the obvious thing to copy. We did **not**, and could not:

- **DBOPL is GPL-2.0-or-later; this package is LGPL-2.1.** A port or transcription of `dbopl.cpp` — even translated to Swift — is a *derivative work*; translation does not shed copyright. The ported file would be **GPL-2.0+**, and because GPL is the stronger copyleft, linking it in forces the **entire distributed work to GPL**. That defeats the point of LGPL (linking into closed-source / differently-licensed apps), which is why the package is LGPL in the first place.
- **Even behind an off-by-default `#if`**, GPL-derived *source* shipping in the tree makes it a mixed-license repo, and any build with the flag on is a GPL combined work. The package rule is that `References/` holds **only** LGPL sources (Nuked-OPL3, AdPlug).
- **Ideas and architecture are not copyrightable — only the specific expression is.** So the three DBOPL *techniques* are fair to learn and reimplement: (1) hoist the branchy per-sample decisions out of the inner loop via **state dispatch**, (2) generate a **block** of samples per call, (3) amortise the slow LFOs **per block**. The actual code in `OPL3BlockSimd.swift` is written from scratch against the Nuked / YMF262 math the rest of the package already uses. `dbopl.cpp` was never opened while writing it.

So `OPL_BLOCKSIMD` realises *the DBOPL idea* under LGPL, which is exactly the direction this document used to flag as "the one direction left, but the code is GPL." It is now built — clean-room.

## Where the time goes

Per sample the integer chip runs `processSlot` for all 36 operators. Each call is, in cost order:

1. `envelopeCalc` (`OPL3Envelope.swift`) — the EG **state machine**: a `switch` on `egGen`, key handling, rate computation, the `egIncstep` table, instant-attack / env-off edge cases. Branchy integer.
2. `phaseGenerate` (`OPL3Phase.swift`) — phase accumulator + vibrato branches + (rhythm slots) the noise LFSR and bespoke bit extraction. Branchy integer.
3. `slotGenerate` — one log-sine table lookup + the exponential-ROM converter. Two lookups + shifts.
4. `slotCalcFB` — feedback shift.

(1) and (2) dominate; (3), the part that "looks like DSP", is the minority. The block fork attacks (1) and (2) directly (state dispatch, average-rate EG, per-block phase increment) and also vectorises (3).

## The fork (compile flag, off by default)

| Flag | File | What it changes | Bit-exact? |
|---|---|---|---|
| *(none)* | `OPL3Generate/Phase/Waveform/Envelope.swift` | faithful integer Nuked port | **yes** (golden) |
| `OPL_BLOCKSIMD` | `OPL3BlockSimd.swift` | clean-room block engine: state-dispatch EG, idle-operator culling, SIMD polynomial-sine synthesis | no (≈0.13 % RMS tonal) |

What each piece does (see the header of `OPL3BlockSimd.swift` for detail):

- **Phase — exact.** A 23-bit integer accumulator (≈ `OPL3_PhaseGenerate`), so pitch never drifts. Only the *increment* is recomputed per block (vibrato sampled per block, not per sample).
- **Envelope — approximated, the speed bet.** A float attenuation advanced by a per-`rate` *average* increment (`OPL3EGRates`), derived by **simulating Nuked's global EG clock once at startup** and averaging the resulting `shift`. State-dispatched instead of Nuked's per-sample switch.
- **Synthesis — approximated, the heavy SIMD.** A branchless **polynomial sine** (parabola + one refinement, ≈0.07 % error, *no table gather* — the reason a LUT float fork can't go wide on NEON) × a linear gain LUT, evaluated `SIMD8<Float>` at a time over the block. Operator full-scale kept at ±4084 (= integer `OPL3_EnvelopeCalcExp(0)`) so FM modulation depth is unchanged.
- **Culling — the main speed lever.** A released operator decayed to silence does no audible work and modulates nothing, so its envelope + synthesis are skipped and its block output left zeroed. On a sparse track most of the 36 operators are idle at any instant; the integer chip runs all of them every sample, this runs only the live ones. (DBOPL culls too.)
- **Serial fallbacks.** Feedback operators (a two-sample recurrence) and rhythm percussion (HH/SD/TC: a per-sample noise LFSR + bespoke phase-bit coupling) are computed scalar per sample — see "Rhythm" below.
- **Envelope one-sample lag — modelled.** Nuked emits `eg_out` from the attenuation *before* it advances that sample, so the first sample after key-on is still at the pre-attack level. The engine matches this (gain emitted, then the float envelope advanced), which removes the per-note-onset transient — important for percussion, which is all onsets.

Build & run:

```
swift build -c release                              # faithful integer (default)
swift build -c release -Xswiftc -DOPL_BLOCKSIMD     # block-SIMD float fork
.build/release/oplbench 120 chip                    # self-labels [int | block-simd-float32 DSP]
.build/release/oplbench 60 render Resources/Music/DUNE8.ADL 2
```

## Measured results

Release, Apple Silicon, best-of-3. `chip` = pure DSP at native 49 716 Hz (120 s audio, a single sustained 2-op note); `render` = full driver→chip→44.1 kHz of `DUNE8.ADL` subsong 2 (60 s). Higher × = faster.

| Build | chip DSP | render | accuracy |
|---|---|---|---|
| **int (faithful, default)** | 2.78 s · **44×** | 1.34 s · **45×** | bit-exact |
| **block-SIMD float** | **1.43 s · 84×** | **1.12 s · 53×** | ≈0.13 % tonal / ≈1 % rhythm |
| speedup | **~1.95×** | **~1.2× (20 %)** | — |

- **`render` (~20 %) is the honest, representative figure** — a real track with many channels live. The win is the net of state-dispatch EG + SIMD synthesis (faster per live operator) and culling (fewer live operators), against the block bookkeeping and the float mix.
- **`chip` (2.2×) is the sparse best case.** A single note keeps 2 of 36 operators live; culling skips the other 34, which the faithful integer chip still processes every sample. It is *not* representative of busy content, but it shows culling's leverage.

The comparison is "faithful integer chip (no culling, bit-exact) vs block fork (culls + vectorises + approximates)". The integer chip is deliberately not allowed to cull or approximate — that exactness is its job; trading it away is what buys the fork its speed.

### Accuracy

`OPL3GoldenTests.goldenTolerance` (`#if OPL_BLOCKSIMD`) measures RMS error vs the Nuked PCM goldens:

- **sine_note 0.127 %, resample 0.126 %** (tonal — tracks Nuked closely; peak ≈0.34 %). On par with the simplest possible float synthesis, despite the EG also being approximated — the average-rate tables track the envelope well.
- **rhythm 1.025 %** (peak ≈3 %). The noise-driven percussion is **modelled faithfully**, so it tracks Nuked as closely as the tonal patches — it just clips to full scale, hence the looser ceiling. See "Rhythm" below.
- **fourop / waveforms** — silent in the Nuked reference itself, so vacuous.

## Rhythm — modelling the percussion in a block engine

OPL rhythm percussion looks hostile to block generation, and a naïve port is badly wrong (the first cut measured 34 % RMS). Three things have to be right, and all three are per-sample state that a block-over-time loop reorders:

1. **The noise LFSR.** Nuked advances a global 23-bit LFSR **once per operator per sample** — 36×/sample, in slot order — and the drums at slots 13 (HH) / 16 (SD) read `noise & 1` after exactly 13 / 16 advances. `synthRhythm` reproduces this: when rhythm mode is on it advances the LFSR 36×/sample in a dedicated loop (decoupled from the melodic operators, which no longer touch noise), snapshotting the two read points. Because the LFSR value depends only on the *count* of advances, not which operator did them, the snapshots match Nuked bit-for-bit. (When rhythm is off the LFSR isn't touched — zero cost on melodic tracks.)
2. **The rmHH/rmTC phase-bit coupling.** HH/SD/TC share `rmHHBit*`/`rmTCBit*` derived from the slot-13 and slot-17 phase, with a precise ordering: slot 13 sets the HH bits and reads the TC bits from the *previous* sample; slot 17 sets the TC bits and reads this sample's HH bits. `synthRhythm` processes the three drums in slot order per sample, so the coupling matches.
3. **The channel-sample-delay quirk.** Nuked computes the LEFT mix after only slots 0..14, so a channel output referencing a slot ≥15 reads the *previous* sample there; the rhythm channels 6/7/8 use slots 15/16/17, so their left output lags one sample. Modelling this (a per-slot "fresh-through" threshold in the mix, bridged across block edges) was the single biggest rhythm fix — 22 % → 1 %.

BD (slots 12/15) and TT (slot 14) carry no noise and stay on the vectorised block path. The result is percussion that matches Nuked to ~1 % RMS — the same order as the tonal patches.

## How this maps to DBOPL (architecture only)

| | **SwiftOPL3 integer (Nuked)** | **`OPL_BLOCKSIMD` (clean-room)** | **DBOPL (DOSBox, GPL — not used)** |
|---|---|---|---|
| Goal | bit-exact hardware model | fast, tonal-faithful approximation | "sounds right", fast |
| Per-sample branching | `switch` every op every sample | state-dispatched EG, per-block phase | none — state-dispatched |
| Generation | one sample at a time | **blocks** (≤32, capped to write boundaries) | **blocks** (`GenerateBlock2/3`) |
| LFO (vib/trem) | per sample | **per block** | **per block** (`ForwardLFO`) |
| Idle operators | processed every sample | **culled** | culled |
| Synthesis | log-sine ROM + exp ROM (int) | polynomial sine × gain LUT (**SIMD float**) | table-based (int) |
| License | LGPL-2.1 | **LGPL-2.1** | **GPL-2.0+** |

The structural overlap with DBOPL is intentional (the techniques are public knowledge); the *code* shares nothing with `dbopl.cpp`, and unlike DBOPL the synthesis here is float + SIMD with a polynomial sine.

## Earlier experiments (removed)

Two earlier forks were built and then removed once this one superseded them; they live in git history (commit `12e2523`) and are summarised here so the conclusions aren't lost:

- **`OPL_FLOAT`** — per-sample float synthesis with a sine LUT, keeping the integer EG/phase. ~12 % faster on chip DSP. Correct (~0.13 %) but bounded: it only touched the minority synthesis arithmetic, and the LUT can't vectorise on NEON (gather). Subsumed by the block fork's polynomial sine.
- **`OPL_SIMD`** — Struct-of-Arrays chip processing melodic *channels* as SIMD4 lanes. **~50 % slower** — the wrong SIMD axis: no NEON gather, only 3 of 4 lanes active (channels group in 3s), branchless EG computing all paths, and the serial FM chain. The block fork's lesson: vectorise across **time** (consecutive samples of one operator), not across channels.

## Verification

- `swift test` (default) — 68 tests, including the bit-exact `OPL3GoldenTests.golden`. The integer build stays the golden.
- `swift test -Xswiftc -DOPL_BLOCKSIMD` — 65 tests: the tolerance golden `goldenTolerance` (tonal ≤0.5 %, rhythm ≤2 %, all asserted) plus all behavioural/determinism tests; the exact-integer-value unit tests are gated `#if !OPL_BLOCKSIMD`.
- Zero warnings on a clean build in both configurations.

See `Documentation/History/2026-06-04.md` for the change log and `Documentation/Architecture/Testing.md` for the golden methodology.
