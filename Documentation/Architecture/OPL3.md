# OPL3 chip core — porting Nuked-OPL3

Reference: **Nuked-OPL3** `opl3.c` + `opl3.h` (Nuke.YKT, LGPL-2.1). Clone into `References/Nuked-OPL3/`. This doc is the map; the C is the law. Cite `opl3.c:<line>` in every ported symbol.

> Nuked-OPL3 is cycle-/bit-accurate and **integer-only**. There is no floating point in the DSP. A correct Swift port is therefore **sample-for-sample identical**, which is exactly why the golden is byte-equality (`Testing.md`).

## Native rate & resampling

- Chip native sample rate: **49 716 Hz** (`OPL_NATIVE_FREQ` ≈ 14318181/288). `OPL3_Generate` produces one native-rate stereo sample per call.
- `OPL3_Reset(chip, samplerate)` computes `rateratio = (samplerate << RSM_FRAC) / 49716` (`RSM_FRAC = 10`). `OPL3_GenerateResampled` advances `samplecnt` by `rateratio` and linearly interpolates between `oldsamples` and `samples`. Port the fixed-point resampler verbatim.
- Output is 4-channel internally (OPL3 has 4 output channels); the public stereo pair sums the relevant channels exactly as `OPL3_Generate` writes `buf[0]/buf[1]`. (Newer Nuked exposes `OPL3_Generate4Ch`; port the version you cloned — pin the commit in History.)

## Types (opl3.h) — exact fields

Port these as Swift types with the **exact** fields and integer widths. Reference types (`final class`) are appropriate (the C uses pointers and shared mutable state: `slot.channel`, `channel.chip`, `slot.mod`). Keep cross-references as `unowned`/`weak` or index-based — decide once and document; index-based (store the chip, index slots/channels) avoids retain cycles and matches the C array layout most closely.

- `opl3_slot` — per-operator state: `out, fbmod, prout, eg_rout, eg_out, eg_inc, eg_gen, eg_rate, eg_ksl, reg_vib, reg_type, reg_ksr, reg_mult, reg_ksl, reg_tl, reg_ar, reg_dr, reg_sl, reg_rr, reg_wf, key, pg_reset, pg_phase, pg_phase_out, slot_num`, plus pointers `channel, mod, trem`.
- `opl3_channel` — `slots[2], pair, out[4], chtype, f_num, block, fb, con, alg, ksv, cha/chb/chc/chd, ch_num`.
- `opl3_chip` — the arrays `channel[18]`, `slot[36]`; the clocks `timer, eg_timer, eg_timerrem, eg_state, eg_add`; mode flags `newm, nts, rhy`; LFO `vibpos, vibshift, tremolo, tremolopos, tremoloshift`; `noise` (LFSR); `zeromod`; `mixbuff[4]`; rhythm bits; the resampler fields `samplecnt, oldsamples[4], samples[4], rateratio`; and the write buffer (`writebuf[OPL_WRITEBUF_SIZE]`, `writebuf_samplecnt`, `writebuf_cur`, `writebuf_last`, `writebuf_lasttime`).

Match `OPL_WRITEBUF_SIZE` (1024) and `OPL_WRITEBUF_DELAY` (2) exactly.

## Tables (opl3.c, top of file) — port first

Copy the literal arrays. Unit-test each (length + several spot values) against the C so a typo surfaces immediately.

- `logsinrom[256]` — log-sine quarter wave.
- `exprom[256]` — exponential.
- `kslrom[16]`, `kslshift[4]` — key-scale level.
- `mt[16]` — frequency multipliers (note: stored ×2; `mt[0]` represents 0.5).
- envelope rate / increment step tables (`eg_incstep`, the `eg_incdesc`/`*4`-style tables — copy whatever the cloned version names them).
- `ch_slot[18]` (channel→slot base mapping) and any `ad_slot`/rhythm slot maps.
- The 8 waveform helpers operate on `logsinrom`/`exprom`; port `OPL3_EnvelopeCalcExp`-style helpers and the `envelope_sin[8]` function table.

