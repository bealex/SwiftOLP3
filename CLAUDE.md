# SwiftOPL3 — pure-Swift OPL3 chip + Westwood ADL driver

A pure-Swift, **LGPL-2.1** emulation of the Yamaha **YMF262 (OPL3)** FM chip and the **Westwood ADL** music driver, faithful enough to play *Dune II* `.ADL` music exactly as the DOS AdLib did. Foundation-only libraries; no platform UI in the core. Swift 6, strict concurrency.

**Read `CurrentState.md` (repo root) first, before anything else.** It is the operational resume point: active task, what was in-flight, the ordered queue of next steps, the test status. Update it after every task.

After that: `Documentation/Plan.md` is the phased plan; `Documentation/Architecture/Overview.md` is the topology.

## The one rule: faithful transcription, change nothing

This package is a **function-by-function transcription** of two reference C/C++ implementations.

1. **Golden standards.**
   - Chip (`SwiftOPL3`) ⇐ **Nuked-OPL3** (`opl3.c` / `opl3.h`, Nuke.YKT, LGPL-2.1).
   - Driver (`WestwoodADL`) ⇐ **AdPlug `src/adl.cpp` (`CadlPlayer`)**, LGPL-2.1 (a port of the ScummVM/Kyra `adlib.cpp` driver — use ScummVM as a cross-reference/oracle, **AdPlug as the transcription source** to keep the license LGPL).
2. **Do not change anything.** Same control flow, same branches and thresholds, same fixed-point arithmetic and integer widths, same table values, same order of operations. No "improvements", no refactors that alter evaluation order, no floating point where the reference uses integers. Port the bit-twiddling verbatim.
3. **Cite the source.** Every ported function/table carries a doc comment naming the reference `file:line` (e.g. `// Nuked-OPL3 opl3.c:412 OPL3_EnvelopeCalc`). If the reference is unclear, surface the gap in History — do not invent behaviour.
4. **Verification is by golden, not by eye.**
   - Chip: **bit-exact PCM** vs Nuked-OPL3 for a register-write script (integer DSP ⇒ sample-identical). See `Documentation/Architecture/Testing.md`.
   - Driver: **register-write trace equivalence** — our driver emits the identical timed `(port, value)` stream as AdPlug for a given `.ADL` track. This isolates driver bugs from chip bugs.

## Logging — Memoirs, debug-only, zero-cost in release

All tracing goes through **`OPLLog`** (`Sources/SwiftOPL3/OPLLog.swift`). Its bodies are wrapped in `#if OPL_TRACE`, so:
- **Release builds carry zero logging cost** — calls compile to empty `@inline(__always)` no-ops; Memoirs is not invoked.
- Debug tracing is enabled by building with `-DOPL_TRACE` (or the manifest `.define` under `.debug`).
- The faithful port must **never** branch on, or be reordered by, a log call. Logging is observation only. See `Documentation/Architecture/Logging.md`.

Use `OPLLog` for every register write and every driver opcode dispatch (the two trace streams the goldens align against). Do not scatter `print`/`Memoirs` calls directly in ported code.

## Workflow per slice

0. Open `CurrentState.md`; confirm the slice matches the active task (or record a new one).
1. Read the reference function(s) in `References/` (clone first — see below). Update the relevant `Documentation/Architecture/*.md` if the design view changed.
2. Transcribe verbatim. Cite `file:line`. Add `OPLLog` taps where the test harness needs them.
3. Write/extend tests (Swift Testing). Chip: golden PCM. Driver: trace-equivalence. Unit tests for tables/edge cases.
4. Run the suite — `swift test`. Green before "done"; previously-green stays green.
5. Zero warnings on a clean build — `swift build` after `swift package clean`. Read the **full** output.
6. Log the change in `Documentation/History/YYYY-MM-DD.md` (one imperative sentence, with `file:line`).
7. Update `CurrentState.md` (move finished → done, set next active task, refresh test status).

**Commit cadence:** after every 2–3 ported functions / one logical block, on the current branch. End commit messages with the `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` trailer.

## References (not in the build)

Clone the golden standards into `References/` (gitignored). They are read + compiled by golden-generation scripts only; **never** linked into the Swift package.

```
Scripts/fetch-references.sh     # clones Nuked-OPL3, AdPlug, (optionally NScumm.Audio, ScummVM) into References/
Scripts/gen-chip-goldens.sh     # compiles Nuked-OPL3, runs register scripts, dumps PCM → Tests/SwiftOPL3Tests/Fixtures/
Scripts/gen-adl-traces.sh       # instruments AdPlug to dump register-write traces per .ADL track → Fixtures/
```

## What not to do

- Do not "improve", optimise, or restructure the DSP/driver. Faithful transcription is the bar.
- Do not introduce floating point where the reference is integer (and vice-versa).
- Do not add cross-platform abstractions beyond what the reference needs. The core is Foundation-only.
- Do not let logging change behaviour or evaluation order; keep it inside `OPLLog` / `#if OPL_TRACE`.
- Do not vendor the C/C# references into the build — they live under `References/`, used as oracles only.
- Do not hard-wrap Markdown paragraphs.
