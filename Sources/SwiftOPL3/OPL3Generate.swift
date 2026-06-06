//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

//  OPL3Generate.swift
//  SwiftOPL3 — the per-sample core, resampler and timed write buffer.
//
//  Faithful transcription of `OPL3_Generate4Ch` (opl3.c:1111),
//  `OPL3_Generate4ChResampled` (opl3.c:1263), `OPL3_WriteRegBuffered`
//  (opl3.c:1472) and the stream helpers. Nuked-OPL3 v1.8, commit cfedb09e.
//
//  We build with the default `OPL_ENABLE_STEREOEXT == 0`, which makes
//  `OPL_QUIRK_CHANNELSAMPLEDELAY == 1`: the slot sweep is split into the
//  0..14 / 15..17 / 18..32 / 33..35 groups, and the right side (buf[1], buf[3])
//  is emitted from the *previous* sample's mixbuff — the documented "FM channels
//  output one sample later on the left" quirk. The split and the inter-group
//  mix accumulation are transcribed exactly.
//
//  Integer-width traps: `accm` sums four `int16_t` and truncates back to
//  `int16_t`; `accm & cha` masks in (promoted) `int` then narrows; the EG timer
//  is a 36-bit counter wrapping at `0xfffffffff`.

extension OPL3Chip {
    // opl3.c:1111 OPL3_Generate4Ch
    #if OPL_BLOCKSIMD
        // Under the experimental block-SIMD float fork the per-sample integer core is
        // replaced by the block engine (OPL3BlockSimd.swift); the resampler / write
        // buffer below stay shared and call this exactly as before.
        func generate4Ch() -> (Int16, Int16, Int16, Int16) {
            blockEngine.generateNative()
        }
    #else
        func generate4Ch() -> (Int16, Int16, Int16, Int16) {
            let buf1 = clipSample(mixbuff.1)
            let buf3 = clipSample(mixbuff.3)

            for ii in 0 ..< 15 {
                processSlot(ii)
            }

            var mix0: Int32 = 0
            var mix1: Int32 = 0
            for ii in 0 ..< 18 {
                let out = channel[ii].out
                let accm = Int16(
                    truncatingIfNeeded:
                        Int32(sample(at: out.0)) &+ Int32(sample(at: out.1))
                        &+ Int32(sample(at: out.2)) &+ Int32(sample(at: out.3))
                )
                mix0 &+= Int32(Int16(truncatingIfNeeded: Int32(accm) & Int32(channel[ii].cha)))
                mix1 &+= Int32(Int16(truncatingIfNeeded: Int32(accm) & Int32(channel[ii].chc)))
            }

            mixbuff.0 = mix0
            mixbuff.2 = mix1

            for ii in 15 ..< 18 {
                processSlot(ii)
            }

            let buf0 = clipSample(mixbuff.0)
            let buf2 = clipSample(mixbuff.2)

            for ii in 18 ..< 33 {
                processSlot(ii)
            }

            mix0 = 0
            mix1 = 0
            for ii in 0 ..< 18 {
                let out = channel[ii].out
                let accm = Int16(
                    truncatingIfNeeded:
                        Int32(sample(at: out.0)) &+ Int32(sample(at: out.1))
                        &+ Int32(sample(at: out.2)) &+ Int32(sample(at: out.3))
                )
                mix0 &+= Int32(Int16(truncatingIfNeeded: Int32(accm) & Int32(channel[ii].chb)))
                mix1 &+= Int32(Int16(truncatingIfNeeded: Int32(accm) & Int32(channel[ii].chd)))
            }

            mixbuff.1 = mix0
            mixbuff.3 = mix1

            for ii in 33 ..< 36 {
                processSlot(ii)
            }

            if (timer & 0x3f) == 0x3f {
                tremolopos = (tremolopos &+ 1) % 210
            }
            if tremolopos < 105 {
                tremolo = tremolopos >> tremoloshift
            } else {
                tremolo = (210 - tremolopos) >> tremoloshift
            }

            if (timer & 0x3ff) == 0x3ff {
                vibpos = (vibpos &+ 1) & 7
            }

            timer = timer &+ 1

            if egState != 0 {
                var shift: UInt8 = 0
                while shift < 13 && ((egTimer >> UInt64(shift)) & 1) == 0 {
                    shift += 1
                }

                if shift > 12 {
                    egAdd = 0
                } else {
                    egAdd = shift &+ 1
                }

                egTimerLo = UInt8(egTimer & 0x3)
            }

            if egTimerrem != 0 || egState != 0 {
                if egTimer == 0xf_ffff_ffff {
                    egTimer = 0
                    egTimerrem = 1
                } else {
                    egTimer = egTimer &+ 1
                    egTimerrem = 0
                }
            }

            egState ^= 1

            while true {
                let cur = Int(writebufCur)
                if !(writebuf[cur].time <= writebufSamplecnt) {
                    break
                }
                if writebuf[cur].reg & 0x200 == 0 {
                    break
                }

                writebuf[cur].reg &= 0x1ff
                writeReg(writebuf[cur].reg, writebuf[cur].data)
                writebufCur = (writebufCur &+ 1) % UInt32(OPL3Const.writeBufSize)
            }

            writebufSamplecnt = writebufSamplecnt &+ 1
            return (buf0, buf1, buf2, buf3)
        }
    #endif  // OPL_BLOCKSIMD (generate4Ch delegate)

    // opl3.c:1263 OPL3_Generate4ChResampled
    func generate4ChResampled() -> (Int16, Int16, Int16, Int16) {
        while samplecnt >= rateratio {
            oldsamples = samples
            samples = generate4Ch()
            samplecnt -= rateratio
        }

        let b0 = resample(oldsamples.0, samples.0)
        let b1 = resample(oldsamples.1, samples.1)
        let b2 = resample(oldsamples.2, samples.2)
        let b3 = resample(oldsamples.3, samples.3)
        samplecnt = samplecnt &+ (Int32(1) << Int32(OPL3Const.rsmFrac))
        return (b0, b1, b2, b3)
    }

    private func resample(_ old: Int16, _ new: Int16) -> Int16 {
        let blended = Int32(old) * (rateratio - samplecnt) + Int32(new) * samplecnt
        return Int16(truncatingIfNeeded: blended / rateratio)
    }

    // opl3.c:1472 OPL3_WriteRegBuffered
    func writeRegBuffered(_ reg: UInt16, _ v: UInt8) {
        let last = Int(writebufLast)

        if writebuf[last].reg & 0x200 != 0 {
            writeReg(writebuf[last].reg & 0x1ff, writebuf[last].data)
            writebufCur = (UInt32(last) &+ 1) % UInt32(OPL3Const.writeBufSize)
            writebufSamplecnt = writebuf[last].time
        }

        writebuf[last].reg = reg | 0x200
        writebuf[last].data = v
        var time1 = writebufLasttime &+ OPL3Const.writeBufDelay
        let time2 = writebufSamplecnt
        if time1 < time2 {
            time1 = time2
        }

        writebuf[last].time = time1
        writebufLasttime = time1
        writebufLast = (UInt32(last) &+ 1) % UInt32(OPL3Const.writeBufSize)
    }
}
