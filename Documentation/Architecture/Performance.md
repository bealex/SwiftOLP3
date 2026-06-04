# Architecture — Performance & experimental DSP variants

The shipping chip (`SwiftOPL3`, default build) is a **bit-exact integer** transcription of Nuked-OPL3. This document records the performance investigation around it: where the per-sample time actually goes, the experimental DSP forks built behind compile flags (all **off by default**, the integer chip is untouched and stays the bit-exact golden), what each measured, and how DOSBox's **DBOPL** emulator differs and what that teaches us.

**One-line conclusion:** the per-operator cost is dominated by *branchy integer control logic* (the envelope-generator state machine + phase generator), not by the synthesis arithmetic. So floating-point helps only modestly (~12 %), SIMD-across-channels is a net loss (~50 % slower), and the only approach that targets the real bottleneck — DOSBox-style block generation with state-specialised inner loops — buys its speed by giving up bit-exactness (and is GPL, so unusable here as source).

## Where the time goes

Per sample the chip runs `processSlot` for all 36 operators. Each call is, in cost order:

1. `envelopeCalc` (`OPL3Envelope.swift`) — the EG **state machine**: a `switch` on `egGen`, key on/off handling, rate computation, the `egIncstep` table, instant-attack / env-off edge cases. Branchy integer.
2. `phaseGenerate` (`OPL3Phase.swift`) — phase accumulator + vibrato branches + (for the rhythm slots) the noise LFSR and bespoke bit extraction. Branchy integer.
3. `slotGenerate` — one log-sine table lookup + the exponential-ROM converter (`OPL3Waveforms.swift`). Two table lookups + shifts.
4. `slotCalcFB` — feedback shift.

(1) and (2) dominate. (3), the part that "looks like DSP", is the minority. Every speed result below follows from that fact.

## The experimental forks (compile flags, off by default)

| Flag | File | What it changes | Bit-exact? |
|---|---|---|---|
| *(none)* | `OPL3Generate/Phase/Waveform/Envelope.swift` | faithful integer Nuked port | **yes** (golden) |
| `OPL_FLOAT` | `OPL3FloatDSP.swift` | per-sample synthesis → 32-bit float (real sine LUT × linear gain) | no (≈0.13 % RMS) |
| `OPL_SIMD` | `OPL3SimdDSP.swift` | Struct-of-Arrays chip, melodic channels as SIMD4 lanes | no (≈0.13 % RMS) |

`OPL_FLOAT` and `OPL_SIMD` are mutually exclusive and both imply `OPLSample = Float` (see `OPL3Types.swift`). The sample type, `mixbuff`, and the per-sample slot functions are forked behind `#if`; the register file, reset, routing, EG/phase control flow and the timed write buffer are **shared and unchanged**.

Build & run:

```
swift build -c release                          # faithful integer (default)
swift build -c release -Xswiftc -DOPL_FLOAT     # float fork
swift build -c release -Xswiftc -DOPL_SIMD      # SoA / SIMD fork
.build/release/oplbench 300 chip                # self-labels [int|float32|simd-float32 DSP]
.build/release/oplbench 120 render Resources/Music/DUNE8.ADL 2
```

## Measured results

Release, Apple Silicon, best-of-3. `chip` = pure DSP at native 49 716 Hz (300 s audio); `render` = full driver→chip→44.1 kHz of `DUNE8.ADL` subsong 2 (120 s). Higher × = faster.

| Build | chip DSP | render | accuracy |
|---|---|---|---|
| **int (faithful, default)** | 6.90 s · **43×** | 2.65 s · **45×** | bit-exact |
| int, `-Ounchecked` | 6.74 s · 45× | — | bit-exact (checksum unchanged) |
| float fork (initial) | 6.51 s · 46× | 2.54 s · 47× | ≈0.13 % RMS |
| **float fork (+unsafe LUTs +FMA)** | **6.10 s · 49×** | **2.40 s · 50×** | ≈0.13 % RMS |
| float fork, `-Ounchecked` | 5.96 s · 50× | — | ≈0.13 % RMS |
| SoA scalar (SIMD Stage A) | 6.46 s · 46× | 2.51 s · 48× | ≈0.13 % RMS |
| **SoA + SIMD (SIMD Stage B)** | **9.34 s · 32×** | **3.41 s · 35×** | ≈0.13 % RMS |

