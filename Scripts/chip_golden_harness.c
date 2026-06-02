//  Copyright (C) 2026 Alex Babaev
//  SwiftOPL3 — https://github.com/bealex/SwiftOLP3
//  SPDX-License-Identifier: LGPL-2.1-or-later
//

/* chip_golden_harness.c — generate bit-exact PCM goldens from Nuked-OPL3.
 *
 * Compiles the cloned reference (References/Nuked-OPL3/opl3.c) and replays one
 * of several fixed register scripts, dumping raw interleaved little-endian int16
 * stereo PCM to argv[1]. argv[2] selects the script (default "sine"). The Swift
 * OPL3GoldenTests drives the SwiftOPL3 port with the identical script and asserts
 * sample-for-sample equality — the integer DSP makes a correct port bit-exact.
 * See Documentation/Architecture/Testing.md §Chip golden.
 *
 * Build (see Scripts/gen-chip-goldens.sh):
 *   cc -O2 -w -I References/Nuked-OPL3 Scripts/chip_golden_harness.c -o harness
 *   harness out.pcm <sine|waveforms|fourop|rhythm|resample44k>
 *
 * Keep every script in lock-step with OPL3GoldenTests.swift.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "opl3.c"

#define NUM_SAMPLES 4096

static void w(opl3_chip *c, uint16_t reg, uint8_t v) { OPL3_WriteReg(c, reg, v); }

static void gen_native(opl3_chip *c, FILE *f, int n) {
    int16_t buf[2];
    for (int i = 0; i < n; i++) { OPL3_Generate(c, buf); fwrite(buf, sizeof(int16_t), 2, f); }
}

/* --- scripts (mirrored in Swift) --- */

static void setup_sine(opl3_chip *c) {
    w(c, 0x20, 0x21); w(c, 0x23, 0x21);
    w(c, 0x40, 0x10); w(c, 0x43, 0x00);
    w(c, 0x60, 0xF0); w(c, 0x63, 0xF0);
    w(c, 0x80, 0x00); w(c, 0x83, 0x00);
    w(c, 0xC0, 0x00);
    w(c, 0xA0, 0x98);
    w(c, 0xB0, 0x31);
}

/* OPL3 4-op patch on channel 0 (paired with channel 3). */
static void setup_fourop(opl3_chip *c) {
    w(c, 0x105, 0x01);          /* newm */
    w(c, 0x104, 0x01);          /* 4-op enable for pair 0 */
    /* operator register offsets for the four operators: 0x00,0x03,0x08,0x0B */
    uint8_t ofs[4] = { 0x00, 0x03, 0x08, 0x0B };
    for (int i = 0; i < 4; i++) {
        w(c, 0x20 + ofs[i], 0x01);
        w(c, 0x40 + ofs[i], (i == 3) ? 0x00 : 0x10);
        w(c, 0x60 + ofs[i], 0xF0);
        w(c, 0x80 + ofs[i], 0x00);
        w(c, 0xE0 + ofs[i], (uint8_t)i & 0x07);
    }
    w(c, 0xC0, 0x01);           /* ch0 con */
    w(c, 0xC3, 0x00);           /* ch3 con */
    w(c, 0xA0, 0x98);
    w(c, 0xB0, 0x31);           /* key-on ch0 */
}

/* Rhythm mode: all five percussion voices keyed. */
static void setup_rhythm(opl3_chip *c) {
    /* BD ch6 ops (0x10,0x13), SD/HH ch7 (0x14,0x11), TT/CY ch8 (0x12,0x15) */
    uint8_t ofs[6] = { 0x10, 0x13, 0x14, 0x11, 0x12, 0x15 };
    for (int i = 0; i < 6; i++) {
        w(c, 0x20 + ofs[i], 0x01);
        w(c, 0x40 + ofs[i], 0x00);
        w(c, 0x60 + ofs[i], 0xF0);
        w(c, 0x80 + ofs[i], 0x00);
    }
    w(c, 0xA6, 0x40); w(c, 0xB6, 0x11);
    w(c, 0xA7, 0x40); w(c, 0xB7, 0x11);
    w(c, 0xA8, 0x40); w(c, 0xB8, 0x11);
    w(c, 0xBD, 0x20 | 0x1F);    /* rhythm enable + BD/SD/TT/CY/HH */
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <out.pcm> [script]\n", argv[0]); return 2; }
    const char *which = (argc >= 3) ? argv[2] : "sine";

    FILE *f = fopen(argv[1], "wb");
    if (!f) { perror("fopen"); return 1; }

    opl3_chip chip;

    if (!strcmp(which, "resample44k")) {
        OPL3_Reset(&chip, 44100);
        setup_sine(&chip);
        int16_t buf[2];
        for (int i = 0; i < NUM_SAMPLES; i++) { OPL3_GenerateResampled(&chip, buf); fwrite(buf, 2, 2, f); }
    } else if (!strcmp(which, "fourop")) {
        OPL3_Reset(&chip, 49716);
        setup_fourop(&chip);
        gen_native(&chip, f, NUM_SAMPLES);
    } else if (!strcmp(which, "rhythm")) {
        OPL3_Reset(&chip, 49716);
        setup_rhythm(&chip);
        gen_native(&chip, f, NUM_SAMPLES);
    } else if (!strcmp(which, "waveforms")) {
        OPL3_Reset(&chip, 49716);
        w(&chip, 0x105, 0x01);  /* newm so waveforms 4..7 are usable */
        setup_sine(&chip);
        int16_t buf[2];
        for (int wf = 0; wf < 8; wf++) {
            w(&chip, 0xE0, (uint8_t)wf);
            w(&chip, 0xE3, (uint8_t)wf);
            for (int i = 0; i < NUM_SAMPLES / 8; i++) { OPL3_Generate(&chip, buf); fwrite(buf, 2, 2, f); }
        }
    } else {  /* sine */
        OPL3_Reset(&chip, 49716);
        setup_sine(&chip);
        gen_native(&chip, f, NUM_SAMPLES);
    }

    fclose(f);
    return 0;
}
