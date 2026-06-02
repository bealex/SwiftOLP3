# SwiftOPL3

A **pure-Swift, LGPL-2.1** emulation of the Yamaha **YMF262 (OPL3)** FM-synthesis
chip and the **Westwood ADL** music driver — faithful enough to play *Dune II*
(and other Westwood / Kyrandia / Eye of the Beholder) `.ADL` music exactly as the
DOS AdLib hardware did.

It is a strict **function-by-function transcription** of two reference
implementations (their source is *not* bundled here — see [References][1]).
The transcription was produced with [Claude Code][2],
Anthropic's agentic coding tool.

| Component                           | Transcribed from                                                                       | Upstream license |
| ----------------------------------- | -------------------------------------------------------------------------------------- | ---------------- |
| OPL3 chip core — `SwiftOPL3`        | [Nuked-OPL3][3] by Nuke.YKT (`opl3.c`/`opl3.h`)                                        | LGPL-2.1         |
| Westwood ADL driver — `WestwoodADL` | [AdPlug][4] `src/adl.cpp` (`CadlPlayer`), a port of the [ScummVM/Kyra][5] AdLib driver | LGPL-2.1         |

The transcription rule is absolute: **change nothing** — same branches, same
fixed-point arithmetic, same table values, same order of operations. Behaviour
is *verified against the originals, not re-derived* (see [Verification][6]).

## Status — working & verified ✅

- **Chip:** bit-exact `Int16` PCM vs Nuked-OPL3 across 5 register scripts
  (sine, all 8 waveforms, a 4-op OPL3 patch, rhythm mode, and the 49716→44100
  resampler) — sample-for-sample identical.
- **Driver:** register-write **trace equivalence** vs AdPlug — identical timed
  `(reg, value)` stream — confirmed on a synthetic track *and* on a real
  `DUNE8.ADL` melody (1178 writes, index-for-index) through the full public API.
- **End-to-end:** the `adlrender` tool renders real Dune II `.ADL` tracks to WAV.
- 68 tests green; zero warnings (default and `-DOPL_TRACE` builds).

## Use

```swift
import SwiftOPL3
import WestwoodADL

let chip = OPL3Chip(sampleRate: 44_100)
let player = ADLPlayer(chip: chip)
player.load(adlFileData)            // parse a .ADL
player.rewind(subsong: 2)

// Host loop: tick the driver at player.refreshRate (72 Hz), render chip samples
// between ticks.
player.update()
let (left, right) = chip.generateResampled()
```

The OPL3 chip is usable standalone (drive it with raw register writes via
`chip.write(reg, value)` and pull PCM with `generate()` / `generateResampled()`).

## Build & test

```sh
swift build
swift test
```

Render a track to a WAV (you supply the `.ADL`):

```sh
swift build
.build/debug/adlrender path/to/{file}.adl 2 45 out.wav
```

## Verification

Two independent goldens, because the two halves fail in different ways:

- **Chip — bit-exact PCM.** `Scripts/gen-chip-goldens.sh` compiles Nuked-OPL3
  with a tiny harness, replays register scripts, and dumps PCM to
  `Tests/SwiftOPL3Tests/Fixtures/*.pcm`. The Swift port replays the same scripts
  and asserts `Int16` equality.
- **Driver — trace equivalence.** `Scripts/gen-adl-traces.sh` drives AdPlug's
  real `AdLibDriver` / `CadlPlayer` through a recording OPL and dumps every
  `writeOPL(reg, val)`. The Swift `ADLPlayer` must emit the identical stream,
  index-for-index.

Fixtures are committed, so the suite is green on a fresh checkout. To regenerate
them you need the reference sources:

```sh
Scripts/fetch-references.sh     # clones Nuked-OPL3 + AdPlug into References/ (gitignored)
Scripts/gen-chip-goldens.sh
Scripts/gen-adl-traces.sh       # real-track traces need your own .ADL in Resources/Music/
```

## Layout

```
Sources/SwiftOPL3/      OPL3 chip core (transcription of Nuked-OPL3)
Sources/WestwoodADL/    Westwood ADL driver (transcription of AdPlug CadlPlayer)
Sources/adlrender/      example: .ADL → WAV renderer
Tests/                  golden PCM + trace-equivalence + unit tests
Documentation/          Plan, Architecture (Overview/OPL3/WestwoodADL/Logging/Testing), Formats/ADL
Scripts/                reference fetch + golden-fixture generation (build-time tooling)
```

`Documentation/` holds the design; `CurrentState.md` is the operational resume point.

## References

The original implementations — read these for the authoritative behaviour;
their code is referenced here, never copied in:

- **Nuked-OPL3** — https://github.com/nukeykt/Nuked-OPL3 (Nuke.YKT, LGPL-2.1)
- **AdPlug** — https://github.com/adplug/adplug (`src/adl.cpp`, LGPL-2.1)
- **ScummVM / Kyra AdLib driver** — https://github.com/scummvm/scummvm
  (`engines/kyra/sound/drivers/adlib.cpp`) — cross-reference oracle

## License

**LGPL-2.1-or-later.** SwiftOPL3 is a derivative work of Nuked-OPL3 (LGPL-2.1)
and the AdPlug/ScummVM AdLib driver (LGPL-2.1); LGPL-2.1 is therefore the
required and intended license. Full text in [`LICENSE`][7]; attribution in
[`NOTICE`][8]. Per-file headers cite the upstream `file:line` they were
transcribed from.

> Dune II `.ADL` music files are copyrighted game assets and are **not** included
> in this repository. Bring your own to render or trace real tracks.

[1]:	#references
[2]:	https://claude.com/claude-code
[3]:	https://github.com/nukeykt/Nuked-OPL3
[4]:	https://github.com/adplug/adplug
[5]:	https://github.com/scummvm/scummvm
[6]:	#verification
[7]:	LICENSE
[8]:	NOTICE