Accuracy is measured by `OPL3GoldenTests.goldenTolerance` (`#if OPL_FLOAT || OPL_SIMD`) as RMS error vs the Nuked PCM goldens: **sine_note 0.126 %, resample 0.124 %, rhythm 0.999 %** (rhythm clips to full scale; its peak error is 2.35 %). The `fourop`/`waveforms` goldens are silent in the Nuked reference itself, so those two cases are vacuous. The float and SIMD forks produce numerically identical output (same checksums) — the SIMD path is a *correct* implementation that is simply slower.

### `OPL_FLOAT` — float synthesis (~12 % faster)

Replaces the log-sine ROM + exponential ROM (which multiply by adding in the log domain) with a real interpolated sine LUT × a linear envelope gain. Operator full-scale is kept at ±4084 (= integer `OPL3_EnvelopeCalcExp(0)`) so the FM phase-modulation depth and amplitude scale are unchanged; only the synthesis math becomes float. EG, phase, routing, LFOs stay integer and identical.

Two of the transferable "Training an LLM in Swift" matmul-article optimizations apply (the rest — threading, AMX, Metal — do not, the FM chain is serial):
- **Owned `UnsafeMutableBufferPointer` LUTs** (`sine`/`gain`/`feedback`, `nonisolated(unsafe) static let`) drop the per-lookup bounds check — recovering nearly all of the global `-Ounchecked` win *safely*, scoped to the tables.
- **FMA** (`Float.addingProduct`, stdlib — no swift-numerics dependency) on the sine lerp, the one genuine mul-add site.

These roughly doubled the advantage, from ~6 % to ~12 %. The ceiling is low because float only touches the minority synthesis arithmetic — the dominant integer EG/phase control logic is unchanged.

### `OPL_SIMD` — channels as SIMD lanes (~50 % slower)

A full Struct-of-Arrays chip that processes melodic channels in SIMD4 lanes. Built and validated in two stages:

- **State model.** The faithful AoS register/reset/routing layer stays the source of truth (it runs at register-write rate, ~72 Hz, not per sample). A persistent SoA mirror (`OPL3SimdState`) holds the per-sample hot-loop state; operators are reindexed `op = (carrier ? 18 : 0) + channel` so each row (18 modulators 0..<18, 18 carriers 18..<36) is contiguous for SIMD loads. Config is synced AoS→SoA when a register write dirties it (`simdDirty`); dynamic state is seeded from AoS once after reset (`simdNeedsSeed`). Verified the register layer never reads per-sample dynamic state, so the split is sound.
- **Stage A** (scalar SoA): a faithful slot-order re-expression of the float fork on SoA storage — config sync, modulation/output-routing resolution to SoA indices, per-operator noise sequencing, the two-pass mix and the channel-sample-delay quirk. Tolerance is **identical** to the float fork, proving the re-layout is correct. It already runs slower (6.46 s vs 6.10 s) — purely from sync + `op→slot` indirection + the channel-output gather, *before* any SIMD.
- **Stage B** (branchless SIMD4): melodic operators processed in SIMD4 chunks — branchless **integer** SIMD `simdEnvVec` (EG) and `simdPhaseVec` (phase), bit-exact to scalar (tolerance unchanged); feedback + waveform synthesis stay scalar per lane (the waveform is an inherently per-lane LUT); the rhythm section (channels 6–8) stays scalar in slot order; the noise LFSR advances by exact per-operator count.

It is decisively slower. Why:
- **No NEON gather** — each SIMD4 is built from 4 scalar loads per field (~14 in the EG, ~6 in phase) and stored back via scalar loops; the gather/scatter overhead dwarfs the vector benefit.
- **3 of 4 lanes active** — OPL channels group in 3s, wasting 25 % of every vector.
- **Branchless overhead** — the EG computes *all* state-transition paths every sample (lane 3 in Attack while lane 5 is in Release).
- **Wrong target** — all that overhead is spent on the minority synthesis/EG arithmetic; the serial FM/rhythm structure and table-driven synthesis are fundamentally hostile to SIMD on this hardware.

## How DOSBox's DBOPL differs

DOSBox ships its own OPL emulator, **DBOPL** (`dbopl.cpp`), at the opposite end of the design spectrum from Nuked. We use it only as an architectural reference — see the license note below.

