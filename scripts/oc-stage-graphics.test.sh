#!/bin/bash
# Tests for oc-stage-graphics.py against fake Recovery/KDK/EFI trees in /tmp.
# External tools (kmutil, strings, dwarfdump) are faked on PATH; never touches
# a real EFI, KDK, or BaseSystem image.
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
STAGE="$SCRIPT_DIR/oc-stage-graphics.py"
PY=$(command -v python3 || command -v python || true)
T=$(mktemp -d /tmp/raphaeli-graphics-test.XXXXXX)
trap 'rm -rf "$T"' EXIT

fails=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails+1)); }
assert_eq()       { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got: '$2' want: '$3')"; }
assert_contains() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1 (output missing: '$3')"; }

[[ -n $PY ]] || { echo "FAIL: python3 not found"; exit 1; }

GRAPHICS_UUID=CA8B49BC-3655-312C-91AA-FB848251C78E
ACCEL_UUID=65CEB805-D326-3F15-9595-F6EC0A6D78DA
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82

# $1=path, then key/value pairs (all strings) -> XML plist
write_plist() {
  "$PY" -c 'import plistlib,os,sys
p=sys.argv[1]; a=sys.argv[2:]
os.makedirs(os.path.dirname(p), exist_ok=True)
plistlib.dump(dict(zip(a[::2], a[1::2])), open(p, "wb"))' "$@"
}

# Fake tools: kmutil prints $FAKE_KMUTIL_OUT, strings prints the Darwin banner,
# dwarfdump prints the UUID stored in "<binary>.uuid" next to the binary.
mkfake_tools() {
  mkdir -p "$T/bin"
  cat > "$T/bin/kmutil" <<'EOF'
#!/bin/sh
cat "$FAKE_KMUTIL_OUT"
EOF
  cat > "$T/bin/strings" <<'EOF'
#!/bin/sh
echo "@(#)VERSION: Darwin Kernel Version 24.6.0: Wed Nov  5 21:30:23 PST 2025"
EOF
  cat > "$T/bin/dwarfdump" <<'EOF'
#!/bin/sh
for last; do :; done
echo "UUID: $(cat "$last.uuid") (x86_64)"
EOF
  chmod +x "$T/bin/kmutil" "$T/bin/strings" "$T/bin/dwarfdump"
}