## Function port order (opl3.c)

Follow dependencies bottom-up; each item is a 1–3-function block.

1. **Envelope helpers** — `OPL3_EnvelopeUpdateKSL`, the EG rate calc, `OPL3_EnvelopeCalc` (the `eg_gen` state machine: attack/decay/sustain/release; `eg_rout`, `eg_out`, key-scale, tremolo, KSL).
2. **Phase generator** — `OPL3_PhaseGenerate` (uses `f_num`, `block`, `mt`, vibrato; updates `pg_phase`, `pg_phase_out`).
3. **Waveforms + slot** — the `envelope_sin[8]` waveform functions; `OPL3_SlotWrite20` (am/vib/egt/ksr/mult), `40` (ksl/tl), `60` (ar/dr), `80` (sl/rr), `E0` (waveform); `OPL3_SlotGenerate`, `OPL3_SlotGeneratePhase`/`OPL3_SlotCalcFB` (feedback).
4. **Channel** — `OPL3_ChannelSetupAlg`, `OPL3_ChannelUpdateAlg`, `OPL3_ChannelWriteA0` (f_num low / block), `OPL3_ChannelWriteB0` (f_num high / key-on / block), `OPL3_ChannelWriteC0` (fb / con / stereo / OPL3 4-op), `OPL3_ChannelKeyOn/Off`, `OPL3_ChannelUpdateRhythm`, the 4-op pairing (`channel.pair`).
5. **Noise / LFO** — the LFSR `noise` update and vibrato/tremolo position advance (inside `OPL3_Generate`).
6. **Top-level generate** — `OPL3_Generate(chip, buf)`: advance EG timer, LFO, noise; iterate 36 slots (`OPL3_SlotCalcFB` + `OPL3_EnvelopeCalc` + `OPL3_PhaseGenerate` + `OPL3_SlotGenerate`); accumulate channel outputs into `mixbuff`; handle rhythm; write `buf`. Then the write-buffer drain (`OPL3_WriteRegBuffered` timing).
7. **Reset / write / resample / stream** — `OPL3_Reset`, `OPL3_WriteReg` (the 0x100 high-bank, `newm`, NTS, rhythm, per-slot/channel dispatch), `OPL3_WriteRegBuffered`, `OPL3_GenerateResampled`, `OPL3_GenerateStream`.

## Gotchas (the verbatim-transcription traps)

- **Integer wraparound is load-bearing.** Phase accumulation, LFSR, and signed sums rely on overflow. Use `&+ &* &<<` and `Int16(truncatingIfNeeded:)`/`UInt16(truncatingIfNeeded:)`. Never let Swift trap on overflow, and never widen "to be safe".
- **Signed vs unsigned shifts.** C `>>` on a signed type is arithmetic; on unsigned it's logical. Match the operand's signedness in Swift (`Int16 >> n` vs `UInt16 >> n`).
- **Sign extension.** Where C casts a small signed field up (e.g. `(Bit16s)(x << k) >> k`), reproduce the exact mask/shift, not the intent.
- **Table indexing** must use the same masks (`& 0xff`, `& 0x1ff`, `& 0x3ff`) — these define the wraparound, not just bounds.
- **`zeromod`** is the shared "no modulation" source pointer; modulator routing (`slot.mod`) must point at it for carriers without a modulator, exactly as `OPL3_ChannelSetupAlg` wires it.
- **Pin the upstream commit** in History — Nuked-OPL3's struct/field names and the 2-ch vs 4-ch `Generate` signature have changed across versions. Port one pinned revision.

## Public wrapper

Keep the `internal` transcription pure (free of `OPLLog` in hot loops if it ever risks reordering — though gated calls are no-ops). Expose only the `OPL3Chip` surface in `Overview.md`. `write(_:_:)` taps `OPLLog.reg(reg, value)` so chip-level traces are available when debugging the driver.
