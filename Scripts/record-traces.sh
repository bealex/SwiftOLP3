#!/usr/bin/env bash
# Copyright (C) 2026 Alex Babaev
# SwiftOPL3 — https://github.com/bealex/SwiftOLP3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Record Instruments traces of the oplbench emulator with xctrace.
#
# Builds the release oplbench, then records one .trace bundle per (mode, template)
# row below into Traces/ (gitignored). Open the bundles in Instruments afterwards,
# or compare them against an earlier run to confirm the driver tick path no longer
# churns the heap (the `driver`-mode Allocations trace is the headline check).
#
# Usage:
#   Scripts/record-traces.sh [adl-file] [subsong]
#     adl-file   path to a .ADL asset   (default Resources/Music/DUNE8.ADL)
#     subsong    0-based subsong index  (default 2)
#
# The `seconds` argument per row is chosen so each instrumented run lasts a few
# wall-clock seconds (the driver-only path is ~30000x real-time, so it needs a
# large audio duration; the chip/render DSP paths run near ~45x, so a few hundred
# seconds of audio is plenty). Tweak the ROWS table to taste.
set -euo pipefail
cd "$(dirname "$0")/.."

# The SwiftPM sandbox rejects executing the compiled manifest from the default
# /tmp; keep a project-local TMPDIR (see CLAUDE.md "Sandbox note").
export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR"

ADL="${1:-Resources/Music/DUNE8.ADL}"
SUBSONG="${2:-2}"

if [ ! -f "$ADL" ]; then
    echo "Missing .ADL asset: $ADL"
    echo "Place a Dune II .ADL under Resources/Music/ (gitignored) or pass a path."
    exit 1
fi

if ! xcrun xctrace version >/dev/null 2>&1; then
    echo "xctrace not found — install Xcode (not just the Command Line Tools)."
    exit 1
fi

echo "==> Building release oplbench"
swift build -c release >/dev/null
BIN="$PWD/.build/release/oplbench"
[ -x "$BIN" ] || { echo "oplbench was not built at $BIN"; exit 1; }

OUTDIR="Traces"
mkdir -p "$OUTDIR"
STAMP="$(date +%Y%m%d-%H%M%S)"

# The default is the full matrix: every mode x both instruments, on the default
# song. Each row is "<mode> <template> <seconds>".
#   driver   — driver tick only, no chip DSP; Allocations isolates the heap path.
#   render   — full driver -> chip -> 44.1k (the real playback path).
#   chip     — pure DSP at 49716 Hz (Time Profiler shows the hot loop).
#
# IMPORTANT: `seconds` is tuned per (mode, template), not just per mode. The
# Allocations instrument hooks every malloc/free process-wide, so it runs the same
# workload ~30-40x slower than Time Profiler — a duration that gives Time Profiler
# a few wall-seconds would take minutes under Allocations and look hung. So the
# Allocations rows use far fewer ticks (the per-tick heap pattern is obvious in a
# few thousand ticks; you don't need millions). The driver path runs ~30000x
# real-time uninstrumented, so its Time-Profiler row still needs a big duration to
# accumulate samples; chip/render run near ~45x.
# NOTE: For *allocation* questions prefer `Scripts/count-allocs.sh` — it gives
# exact counts instantly. The Allocations instrument here carries heavy
# VM-Tracker/per-iteration overhead (a long run can hit the time-limit even when
# the code allocates nothing), so its rows use SHORT durations — just enough to
# see the heap timeline in the GUI.
ROWS=(
    "driver Time-Profiler 50000"
    "driver Allocations 30"
    "render Time-Profiler 180"
    "render Allocations 20"
    "chip Time-Profiler 180"
    "chip Allocations 20"
)

for row in "${ROWS[@]}"; do
    read -r mode template_slug seconds <<<"$row"
    template="${template_slug//-/ }"
    out="$OUTDIR/${STAMP}_${mode}_${template_slug}.trace"

    # render/driver need the .ADL path + subsong; chip ignores the extra args.
    if [ "$mode" = "chip" ]; then
        run_args=("$seconds" "$mode")
    else
        run_args=("$seconds" "$mode" "$ADL" "$SUBSONG")
    fi

    echo "==> Recording '$template' for mode '$mode' (${seconds}s audio) -> $out"
    rm -rf "$out"
    # --time-limit is a safety net: if a row is mis-sized and overruns, recording
    # stops *cleanly* at the bound (a usable trace) instead of forcing you to press
    # Stop, which SIGKILLs the target and can corrupt the bundle. Well-sized rows
    # finish long before it.
    xcrun xctrace record \
        --template "$template" \
        --output "$out" \
        --time-limit 120s \
        --target-stdout - \
        --launch -- "$BIN" "${run_args[@]}"
done

echo
echo "Done. Trace bundles in $OUTDIR/ (gitignored):"
ls -dt "$OUTDIR"/${STAMP}_*.trace
echo
echo "Open one with:  open '$OUTDIR/${STAMP}_driver_Allocations.trace'"