# $1=recovery version $2=recovery build $3=kdk version $4=kdk build $5=graphics uuid $6=accel uuid
mkfixture() {
  local root=$T/case
  rm -rf "$root"
  mkdir -p "$root/efi/EFI/OC/Kexts"
  write_plist "$root/recovery/System/Library/CoreServices/SystemVersion.plist" \
    ProductVersion "$1" ProductBuildVersion "$2"
  local kdk=$root/kdk
  write_plist "$kdk/System/Library/CoreServices/SystemVersion.plist" \
    ProductVersion "$3" ProductBuildVersion "$4"
  local ext=$kdk/System/Library/Extensions
  write_plist "$ext/IOGraphicsFamily.kext/Info.plist" \
    CFBundleIdentifier com.apple.iokit.IOGraphicsFamily CFBundleExecutable IOGraphicsFamily \
    CFBundleVersion 599 OSBundleCompatibleVersion 1.0.0b1
  printf 'graphics-binary' > "$ext/IOGraphicsFamily.kext/IOGraphicsFamily"
  printf '%s' "$GRAPHICS_UUID" > "$ext/IOGraphicsFamily.kext/IOGraphicsFamily.uuid"
  write_plist "$ext/IOAcceleratorFamily2.kext/Contents/Info.plist" \
    CFBundleIdentifier com.apple.iokit.IOAcceleratorFamily2 CFBundleExecutable IOAcceleratorFamily2 \
    CFBundleVersion 485 OSBundleCompatibleVersion 2.0.0
  mkdir -p "$ext/IOAcceleratorFamily2.kext/Contents/MacOS"
  printf 'accel-binary' > "$ext/IOAcceleratorFamily2.kext/Contents/MacOS/IOAcceleratorFamily2"
  printf '%s' "$5" > "$ext/IOAcceleratorFamily2.kext/Contents/MacOS/IOAcceleratorFamily2.uuid"
  # Keep the graphics UUID the fake dwarfdump reads for the graphics binary.
  printf '%s' "$GRAPHICS_UUID" > "$ext/IOGraphicsFamily.kext/IOGraphicsFamily.uuid"
  printf '%s' "$6" > "$ext/IOAcceleratorFamily2.kext/Contents/MacOS/IOAcceleratorFamily2.uuid"
  printf '%s\n' \
    "com.apple.iokit.IOAcceleratorFamily2	485	/System/Library/Extensions/IOAcceleratorFamily2.kext	($ACCEL_UUID)" \
    "com.apple.iokit.IOGraphicsFamily	599	/System/Library/Extensions/IOGraphicsFamily.kext	($GRAPHICS_UUID)" \
    > "$root/kmutil.out"
  cat > "$root/efi/EFI/OC/config.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Kernel</key>
  <dict>
    <key>Add</key>
    <array>
      <dict>
        <key>Arch</key><string>x86_64</string>
        <key>BundlePath</key><string>Dummy.kext</string>
        <key>Enabled</key><true/>
        <key>ExecutablePath</key><string>Contents/MacOS/Dummy</string>
        <key>PlistPath</key><string>Contents/Info.plist</string>
      </dict>
      <dict>
        <key>Arch</key><string>x86_64</string>
        <key>BundlePath</key><string>Raphaeli.kext</string>
        <key>Enabled</key><true/>
        <key>ExecutablePath</key><string>Contents/MacOS/Raphaeli</string>
        <key>PlistPath</key><string>Contents/Info.plist</string>
      </dict>
    </array>
  </dict>
  <key>NVRAM</key>
  <dict>
    <key>Add</key>
    <dict>
      <key>$GUID</key>
      <dict>
        <key>boot-args</key><string>keepsyms=1 debug=0x100</string>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
EOF
}

# Run the staging tool against the current fixture. Extra args are passed through.
run_stage() {
  local root=$T/case
  FAKE_KMUTIL_OUT=$root/kmutil.out PATH="$T/bin:$PATH" \
    "$PY" "$STAGE" "$root/efi" "$root/recovery" "$root/kdk" "$@"
}

config() { echo "$T/case/efi/EFI/OC/config.plist"; }
dest()   { echo "$T/case/efi/EFI/OC/Kexts/RaphaeliDependencies"; }

mkfake_tools

echo "== test 1: Tahoe Recovery is rejected (no Tahoe binaries mixed in)"
mkfixture 26.6 25G72 15.7.8 24G824 "$GRAPHICS_UUID" "$ACCEL_UUID"
out=$(run_stage --apply 2>&1) && bad "tahoe recovery accepted" || ok "tahoe recovery rejected"
assert_contains "tahoe: names Sequoia guard" "$out" "not Sequoia 15.x"
[[ -e $(dest) ]] && bad "tahoe: destination created" || ok "tahoe: no destination"

echo "== test 2: Tahoe KDK is rejected even with Sequoia Recovery"
mkfixture 15.7.8 24G824 27.0 26A5368g "$GRAPHICS_UUID" "$ACCEL_UUID"
out=$(run_stage --apply 2>&1) && bad "tahoe KDK accepted" || ok "tahoe KDK rejected"
assert_contains "tahoe KDK: names KDK guard" "$out" "KDK is macOS 27.0"
[[ -e $(dest) ]] && bad "tahoe KDK: destination created" || ok "tahoe KDK: no destination"

echo "== test 3: Recovery/KDK build mismatch is rejected"
mkfixture 15.7.8 24G824 15.7.8 24G825 "$GRAPHICS_UUID" "$ACCEL_UUID"
out=$(run_stage 2>&1) && bad "build mismatch accepted" || ok "build mismatch rejected"
assert_contains "build mismatch: message" "$out" "Recovery/KDK build mismatch"

echo "== test 4: BootKC UUID mismatch is rejected"
mkfixture 15.7.8 24G824 15.7.8 24G824 "$GRAPHICS_UUID" "00000000-0000-0000-0000-000000000000"
out=$(run_stage 2>&1) && bad "uuid mismatch accepted" || ok "uuid mismatch rejected"
assert_contains "uuid mismatch: names family" "$out" "UUID mismatch: IOAcceleratorFamily2"

