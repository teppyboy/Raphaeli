#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
SDK=$(xcrun --sdk macosx --show-sdk-path)
HEADERS="$SDK/System/Library/Frameworks/Kernel.framework/Headers"
OUT=${1:-"$ROOT/build"}
mkdir -p "$OUT/PhoenixProbe.kext/Contents/MacOS"
xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -mkernel -fapple-kext -nostdinc -isysroot "$SDK" \
  -I"$HEADERS" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -O2 -Wall \
  -c "$ROOT/PhoenixProbe.cpp" -o "$OUT/PhoenixProbe.kext/Contents/MacOS/PhoenixProbe.o"
xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -fapple-kext -nostdlib -Xlinker -kext \
  "$OUT/PhoenixProbe.kext/Contents/MacOS/PhoenixProbe.o" -lkmodc++ -lkmod -lcc_kext \
  -o "$OUT/PhoenixProbe.kext/Contents/MacOS/PhoenixProbe"
cp "$ROOT/Info.plist" "$OUT/PhoenixProbe.kext/Contents/Info.plist"
printf 'Built diagnostic-only kext: %s\n' "$OUT/PhoenixProbe.kext"
