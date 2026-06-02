#!/usr/bin/env bash
# Copyright (C) 2026 Alex Babaev
# SwiftOPL3 — https://github.com/bealex/SwiftOLP3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Count heap allocations exactly, without Instruments.
#
# Builds the release oplbench, compiles a tiny interpose dylib that installs a
# libmalloc `malloc_logger` hook (the same hook MallocStackLogging uses) to count
# every malloc/free, then runs each oplbench mode at a SHORT and a LONG duration.
#
# The point: if the total allocation count is ~identical at both durations, the
# per-frame/per-tick path allocates nothing — all allocations are one-time
# startup/load. A count that grows with duration is the real-time-audio red flag.
# This is more decisive than the Allocations instrument here (exact integer
# counts, no GUI, no VM-Tracker overhead, finishes instantly).
#
# Usage:
#   Scripts/count-allocs.sh [adl-file] [subsong]
set -euo pipefail
cd "$(dirname "$0")/.."

export TMPDIR="$PWD/.build/tmp"
mkdir -p "$TMPDIR"

ADL="${1:-Resources/Music/DUNE8.ADL}"
SUBSONG="${2:-2}"

echo "==> Building release oplbench"
swift build -c release >/dev/null
BIN="$PWD/.build/release/oplbench"

echo "==> Compiling malloc-counter interpose dylib"
SCRATCH="$PWD/.build/scratch"
mkdir -p "$SCRATCH"
cat > "$SCRATCH/mallocount.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdatomic.h>
// libmalloc calls this hook (when set) for every alloc/free. type bit 1 (value 2)
// = MALLOC_LOG_TYPE_ALLOCATE, bit 2 (value 4) = MALLOC_LOG_TYPE_DEALLOCATE.
typedef void (malloc_logger_t)(uint32_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uint32_t);
extern malloc_logger_t *malloc_logger;
static _Atomic long allocs = 0, frees = 0;
static void lg(uint32_t type,uintptr_t a1,uintptr_t a2,uintptr_t a3,uintptr_t r,uint32_t n){
    if (type & 2) atomic_fetch_add(&allocs,1);
    if (type & 4) atomic_fetch_add(&frees,1);
}
__attribute__((constructor)) static void on(void){ malloc_logger = lg; }
__attribute__((destructor))  static void off(void){
    fprintf(stderr,"  allocs=%ld frees=%ld\n", atomic_load(&allocs), atomic_load(&frees));
}
EOF
CC="$(xcrun -f clang)"
SDK="$(xcrun --show-sdk-path)"
"$CC" -isysroot "$SDK" -dynamiclib -O2 "$SCRATCH/mallocount.c" -o "$SCRATCH/mallocount.dylib"
LIB="$SCRATCH/mallocount.dylib"

run() {  # mode short long [adl subsong]
    local mode="$1" short="$2" long="$3"
    local extra=()
    [ "$mode" != "chip" ] && extra=("$ADL" "$SUBSONG")
    echo "--- mode=$mode ---"
    printf "  short (%ss): " "$short"
    DYLD_INSERT_LIBRARIES="$LIB" "$BIN" "$short" "$mode" ${extra[@]+"${extra[@]}"} >/dev/null
    printf "  long  (%ss): " "$long"
    DYLD_INSERT_LIBRARIES="$LIB" "$BIN" "$long" "$mode" ${extra[@]+"${extra[@]}"} >/dev/null
}

echo
echo "Allocation counts (a flat count short-vs-long ⇒ zero per-frame allocation):"
run driver 3 2000
run render 1 60
run chip   1 60
echo
echo "Done."