echo "== test 5: dry-run prints plan, changes nothing"
mkfixture 15.7.8 24G824 15.7.8 24G824 "$GRAPHICS_UUID" "$ACCEL_UUID"
cp "$(config)" "$T/orig.plist"
out=$(run_stage 2>&1) || bad "dry-run exited nonzero"
assert_contains "dry-run: Sequoia build checked" "$out" "IOGraphicsFamily: matching UUID"
assert_contains "dry-run: no-change message" "$out" "no changes made"
cmp -s "$T/orig.plist" "$(config)" && ok "dry-run: config unchanged" || bad "dry-run: config changed"
[[ -e $(dest) ]] && bad "dry-run: destination created" || ok "dry-run: no destination"

echo "== test 6: --apply stages both families before Raphaeli, Raphaeli stays inert"
mkfixture 15.7.8 24G824 15.7.8 24G824 "$GRAPHICS_UUID" "$ACCEL_UUID"
cp "$(config)" "$T/orig.plist"
out=$(run_stage --apply 2>&1) || { bad "apply exited nonzero"; echo "$out"; }
[[ -f $(dest)/IOGraphicsFamily.kext/Contents/MacOS/IOGraphicsFamily ]] && ok "apply: graphics staged" || bad "apply: graphics not staged"
[[ -f $(dest)/IOAcceleratorFamily2.kext/Contents/Info.plist ]] && ok "apply: accel plist staged" || bad "apply: accel plist not staged"
"$PY" - "$(config)" "$T/orig.plist" <<'PYEOF' && ok "apply: config order, versions, Raphaeli untouched" || bad "apply: config contents wrong"
import plistlib, sys
cfg = plistlib.load(open(sys.argv[1], "rb"))
orig = plistlib.load(open(sys.argv[2], "rb"))
add = cfg["Kernel"]["Add"]
paths = [e["BundlePath"] for e in add]
assert paths == ["Dummy.kext", "RaphaeliDependencies/IOGraphicsFamily.kext",
                 "RaphaeliDependencies/IOAcceleratorFamily2.kext", "Raphaeli.kext"], paths
dep = add[1]
assert dep["Enabled"] is True and dep["MinKernel"] == "24.6.0" and dep["MaxKernel"] == "24.6.99"
assert dep["ExecutablePath"] == "Contents/MacOS/IOGraphicsFamily"
raph = add[3]
assert raph == orig["Kernel"]["Add"][1], "Raphaeli entry changed"
assert cfg["NVRAM"] == orig["NVRAM"], "boot-args changed (must stay inert)"
PYEOF
backup=$(ls "$T/case/efi/EFI/OC"/config.plist.raphaeli-graphics-backup-* 2>/dev/null | head -1)
[[ -n $backup ]] && cmp -s "$backup" "$T/orig.plist" && ok "apply: backup matches original" || bad "apply: backup missing or differs"
assert_contains "apply: rollback instructions" "$out" "Rollback: restore that backup, then remove"

echo "== test 7: rollback restores original config and removes staged dependencies"
cp "$backup" "$(config)"
rm -rf "$(dest)"
cmp -s "$T/orig.plist" "$(config)" && ok "rollback: config restored" || bad "rollback: config differs"
[[ -e $(dest) ]] && bad "rollback: destination remains" || ok "rollback: destination removed"

echo "== test 8: second --apply refuses over existing staging, config untouched"
mkfixture 15.7.8 24G824 15.7.8 24G824 "$GRAPHICS_UUID" "$ACCEL_UUID"
run_stage --apply >/dev/null 2>&1 || bad "first apply failed"
cp "$(config)" "$T/applied.plist"
out=$(run_stage --apply 2>&1) && bad "re-apply accepted" || ok "re-apply rejected"
assert_contains "re-apply: message" "$out" "Dependency staging directory already exists"
cmp -s "$T/applied.plist" "$(config)" && ok "re-apply: config untouched" || bad "re-apply: config changed"

echo
if (( fails )); then echo "$fails test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
