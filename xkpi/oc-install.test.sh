#!/bin/bash
# Tests for oc-install.sh / oc-install.py against a fake EFI tree in /tmp.
# Never touches a real EFI. Requires python3 (same as the tool itself).
set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OC="$SCRIPT_DIR/oc-install.sh"
PYCORE="$SCRIPT_DIR/oc-install.py"
PY=$(command -v python3 || command -v python || true)
GUID=7C436110-AB2A-4BBB-A880-FE41995C9F82
T=$(mktemp -d /tmp/raphaeli-oc-test.XXXXXX)
trap 'rm -rf "$T"' EXIT

fails=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails+1)); }
assert_eq()      { [[ "$2" == "$3" ]] && ok "$1" || bad "$1 (got: '$2' want: '$3')"; }
assert_contains(){ [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1 (output missing: '$3')"; }

mkfake_efi() { # $1 = dir: minimal OC tree with one dummy Add entry + boot-args
  local root=$1
  mkdir -p "$root/EFI/OC/Kexts"
  cat > "$root/EFI/OC/config.plist" <<EOF
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

mkfake_kext() { # $1 = dir: minimal Raphaeli.kext bundle
  mkdir -p "$1/Contents/MacOS"
  cat > "$1/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>me.tretrauit.raphaeli</string>
  <key>CFBundleExecutable</key><string>Raphaeli</string>
</dict></plist>
EOF
  : > "$1/Contents/MacOS/Raphaeli"
}

# Count Kernel>Add entries whose BundlePath is Raphaeli.kext (plistlib-based).
count_entries() {
  "$PY" - "$1" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    cfg = plistlib.load(f)
add = cfg.get("Kernel", {}).get("Add", [])
print(sum(1 for e in add if e.get("BundlePath") == "Raphaeli.kext"))
PYEOF
}
bootargs() {
  "$PY" - "$1" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    cfg = plistlib.load(f)
print(cfg.get("NVRAM", {}).get("Add", {}).get("7C436110-AB2A-4BBB-A880-FE41995C9F82", {}).get("boot-args", ""))
PYEOF
}

[[ -n $PY ]] || { echo "FAIL: python3 not found"; exit 1; }

echo "== test 0: python core is portable (stdlib imports only)"
mods=$(grep -E '^(import|from) ' "$PYCORE" | awk '{print $2}' | sort -u)
portable=1
for m in $mods; do
  case $m in
    os|re|shutil|subprocess|sys|plistlib|datetime|typing) ;;
    *) bad "python core imports non-portable module: $m"; portable=0 ;;
  esac
done
(( portable )) && ok "python core imports: $(echo $mods | tr '\n' ' ')"
# no macOS-only plist/copy/framework references in the core (diskutil/udisksctl
# for mounting are the sanctioned per-OS volume resolvers and are allowed)
grep -qE 'import (Foundation|AppKit|objc)|PlistBuddy|plutil|ditto' "$PYCORE" \
  && bad "python core references macOS-only plist/copy tools" \
  || ok "python core: no macOS-only plist/copy tool references"

EFI="$T/efi"
KEXT_SRC="$T/src/Raphaeli.kext"
mkfake_kext "$KEXT_SRC"

echo "== test 1: --add inserts entry + stages kext + backup (via shell wrapper)"
mkfake_efi "$EFI"
"$OC" "$EFI" --add --kext-src "$KEXT_SRC" >/dev/null || bad "add exited nonzero"
assert_eq "add: one entry"        "1" "$(count_entries "$EFI/EFI/OC/config.plist")"
"$PY" -c "
import plistlib
cfg = plistlib.load(open('$EFI/EFI/OC/config.plist','rb'))
e = [x for x in cfg['Kernel']['Add'] if x['BundlePath']=='Raphaeli.kext'][0]
assert e['Enabled'] is True and e['MinKernel']=='23.4.0' and e['ExecutablePath']=='Contents/MacOS/Raphaeli', e
assert cfg['Kernel']['Add'][0]['BundlePath']=='Dummy.kext'
" && ok "add: entry fields (Enabled/MinKernel/ExecutablePath, dummy kept)" || bad "add: entry fields wrong"
[[ -d $EFI/EFI/OC/Kexts/Raphaeli.kext/Contents/MacOS ]] && ok "add: kext staged (copytree)" || bad "add: kext not staged"
ls "$EFI"/EFI/OC/config.plist.raphaeli-backup-* >/dev/null 2>&1 && ok "add: backup created" || bad "add: no backup"
assert_eq "add: no boot-arg added" "keepsyms=1 debug=0x100" "$(bootargs "$EFI/EFI/OC/config.plist")"

echo "== test 2: --add idempotency"
before=$(count_entries "$EFI/EFI/OC/config.plist")
"$OC" "$EFI" --add --kext-src "$KEXT_SRC" >/dev/null || bad "re-add exited nonzero"
assert_eq "add idempotent: still one entry" "$before" "$(count_entries "$EFI/EFI/OC/config.plist")"

echo "== test 3: --enable appends + idempotent, --disable strips"
"$OC" "$EFI" --enable >/dev/null || bad "enable exited nonzero"
assert_eq "enable: boot-args"     "keepsyms=1 debug=0x100 raphaeli-amd=1" "$(bootargs "$EFI/EFI/OC/config.plist")"
"$OC" "$EFI" --enable >/dev/null
assert_eq "enable idempotent"     "keepsyms=1 debug=0x100 raphaeli-amd=1" "$(bootargs "$EFI/EFI/OC/config.plist")"
"$OC" "$EFI" --disable >/dev/null || bad "disable exited nonzero"
assert_eq "disable: boot-args"    "keepsyms=1 debug=0x100" "$(bootargs "$EFI/EFI/OC/config.plist")"

echo "== test 4: --dry-run prints but does not mutate"
"$OC" "$EFI" --enable --dry-run > "$T/dry.out" 2>&1 || bad "dry-run enable exited nonzero"
assert_contains "dry-run: prints planned change" "$(cat "$T/dry.out")" "raphaeli-amd=1"
assert_eq "dry-run: boot-args untouched"   "keepsyms=1 debug=0x100" "$(bootargs "$EFI/EFI/OC/config.plist")"
"$OC" "$EFI" --remove --dry-run >/dev/null 2>&1
assert_eq "dry-run: entry still there" "1" "$(count_entries "$EFI/EFI/OC/config.plist")"
[[ -d $EFI/EFI/OC/Kexts/Raphaeli.kext ]] && ok "dry-run: kext still staged" || bad "dry-run: kext removed"

echo "== test 5: --status"
out=$("$OC" "$EFI" --status)
assert_contains "status: entry reported"  "$out" "Kernel>Add:1, Enabled=true"
assert_contains "status: kext staged"     "$out" "kext staged:       EFI/OC/Kexts/Raphaeli.kext"
assert_contains "status: boot-arg absent" "$out" "boot-arg:          not set"
assert_contains "status: firmware line"   "$out" "Library/Raphaeli/firmware"

echo "== test 6: --remove rolls back fully, keeps backup"
"$OC" "$EFI" --remove >/dev/null || bad "remove exited nonzero"
assert_eq "remove: entry gone"    "0" "$(count_entries "$EFI/EFI/OC/config.plist")"
[[ -d $EFI/EFI/OC/Kexts/Raphaeli.kext ]] && bad "remove: kext still staged" || ok "remove: kext deleted"
ls "$EFI"/EFI/OC/config.plist.raphaeli-backup-* >/dev/null 2>&1 && ok "remove: backup kept" || bad "remove: backup gone"

echo "== test 7: missing Add array case + missing target (python core direct)"
mkdir -p "$T/efi2/EFI/OC/Kexts"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "$T/efi2/EFI/OC/config.plist"
"$PYCORE" "$T/efi2" --add --kext-src "$KEXT_SRC" >/dev/null 2>&1 || bad "add (no Add array) exited nonzero"
assert_eq "add: created Add array" "1" "$(count_entries "$T/efi2/EFI/OC/config.plist")"
"$OC" "$T/nonexistent-volume" --status >/dev/null 2>&1 && bad "bad target should fail" || ok "bad target rejected"

echo "== test 8: python core smoke cycle (direct add/enable/remove, no shell wrapper)"
mkfake_efi "$T/efi3"
"$PYCORE" "$T/efi3" --add --kext-src "$KEXT_SRC" >/dev/null || bad "py add exited nonzero"
"$PYCORE" "$T/efi3" --enable >/dev/null || bad "py enable exited nonzero"
assert_eq "py: boot-args after enable" "keepsyms=1 debug=0x100 raphaeli-amd=1" "$(bootargs "$T/efi3/EFI/OC/config.plist")"
"$PYCORE" "$T/efi3" --remove >/dev/null || bad "py remove exited nonzero"
assert_eq "py: entry gone after remove" "0" "$(count_entries "$T/efi3/EFI/OC/config.plist")"

echo
if (( fails )); then echo "$fails test(s) FAILED"; exit 1; fi
echo "ALL TESTS PASSED"
