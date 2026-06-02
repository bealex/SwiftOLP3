# Westwood ADL driver — porting AdPlug CadlPlayer

Reference (transcription source): **AdPlug `src/adl.cpp` + `src/adl.h`** (`CadlPlayer`), LGPL-2.1. Clone into `References/adplug/`.
Cross-reference / oracle: **ScummVM `engines/kyra/sound/drivers/adlib.cpp`** (`AdLibDriver`) — the upstream, best-commented version; use it to understand intent, but transcribe from AdPlug to keep the result LGPL. C# cross-check: **NScumm.Audio** (`AdlibDriver.cs`).

> AdPlug's `adl.cpp` is itself a port of the ScummVM/Kyra driver. The two are structurally identical (same opcode tables, same channel state). Where AdPlug is terse, read ScummVM for the same routine.

## What the driver is

A per-channel **bytecode sequencer**. Each `.ADL` track is a little program; the driver runs up to ~10 channels, each with a program counter walking the track data, executing opcodes that (a) manipulate channel state and timing and (b) emit OPL register writes that load instruments and trigger notes. The net effect is a timed stream of `writeOPL(reg, val)` calls — which is exactly the trace the parity golden checks (`Testing.md`).

## Structure to transcribe (from `CadlPlayer` / `AdLibDriver`)

Port these as Swift members of `ADLPlayer`, verbatim:

- **`Channel` state struct** — the per-channel registers the driver tracks: `dataptr` (program counter into the track bytes), `duration`, `repeatCounter`, `baseOctave`, `priority`, `dataptrStack[]`, `note`, `baseNote`, `regAx`/`regBx` (the A0/B0 cached values), `tempo`, the primary/secondary effect fields, `opLevel*`/`opExtra*` (operator levels), etc. Copy every field; names per AdPlug.
- **Driver-global state** — `_curChannel`, `_soundTrigger`, `_rnd` (the driver's own PRNG — copy its constants exactly), `_tempo`, `_callbackTimer`, `_curTable`/program/instrument base pointers, the OPL register shadow, rhythm-section state.
- **`update()`** — `CadlPlayer::update()`: one call advances the driver by one tick; decrement timers, when a channel's `duration` elapses run `executePrograms` for it. Returns whether playback continues (drives the host's scheduling at `getrefresh()`).
- **Program execution** — `executePrograms` / `processChannel`: the loop that reads opcodes from `dataptr` and dispatches through the two tables.
- **Setup / reset** — `rewind(subsong)` (≈ load track, reset channels, program the OPL into the known initial state), `resetAdlibState`, `initChannel`, `noteOff`.
- **Register I/O** — `writeOPL(reg, val)` — the single choke point; route through the chip and tap `OPLLog.reg(reg, val)`. **All** OPL access goes here.
- **Effects** — the primary effect (pitch slide / vibrato) and secondary effect routines (`setupPrimaryEffect*`, `setupSecondaryEffect1`, their per-tick `update`), transcribed exactly — these are a common divergence source.

## The opcode tables — the heart of the port

`AdLibDriver` has two parallel dispatch tables:

- **`_parserOpcodeTable`** — opcodes that control the *parser/sequencer* (jumps, repeats, durations, program/subroutine flow). ~16 entries.
- **`_callbackTable`** — opcodes that produce *sound/state* effects. ~60 entries.

Together ~75 `update_*` functions, e.g. (names per AdPlug):
`update_setRepeat`, `update_checkRepeat`, `update_setupProgram`, `update_setNoteSpacing`, `update_jump`, `update_jumpToSubroutine`, `update_returnFromSubroutine`, `update_setBaseOctave`, `update_stopChannel`, `update_playRest`, `update_writeAdLib`, `update_setupNoteAndDuration`, `update_setBaseNote`, `update_setupSecondaryEffect1`, `update_stopOtherChannel`, `update_waitForEndOfProgram`, `update_setupInstrument`, `update_setupPrimaryEffectSlide`, `update_removePrimaryEffectSlide`, `update_setBaseFreq`, `update_setupPrimaryEffectVibrato`, `update_setPriority`, `update_setBeat`, `update_waitForEndOfBeat`, `update_setExtraLevel1/2/3`, `update_changeExtraLevel1/2`, `update_setExtraLevel2`, `update_setVolume`, `update_pitchBend`, `update_resetToGlobalTempo`, `update_nop`, `update_setDurationRandomness`, `update_changeChannelTempo`, `update_setTempoReset`, `update_setupRhythmSection`, `update_playRhythmSection`, `update_removeRhythmSection`, `update_setRhythmLevel`, `update_changeRhythmLevel`, `update_setSoundTrigger`, `update_setTempoReset`, … (the exact set + order is defined by the cloned AdPlug — **copy the table verbatim; index = opcode**).

Each `update_*` takes the channel and the current data pointer, mutates state, advances `dataptr`, and returns a control code (continue / stop parsing this tick). **Transcribe the bodies byte-for-byte** — the pointer arithmetic (`*dataptr++`, signed vs unsigned reads) and the return codes are the behaviour.

### Swift shape for the dispatch tables

```swift
private typealias Op = (inout DataPtr, inout Channel, UInt8) -> Int
private let parserOpcodeTable: [Op] = [ updateSetRepeat, updateCheckRepeat, /* … verbatim order … */ ]
private let callbackTable:     [Op] = [ /* … verbatim order … */ ]
```

Keep the **table order identical to AdPlug** — opcodes index into these arrays; a reorder is a silent corruption. `DataPtr` is a small struct wrapping the track `[UInt8]` + an index (the Swift stand-in for `uint8 *dataptr`); reproduce post-increment reads exactly.

## Tick rate

`getrefresh()` gives the callback frequency (Hz) the host must call `update()` at. Dune II's driver tempo is data-driven (`update_changeChannelTempo` / global tempo). Port `getrefresh()` verbatim; the host schedules `update()` at that rate (and renders chip samples between calls).

## Verification

Primary golden = **register-write trace equivalence** (`Testing.md` §Driver). Instrument AdPlug to log every `opl->write(reg, val)` with a tick index for a given `.ADL` track; our `OPLLog.reg` stream must match index-for-index. Diff by index; the first divergence localizes the buggy opcode. Do **not** jump to PCM comparison until the trace matches — a trace match + a correct chip ⇒ correct audio by construction.
