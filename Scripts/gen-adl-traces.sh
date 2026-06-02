#!/usr/bin/env bash
# Copyright (C) 2026 Alex Babaev
# SwiftOPL3 — https://github.com/bealex/SwiftOLP3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Generate the driver register-write trace golden from AdPlug (the oracle).
#
# Builds a harness that #includes References/adplug/src/adl.cpp and drives its
# `AdLibDriver` directly through a recording `Copl`, over a synthetic .ADL sound
# block the harness builds itself. It emits:
#   Tests/WestwoodADLTests/Fixtures/synth_track.bin    — the soundData bytes
#   Tests/WestwoodADLTests/Fixtures/synth_track.trace  — "RR VV" hex per writeOPL
# The Swift ADLTraceTests drives the ported AdLibDriver with the identical call
# sequence over the same soundData and asserts the trace matches index-for-index
# (the primary driver parity bar). See Documentation/Architecture/Testing.md §Driver.
#
# The heavy AdPlug headers (player/fprovide/binio/database) are stubbed so adl.cpp
# compiles standalone; we never call CadlPlayer::load, only AdLibDriver.
#
# A real DUNE*.ADL trace is produced below via the full CadlPlayer load path,
# if you supply your own .ADL under Resources/Music/ (set ADL_SONG to point at it).
set -euo pipefail
cd "$(dirname "$0")/.."

REF=References/adplug/src
[ -f "$REF/adl.cpp" ] || { echo "Missing $REF/adl.cpp — run Scripts/fetch-references.sh first."; exit 1; }

OUT=Tests/WestwoodADLTests/Fixtures
BUILD=.build/adl_harness
mkdir -p "$OUT" "$BUILD"

# Assemble a standalone build dir: real adl.cpp/adl.h/opl.h + stub headers.
cp "$REF/adl.cpp" "$REF/adl.h" "$REF/opl.h" "$BUILD/"

cat > "$BUILD/binio.h" <<'EOF'
#ifndef BINIO_STUB_H
#define BINIO_STUB_H
class binistream { public: unsigned long readString(char *, unsigned long n) { return n; } };
#endif
EOF

cat > "$BUILD/database.h" <<'EOF'
#ifndef H_ADPLUG_DATABASE
#define H_ADPLUG_DATABASE
class CAdPlugDatabase {};
#endif
EOF

cat > "$BUILD/fprovide.h" <<'EOF'
#ifndef H_ADPLUG_FILEPROVIDER
#define H_ADPLUG_FILEPROVIDER
#include <string>
#include "binio.h"
class CFileProvider {
public:
  virtual ~CFileProvider() {}
  virtual binistream *open(std::string) const { return 0; }
  virtual void close(binistream *) const {}
  static bool extension(const std::string &, const std::string &) { return true; }
  static unsigned long filesize(binistream *) { return 0; }
};
class CProvider_Filesystem : public CFileProvider {};
#endif
EOF

cat > "$BUILD/debug.h" <<'EOF'
#ifndef ADL_DEBUG_STUB_H
#define ADL_DEBUG_STUB_H
#endif
EOF

cat > "$BUILD/player.h" <<'EOF'
#ifndef H_ADPLUG_PLAYER
#define H_ADPLUG_PLAYER
#include <string>
#include "opl.h"
#include "fprovide.h"
#include "database.h"
class CPlayer {
public:
  CPlayer(Copl *newopl) : opl(newopl), db(0) {}
  virtual ~CPlayer() {}
protected:
  Copl *opl;
  CAdPlugDatabase *db;
};
#endif
EOF

cat > "$BUILD/harness.cpp" <<'EOF'
#include <cstdio>
#include <cstring>
#include <vector>
#include "adl.cpp"

struct Rec { int reg, val; };
static std::vector<Rec> g_trace;

class RecordingOpl : public Copl {
public:
  void write(int reg, int val) { g_trace.push_back(Rec{reg & 0xFF, val & 0xFF}); }
  void init() {}
};

// Build the same synthetic soundData the Swift test uses (single source: written
// out to the .bin fixture below). Program 2 → bytecode; instrument 0 → operators.
static void buildSoundData(unsigned char *data, int size) {
  memset(data, 0, size);
  data[4] = 520 & 0xFF; data[5] = (520 >> 8) & 0xFF;      // program 2 offset
  data[500] = 540 & 0xFF; data[501] = (540 >> 8) & 0xFF;  // instrument 0 offset (program 250)
  int p = 520;
  data[p++] = 0;    data[p++] = 16;                        // channel, priority
  data[p++] = 0xA6; data[p++] = 0xFF;                      // setTempo 0xFF
  data[p++] = 0x87; data[p++] = 0x04;                      // setBaseOctave 4
  data[p++] = 0x90; data[p++] = 0x00;                      // setupInstrument 0
  data[p++] = 0xB9; data[p++] = 0x05;                      // pitchBend +5
  data[p++] = 0x91; data[p++] = 0x08; data[p++] = 0x00; data[p++] = 0x20; // setupPrimaryEffectSlide
  data[p++] = 0x20; data[p++] = 0x18;                      // inline note 0x20, duration 24 (key-on)
  data[p++] = 0x88;                                        // stopChannel
  unsigned char instr[11] = { 0x01,0x01,0x00,0x00,0x00,0x10,0x00,0xF0,0xF0,0x00,0x00 };
  memcpy(data + 540, instr, 11);
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s <out.trace> <out.bin>\n", argv[0]); return 2; }
  const int SIZE = 600;
  unsigned char data[SIZE];
  buildSoundData(data, SIZE);

  RecordingOpl opl;
  AdLibDriver drv(&opl);
  drv.setVersion(3);
  drv.setSoundData(data, SIZE);
  drv.initDriver();
  drv.stopAllChannels();
  drv.startSound(2, 0xFF);
  for (int i = 0; i < 40; i++) drv.callback();

  FILE *tf = fopen(argv[1], "w");
  for (size_t i = 0; i < g_trace.size(); i++) fprintf(tf, "%02X %02X\n", g_trace[i].reg, g_trace[i].val);
  fclose(tf);

  FILE *bf = fopen(argv[2], "wb");
  fwrite(data, 1, SIZE, bf);
  fclose(bf);
  return 0;
}
EOF

