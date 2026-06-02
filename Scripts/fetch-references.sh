#!/usr/bin/env bash
# Copyright (C) 2026 Alex Babaev
# SwiftOPL3 — https://github.com/bealex/SwiftOLP3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Clone the golden-standard reference sources into References/ (gitignored).
# These are oracles only — they are NEVER part of the Swift build.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p References
cd References

clone() { # url dir [pin]
  local url="$1" dir="$2" pin="${3:-}"
  if [ -d "$dir/.git" ]; then echo "✓ $dir present"; return; fi
  echo "→ cloning $dir"
  git clone --depth 1 "$url" "$dir"
  if [ -n "$pin" ]; then ( cd "$dir" && git fetch --depth 1 origin "$pin" && git checkout -q "$pin" ); fi
}

# Chip reference (transcription source). PIN a commit and record it in History.
clone https://github.com/nukeykt/Nuked-OPL3.git Nuked-OPL3

# Driver reference (LGPL transcription source).
clone https://github.com/adplug/adplug.git adplug

# Cross-references / oracles (optional — uncomment as needed):
# clone https://github.com/scemino/NScumm.Audio.git NScumm.Audio       # C# AdLib driver
# clone https://github.com/scummvm/scummvm.git scummvm                 # engines/kyra/.../adlib.cpp (large)

echo "Done. Pin the Nuked-OPL3 commit you port against and note it in Documentation/History."