| | **SwiftOPL3 (Nuked-OPL3)** | **DBOPL (DOSBox)** |
|---|---|---|
| Goal | bit-exact hardware model | "sounds right", fast |
| Fidelity | sample-identical to the YMF262 | optimised **approximation** (smaller envelope tables; its own comment notes this is the biggest audible difference) |
| Per-sample branching | `switch` on `egGen` and `regWf` every sample, every operator | **none** — state-dispatched |
| Generation | one sample at a time | **blocks** (`GenerateBlock2/3`) |
| LFO (vib/trem) | per sample | **per block** (`ForwardLFO`) — an approximation |
| Arithmetic | integer | integer |
| License | LGPL-2.1 | **GPL-2.0+** |

DBOPL's speed comes from **hoisting the branchy decisions out of the per-sample loop**:
- each operator holds a `volHandler` function pointer → one of five `TemplateVolume<OFF/ATTACK/DECAY/SUSTAIN/RELEASE>` routines; `SetState()` swaps the pointer on a state change instead of branching per sample;
- the waveform is a `waveBase/waveMask/waveStart` (or `waveHandler`) set when the `0xE0` register is written, never re-decided per sample;
- each channel holds a `synthHandler` → a **template-specialised** block generator (`BlockTemplate<sm2FM>`, `sm3AM`, `sm3FMFM`, …) for its connection algorithm.

Combined with block generation, the inner loop becomes a tight, branch-free, fully-inlined specialised routine that runs N samples with fixed state. That is the only design here that attacks our actual bottleneck (the branchy control logic).

### Why we can't just adopt it

1. **License.** DBOPL is **GPL-2.0+**; this package is LGPL-2.1. We cannot transcribe or copy it — only learn from the architecture. Being an approximation, it could not serve as a bit-exact golden either. (`References/` holds only Nuked-OPL3 and AdPlug, both LGPL.)
2. **The bit-exactness tension.** The biggest DBOPL wins — block generation with **per-block LFO amortisation** and smaller tables — are approximations *incompatible with our bit-exact default*. To stay sample-identical to Nuked we must advance the EG timer and LFOs every sample, which limits how much a block loop can be specialised. DBOPL is fast for the same reason our float fork is: it trades exactness (table size + per-block LFO) for speed, just in a different place.
3. **Swift vs C++.** DBOPL's win leans on C++ *template specialisation* (compile-time per-state loops the compiler fully inlines). A naive Swift function-pointer port adds indirect-call overhead and blocks inlining; a Swift `switch` on a `UInt8` is already a jump table. Reproducing the effect needs block generation with state-specialised inner loops (generics / `@inline`), not just pointers.

## Verdict and the one direction left

- **Float (`OPL_FLOAT`)** — a real but modest ~12 % win for the loss of bit-exactness. Kept as an opt-in option.
- **SIMD (`OPL_SIMD`)** — ~50 % slower; a documented, validated negative result. Kept behind the flag as evidence, not for use.
- **DBOPL-style block + state dispatch** — the only approach that targets the dominant cost, but its real speed requires the same bit-exactness sacrifice as the float fork, and the code is GPL.

If more speed is ever wanted, the **bit-exact-preserving slice** of the DBOPL idea is the candidate: per-slot waveform-handler dispatch + block generation with the LFO/EG-timer kept exact (advanced per sample), behind a new flag, written from scratch (LGPL, Nuked math) so the golden tests stay bit-exact. Whether the block restructure alone — without DBOPL's approximations — beats the current per-sample loop is unmeasured and uncertain. Not yet attempted.

## Verification

All forks are validated against the same Nuked PCM goldens, and the default integer build stays the bit-exact golden:
- `swift test` (default) — 68 tests, including the bit-exact `OPL3GoldenTests.golden`.
- `swift test -Xswiftc -DOPL_FLOAT` / `-DOPL_SIMD` — the tolerance golden `goldenTolerance` plus all behavioural/determinism tests; the exact-integer-value unit tests are gated `#if !OPL_FLOAT && !OPL_SIMD`.
- Zero warnings on a clean build in every configuration.

See `Documentation/History/2026-06-04.md` for the change log and `Documentation/Architecture/Testing.md` for the golden methodology.