if command -v c++ >/dev/null 2>&1; then CXX=c++; else CXX="xcrun clang++"; fi
echo "→ building AdPlug trace harness with: $CXX"
$CXX -std=c++11 -w -I "$BUILD" "$BUILD/harness.cpp" -o "$BUILD/harness"

echo "→ generating $OUT/synth_track.{trace,bin}"
"$BUILD/harness" "$OUT/synth_track.trace" "$OUT/synth_track.bin"

echo "Done. $(wc -l < "$OUT/synth_track.trace") writes captured."

# --- Real-track oracle: full CadlPlayer over an actual DUNE*.ADL ---------------
# Uses a file-backed binistream so AdPlug's real load→rewind→update path runs.
# Generates the audible-track golden if the asset is present (game data; not
# committed). Adjust ADL_SONG / ADL_SUBSONG / ADL_TICKS as needed.
ADL_SONG="${ADL_SONG:-Resources/Music/DUNE8.ADL}"
ADL_SUBSONG="${ADL_SUBSONG:-2}"
ADL_TICKS="${ADL_TICKS:-600}"
ADL_TRACE_NAME="${ADL_TRACE_NAME:-DUNE8.2}"

if [ -f "$ADL_SONG" ]; then
    S=.build/adl_song
    mkdir -p "$S"
    cp "$REF/adl.cpp" "$REF/adl.h" "$REF/opl.h" "$S/"
    cp "$BUILD/database.h" "$BUILD/debug.h" "$BUILD/player.h" "$S/"

    cat > "$S/binio.h" <<'EOF'
#ifndef BINIO_REAL_H
#define BINIO_REAL_H
#include <cstdio>
class binistream {
  FILE *f; long sz;
public:
  binistream(FILE *fp) : f(fp), sz(0) { if (f) { fseek(f,0,SEEK_END); sz=ftell(f); fseek(f,0,SEEK_SET); } }
  ~binistream() { if (f) fclose(f); }
  unsigned long readString(char *dst, unsigned long n) { return (unsigned long)fread(dst, 1, n, f); }
  long size() const { return sz; }
};
#endif
EOF
    cat > "$S/fprovide.h" <<'EOF'
#ifndef H_ADPLUG_FILEPROVIDER
#define H_ADPLUG_FILEPROVIDER
#include <string>
#include "binio.h"
class CFileProvider {
public:
  virtual ~CFileProvider() {}
  virtual binistream *open(std::string) const = 0;
  virtual void close(binistream *) const = 0;
  static bool extension(const std::string &, const std::string &) { return true; }
  static unsigned long filesize(binistream *f) { return f ? (unsigned long)f->size() : 0; }
};
class CProvider_Filesystem : public CFileProvider {
public:
  binistream *open(std::string fn) const { FILE *fp = fopen(fn.c_str(), "rb"); return fp ? new binistream(fp) : 0; }
  void close(binistream *b) const { delete b; }
};
#endif
EOF
    cat > "$S/song_harness.cpp" <<'EOF'
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include "adl.cpp"
struct Rec { int reg, val; };
static std::vector<Rec> g_trace;
class RecordingOpl : public Copl {
public:
  void write(int reg, int val) { g_trace.push_back(Rec{reg & 0xFF, val & 0xFF}); }
  void init() {}
};
int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: %s <file.adl> <subsong> <ticks> <out.trace>\n", argv[0]); return 2; }
  RecordingOpl opl; CadlPlayer player(&opl); CProvider_Filesystem fp;
  if (!player.load(argv[1], fp)) { fprintf(stderr, "load failed: %s\n", argv[1]); return 1; }
  fprintf(stderr, "subsongs=%u type=%s\n", player.getsubsongs(), player.gettype().c_str());
  g_trace.clear();
  player.rewind(atoi(argv[2]));
  int ticks = atoi(argv[3]);
  for (int i = 0; i < ticks; i++) player.update();
  FILE *tf = fopen(argv[4], "w");
  for (size_t i = 0; i < g_trace.size(); i++) fprintf(tf, "%02X %02X\n", g_trace[i].reg, g_trace[i].val);
  fclose(tf);
  fprintf(stderr, "writes=%zu\n", g_trace.size());
  return 0;
}
EOF
    echo "→ building real-track oracle with: $CXX"
    $CXX -std=c++11 -w -I "$S" "$S/song_harness.cpp" -o "$S/song_harness"
    echo "→ tracing $ADL_SONG subsong $ADL_SUBSONG ($ADL_TICKS ticks) → $OUT/$ADL_TRACE_NAME.trace"
    "$S/song_harness" "$ADL_SONG" "$ADL_SUBSONG" "$ADL_TICKS" "$OUT/$ADL_TRACE_NAME.trace"
else
    echo "skip real-track oracle: $ADL_SONG not present"
fi
