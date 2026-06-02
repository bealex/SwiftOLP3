#!/usr/bin/env bash
# Copyright (C) 2026 Alex Babaev
# SwiftOPL3 — https://github.com/bealex/SwiftOLP3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Generate bit-exact chip golden PCM from Nuked-OPL3 (the oracle).
#
# Compiles References/Nuked-OPL3/opl3.c together with Scripts/chip_golden_harness.c
# (which replays a fixed register script and dumps interleaved LE Int16 stereo PCM)
# into Tests/SwiftOPL3Tests/Fixtures/. The Swift OPL3GoldenTests drives OPL3Chip
# with the identical script and asserts sample-for-sample equality — the integer
# DSP makes a correct port bit-identical. See Documentation/Architecture/Testing.md.
#
# Future scripts: parameterise chip_golden_harness.c (or add siblings) per fixture
# — each waveform, a 4-op patch, rhythm mode, the 49716→44100 resampler, etc.
set -euo pipefail
cd "$(dirname "$0")/.."

REF=References/Nuked-OPL3
[ -d "$REF" ] || { echo "Missing $REF — run Scripts/fetch-references.sh first."; exit 1; }

OUT=Tests/SwiftOPL3Tests/Fixtures
mkdir -p "$OUT" .build/tmp

# Prefer a plain compiler; fall back to the Xcode toolchain (provides the SDK sysroot).
if command -v cc >/dev/null 2>&1; then
    CC=cc
else
    CC="xcrun clang"
fi

echo "→ building harness with: $CC"
$CC -O2 -w -I "$REF" Scripts/chip_golden_harness.c -o .build/tmp/chip_golden_harness

# fixture-name → script-id
gen() {
    echo "→ generating $OUT/$1.pcm ($2)"
    .build/tmp/chip_golden_harness "$OUT/$1.pcm" "$2"
}

gen sine_note_49716   sine
gen waveforms_49716   waveforms
gen fourop_49716      fourop
gen rhythm_49716      rhythm
gen resample_44100    resample44k

echo "Done."
ls -l "$OUT"/*.pcm | awk '{print "  " $9 " (" $5 " bytes)"}'
