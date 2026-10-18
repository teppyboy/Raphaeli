#!/bin/bash
# Argument-parsing and dry-run tests for install.sh. No sudo, no system changes:
# every privileged step must print DRY-RUN lines only.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL="$HERE/install.sh"
pass=0
fail=0

t() { # t <name> <expected-exit> <cmd...>
  local name=$1 want=$2; shift 2
  local got
  out=$("$@" 2>&1); got=$?
  if [[ $got == "$want" ]]; then
    echo "ok    $name"; pass=$((pass + 1))
  else
    echo "FAIL  $name (exit $got, want $want)"; echo "$out" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}
assert_out() { # assert_out <name> <pattern> (uses $out from last t)
  local name=$1 pattern=$2
  if [[ $out == *$pattern* ]]; then
    echo "ok    $name"; pass=$((pass + 1))
  else
    echo "FAIL  $name (pattern not in output)"; echo "$out" | sed 's/^/      /'
    fail=$((fail + 1))
  fi
}

KEXT=$(mktemp -d)/Raphaeli.kext
mkdir -p "$KEXT/Contents/MacOS"
printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>me.tretrauit.raphaeli</string><key>CFBundleExecutable</key><string>Raphaeli</string></dict></plist>' > "$KEXT/Contents/Info.plist"
printf 'me.tretrauit.raphaeli\n' > "$KEXT/Contents/MacOS/Raphaeli"
TMPFW=$(mktemp -d)

# full dry-run with a complete temp firmware source
cp "$HERE/../firmware/amdgpu/"*.bin "$TMPFW"/

t "help exits 0"              0 "$INSTALL" --help
t "unknown option fails"      1 "$INSTALL" --bogus
t "two kext paths fail"       1 "$INSTALL" "$KEXT" "$KEXT"
t "nonexistent kext fails"    1 "$INSTALL" --dry-run /tmp/no-such.kext

RAPHAELI_FW_SRC=$TMPFW t "full dry-run succeeds" 0 env RAPHAELI_FW_SRC=$TMPFW "$INSTALL" --dry-run "$KEXT"
assert_out "dry-run prints ditto"        "DRY-RUN: sudo ditto"
assert_out "dry-run prints chown"        "DRY-RUN: sudo chown -R root:wheel /Library/Extensions/Raphaeli.kext"
assert_out "dry-run prints stage.sh"     "DRY-RUN: sudo sh *Firmware/stage.sh"
assert_out "dry-run prints kmutil"       "DRY-RUN: sudo kmutil create"
assert_out "dry-run prints auxkc path"   "/Library/KernelCollections/Raphaeli.auxkc"
assert_out "prints apply step (cp)"      "sudo cp /Library/KernelCollections/Raphaeli.auxkc"
assert_out "prints boot-guard rollback"  "nvram -d raphaeli-gpu-attaching"
assert_out "does not set boot-args"      "not applying boot-args"

# missing-firmware census abort with clear message
rm "$TMPFW/psp_13_0_11_toc.bin"
t "missing firmware aborts" 1 env RAPHAELI_FW_SRC=$TMPFW "$INSTALL" --dry-run "$KEXT"
assert_out "lists missing file"     "amdgpu/psp_13_0_11_toc.bin"
assert_out "says where to fetch"    "linux-firmware"

rm -rf "$TMPFW"
echo
echo "passed=$pass failed=$fail"
exit $((fail > 0))
