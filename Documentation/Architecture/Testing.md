# Testing — the parity bar

The philosophy: **verify against the golden standard, don't re-derive.** Two distinct goldens because the two components fail in distinct ways (see `Overview.md` §Why this split). Swift Testing (`import Testing`).

## Chip golden — bit-exact PCM (SwiftOPL3Tests)

Nuked-OPL3's DSP is integer-only, so a correct Swift port is **sample-for-sample identical**. The golden is therefore **`Int16` byte-equality**, not a tolerance.

Method:
1. `Scripts/gen-chip-goldens.sh` compiles the cloned Nuked-OPL3 with a tiny C harness that:
   - `OPL3_Reset(&chip, 49716)` (and a 44100 variant for the resampler test),
   - replays a **register-write script** (a text/JSON list of `(samples_to_advance, reg, val)` steps),
   - dumps the produced PCM to `Tests/SwiftOPL3Tests/Fixtures/<name>.pcm` (raw interleaved LE `Int16`),
   - and writes the script alongside as `<name>.script`.
2. The Swift test loads `<name>.script`, drives `OPL3Chip` identically, and asserts the rendered `[Int16]` equals `<name>.pcm` exactly.

Scripts to cover (each its own fixture): a single 2-op sine note (key-on, sustain, key-off); each of the 8 waveforms; a 4-op patch (OPL3 `newm`); feedback sweep; KSL/TL/AR/DR/SL/RR edge values; rhythm mode (BD/SD/TT/CYM/HH); the resampler (49716→44100); a register-bank sweep. Plus the **first real `.ADL` track's captured register stream** replayed through the chip once the driver exists (closes the loop chip-side).

Also: **table unit tests** — assert each ported table's length and several spot values against `opl3.c` literals (catches a transcription typo before it poisons every render).

## Driver golden — register-write trace equivalence (WestwoodADLTests)

The primary parity bar. Our driver must emit the **identical timed `(port, value)` stream** as AdPlug for a given `.ADL` track.

Method:
1. `Scripts/gen-adl-traces.sh` builds AdPlug (or a minimal harness linking `adl.cpp`) with `writeOPL`/`opl->write` instrumented to append `tick port value` lines, runs it over `DUNEn.ADL` subsong K for N ticks, and writes `Tests/WestwoodADLTests/Fixtures/DUNEn.<K>.trace`.
2. The Swift test runs `ADLPlayer` over the same track for N ticks with `OPL_TRACE`-equivalent capture (a test-only `OPLLog` sink, or a recording `OPL3Chip` subclass/seam that records writes), and asserts the captured `(tick, port, value)` sequence equals the fixture **index-for-index**.
3. On mismatch: report the **first divergent index** and the surrounding opcodes — that localizes the buggy `update_*`. (Mirrors the parent project's RNG-trace-diff discipline: fix the first divergence, never gate around it.)

Capture seam: give the driver a `RegisterSink` it writes through (default = the real `OPL3Chip`; tests inject a recorder). This keeps capture out of `#if OPL_TRACE` so trace tests run in release config too.

## End-to-end — PCM render + ear (Phase 5)

- Render `DUNEn.ADL` (driver → chip → PCM) to a WAV at 44 100 Hz.
- Compare to an AdPlug-rendered WAV. **Same chip** (both Nuked) ⇒ expect near-exact; gate on a tight tolerance or a spectral check (not byte-equality, because AdPlug's resampler/output stage may differ).
- **Listen.** The user's stated acceptance test. A manual-verification checklist lives in `Plan.md` §Phase 5.

## Coverage rules (inherited)

- Every `throw`ing parse path (ADL header) has a test that throws it.
- Every table has a length + spot-value test.
- Every public function has at least one test on real or synthetic input.
- Fixtures are committed; the C/C# references that *generate* them are not (`References/` is gitignored). Tests **short-circuit (skip) when a fixture or the `.ADL` asset is absent**, so the suite stays green on a fresh checkout without the install.

## Determinism note

The chip and driver are fully deterministic (the driver's own `_rnd` is seeded/transcribed exactly). Same `.ADL` + same subsong + same tick count ⇒ identical trace and identical PCM, every run.
