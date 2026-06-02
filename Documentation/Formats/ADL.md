# ADL format (Westwood, version 2)

The music file format for *Dune II* (and *Legend of Kyrandia 1*, *Eye of the Beholder II*). Self-contained: it carries both the **sequencer programs** (per-track bytecode) and the **instrument definitions** (FM operator register values) in one file. There is no external timbre bank.

References (read for the exact byte layout — **do not** trust this summary over them):
- AdPlug `src/adl.cpp` — `CadlPlayer::load()` (authoritative parse; this is what we transcribe).
- shikadi ModdingWiki — "ADL Format".
- VGMPF — "ADL (Westwood)".

## Versions

Westwood shipped three driver/format versions. **Dune II uses version 2** (shared with Kyra1 and EOB2). AdPlug auto-detects the version in `load()`; we only need v2, but transcribe the detection branch as-is (it's cheap and keeps the port honest).

## Version-2 layout (summary — confirm against `adl.cpp::load`)

The v2 file is, in order:
1. A **track/program offset table** — an array of little-endian `UInt16` offsets indexing into the data block, one per logical track/program. The research note records the v2 track-pointer array as **300 bytes** (i.e. 150 × `UInt16`).
2. An **instrument offset table** — `UInt16` offsets to each instrument's operator block.
3. The **data block** — the per-program bytecode (walked by the driver's `dataptr`) and the instrument operator bytes (loaded by `update_setupInstrument`).

> Offsets are relative to a base AdPlug computes in `load()`; reproduce that base arithmetic exactly. The "track number" the game selects indexes the track table.

## What the parser must expose

For the driver (`WestwoodADL`), parsing only needs to resolve:
- `programData(track:) -> startIndex into the byte buffer` — where a track's bytecode begins.
- `instrumentData(index:) -> startIndex` — where an instrument's operator bytes begin.

So the "parser" can be as thin as: keep the whole file as `[UInt8]`, decode the two offset tables, and hand the driver indices. (Matches AdPlug, which keeps the file resident and indexes into it — `dataptr` is a pointer *into the loaded file*.) A heavier typed model is unnecessary and risks diverging from the pointer arithmetic.

## Song-index ↔ track mapping (verify)

Dune II selects music by a single logical song index (OpenDUNE `g_table_musics`, `(file, song)`). The original engine uses that same index across all device drivers, so **the ADL track number should equal the XMIDI sequence index 1:1**. ⚠️ Confirm against AdPlug's `getsubsongs()` / track-table size before trusting it.

## Test

A `Formats`-style test: load `DUNE0.ADL`, decode the offset tables, and assert the **subsong count** and a few **track/instrument offsets** match AdPlug's `load()` output (dump them once from the instrumented AdPlug harness in `Scripts/gen-adl-traces.sh`). Short-circuit if the `.ADL` asset is absent.
