#!/bin/bash
# Tests for recovery-install.sh: fake dist tree + fake volume in a temp dir,
# mocked nvram (recorded in a state file). No system changes, no real /Volumes.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
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

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# ---- fake dist tree (mirrors the package.sh zip layout) ----------------------

DIST=$WORK/dist
mkdir -p "$DIST"/{tools/fw,usr/lib,firmware/amdgpu,target/Sequoia,target/Tahoe}
cp "$HERE/recovery-install.sh" "$DIST/tools/"
cp "$HERE/../Raphaeli/Firmware/stage.sh" "$DIST/tools/fw/"

# minimal kext bundle: Contents/Info.plist + executable, correct bundle id
KEXT=$DIST/kext/Raphaeli.kext
mkdir -p "$KEXT/Contents/MacOS"
plutil -insert CFBundleIdentifier -string me.tretrauit.raphaeli \
  -insert CFBundleExecutable -string raphaeli \
  "$KEXT/Contents/Info.plist" 2>/dev/null || {
  printf '<?xml version="1.0"?>\n<plist version="1.0"><dict>\n<key>CFBundleIdentifier</key><string>me.tretrauit.raphaeli</string>\n<key>CFBundleExecutable</key><string>raphaeli</string>\n</dict></plist>\n' > "$KEXT/Contents/Info.plist"
}
printf 'fixture executable\n' > "$KEXT/Contents/MacOS/raphaeli"; chmod +x "$KEXT/Contents/MacOS/raphaeli"
cp -R "$KEXT" "$DIST/target/Sequoia/Raphaeli.kext"
cp -R "$KEXT" "$DIST/target/Tahoe/Raphaeli.kext"

: > "$DIST/usr/lib/libvulkan_radeon.dylib"
: > "$DIST/usr/lib/libdrm.2.dylib"
: > "$DIST/usr/lib/libdrm_amdgpu.1.dylib"
for firmware_name in \
  gc_11_0_1_pfp.bin gc_11_0_1_me.bin gc_11_0_1_rlc.bin \
  gc_11_0_1_mec.bin gc_11_0_1_imu.bin gc_11_0_1_mes1.bin \
  sdma_6_0_2.bin psp_13_0_11_toc.bin psp_13_0_11_ta.bin \
  vcn_4_0_2.bin dcn_3_1_4_dmcub.bin; do
  : > "$DIST/firmware/amdgpu/$firmware_name"
done
: > "$DIST/firmware/amdgpu/ip_discovery.bin"   # optional blob

# ---- mock nvram: state file, mimics name<TAB>value ----------------------------

NVRAM_STATE=$WORK/nvram.state
printf 'boot-args\tnv_disable=1\n' > "$NVRAM_STATE"   # pre-existing boot-args must survive
SHIM=$WORK/shim
mkdir -p "$SHIM"
cat > "$SHIM/nvram" <<EOF
#!/bin/bash
# mock nvram for tests: state in $NVRAM_STATE
S="$NVRAM_STATE"
case "\$1" in
  -p) cat "\$S" ;;
  -d) { grep -v "^\$2	" "\$S" || true; } > "\$S.new"; mv "\$S.new" "\$S" ;;
  *=*)
    k=\${1%%=*}; v=\${1#*=}
    { grep -v "^\$k	" "\$S" || true; } > "\$S.new"; mv "\$S.new" "\$S"
    printf '%s\t%s\n' "\$k" "\$v" >> "\$S"
    ;;
  *)  # nvram boot-args
    grep "^\$1	" "\$S" || exit 1
    ;;
esac
EOF
chmod +x "$SHIM/nvram"

VOLDIR=$WORK/volumes   # RAPHAELI_VOLUMES_DIR override for detection tests
newvol() { # newvol <name> -> echoes path; minimal macOS volume shape
  local v=$VOLDIR/$1
  mkdir -p "$v"/{Library/Extensions,System/Library}
  echo "$v"
}

run_inst() { # run_inst <volume> <args...>
  PATH="$SHIM:$PATH" RAPHAELI_VOLUMES_DIR=$VOLDIR "$DIST/tools/recovery-install.sh" "$@"
}

# ---- volume detection ---------------------------------------------------------

V1=$(newvol "Macintosh HD")
V2=$(newvol "Other HD")
t "explicit volume works"            0 run_inst "$V1" --dry-run
t "ambiguous volumes fail"           1 env PATH="$SHIM:$PATH" RAPHAELI_VOLUMES_DIR=$VOLDIR \
                                        "$DIST/tools/recovery-install.sh" --dry-run
assert_out "ambiguity prints usage"  "usage: recovery-install.sh /Volumes/Macintosh"

t "two candidates: explicit still ok" 0 run_inst "$V2" --dry-run

t "Sequoia target resolves package bundle" 0 run_inst "$V1" --target sequoia --dry-run
assert_out "Sequoia bundle selected" "$DIST/target/Sequoia/Raphaeli.kext"
t "Tahoe target resolves package bundle" 0 run_inst "$V1" --target=tahoe --dry-run
assert_out "Tahoe bundle selected" "$DIST/target/Tahoe/Raphaeli.kext"
KEXT_OVERRIDE=$DIST/kext/Raphaeli.kext
run_override() { RAPHAELI_KEXT=$KEXT_OVERRIDE run_inst "$@"; }
t "explicit kext override wins" 0 run_override "$V1" --target tahoe --dry-run
assert_out "override selected" "$KEXT_OVERRIDE"

rm -rf "$V2"                          # single candidate -> auto-detected
out=$(PATH="$SHIM:$PATH" RAPHAELI_VOLUMES_DIR=$VOLDIR "$DIST/tools/recovery-install.sh" --dry-run 2>&1)
if [[ $? == 0 && $out == *"target volume: $V1"* ]]; then
  echo "ok    single candidate auto-detected"; pass=$((pass + 1))
else
  echo "FAIL  single candidate auto-detected"; echo "$out" | sed 's/^/      /'; fail=$((fail + 1))
fi

# ---- dry-run output -----------------------------------------------------------

t "dry-run exits 0"                       0 run_inst "$V1" --dry-run
assert_out "prints dylib copy"            "cp -f"
assert_out "dylibs to Library/Raphaeli"   "$V1/Library/Raphaeli/usr/lib"
assert_out "prints ICD json path"         "$V1/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json"
assert_out "prints absolute library_path" "library_path=/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib"
assert_out "prints kext ditto"            "ditto *dist/kext/Raphaeli.kext"
assert_out "prints chown root:wheel"      "chown -R root:wheel"
assert_out "prints firmware staging"      "stage.sh"
assert_out "prints mount -uw"             "mount -uw $V1"
assert_out "no boot-args without --apply" "not applying boot-args"
if [[ $out != *"nvram boot-args="* ]]; then
  echo "ok    dry-run never touches nvram"; pass=$((pass + 1))
else
  echo "FAIL  dry-run touches nvram"; fail=$((fail + 1))
fi

# ---- real apply into fake volume (non-root: chown warns but continues) --------

t "apply succeeds"                    0 run_inst "$V1" --apply
assert_out "boot-arg set"             "applying boot-arg opt-in (raphaeli-amd=1)"
[[ -f $V1/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib ]] && \
  { echo "ok    dylib installed"; pass=$((pass + 1)); } || \
  { echo "FAIL  dylib installed"; fail=$((fail + 1)); }
[[ -f $V1/Library/Raphaeli/usr/lib/libdrm.2.dylib ]] && \
  { echo "ok    libdrm installed"; pass=$((pass + 1)); } || \
  { echo "FAIL  libdrm installed"; fail=$((fail + 1)); }
[[ -f $V1/Library/Raphaeli/firmware/amdgpu/psp_13_0_11_toc.bin ]] && \
  { echo "ok    firmware staged"; pass=$((pass + 1)); } || \
  { echo "FAIL  firmware staged"; fail=$((fail + 1)); }
[[ -f $V1/Library/Extensions/Raphaeli.kext/Contents/Info.plist ]] && \
  { echo "ok    kext installed"; pass=$((pass + 1)); } || \
  { echo "FAIL  kext installed"; fail=$((fail + 1)); }

# ICD json: absolute library_path, valid placement
if grep -q '"library_path": "/Library/Raphaeli/usr/lib/libvulkan_radeon.dylib"' \
      "$V1/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json"; then
  echo "ok    json library_path absolute"; pass=$((pass + 1))
else
  echo "FAIL  json library_path absolute"; cat "$V1/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json"; fail=$((fail + 1))
fi

# boot-args: added on top of pre-existing args, guard marker untouched
expected="nv_disable=1 raphaeli-amd=1"
got=$(grep '^boot-args	' "$NVRAM_STATE" | cut -f2-)
if [[ $got == "$expected" ]]; then
  echo "ok    boot-args appended, existing preserved"; pass=$((pass + 1))
else
  echo "FAIL  boot-args appended (got '$got', want '$expected')"; fail=$((fail + 1))
fi

# idempotent apply
t "apply is idempotent"               0 run_inst "$V1" --apply
assert_out "already contains"         "boot-args already contain raphaeli-amd=1"

# ---- OC-detect: skip kext copy + auxKC ----------------------------------------

V3=$(newvol "OC HD")
mkdir -p "$V3/EFI/OC"
: > "$V3/EFI/OC/config.plist"
t "OC volume apply succeeds"          0 run_inst "$V3" --apply
assert_out "OC detected"              "OC config found"
assert_out "skips kext copy"          "skipping kext copy + auxKC"
[[ ! -e $V3/Library/Extensions/Raphaeli.kext ]] && \
  { echo "ok    no kext in OC mode"; pass=$((pass + 1)); } || \
  { echo "FAIL  no kext in OC mode"; fail=$((fail + 1)); }
[[ -f $V3/Library/Raphaeli/firmware/amdgpu/vcn_4_0_2.bin ]] && \
  { echo "ok    firmware still staged in OC mode"; pass=$((pass + 1)); } || \
  { echo "FAIL  firmware still staged in OC mode"; fail=$((fail + 1)); }
[[ -f $V3/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json ]] && \
  { echo "ok    ICD json in OC mode"; pass=$((pass + 1)); } || \
  { echo "FAIL  ICD json in OC mode"; fail=$((fail + 1)); }

# ---- required input failures --------------------------------------------------

mv "$DIST/usr/lib/libvulkan_radeon.dylib" "$WORK/libvulkan_radeon.dylib.missing"
t "missing required userspace input aborts" 1 run_inst "$V1" --dry-run
mv "$WORK/libvulkan_radeon.dylib.missing" "$DIST/usr/lib/libvulkan_radeon.dylib"
mv "$DIST/firmware/amdgpu/vcn_4_0_2.bin" "$WORK/vcn_4_0_2.bin.missing"
t "missing required firmware input aborts" 1 run_inst "$V1" --dry-run
mv "$WORK/vcn_4_0_2.bin.missing" "$DIST/firmware/amdgpu/vcn_4_0_2.bin"

# ---- checksum manifest --------------------------------------------------------

V4=$(newvol "BadSum HD")
( cd "$DIST/firmware/amdgpu" && shasum -a 256 psp_13_0_11_toc.bin > SHA256SUMS \
  && sed -i '' 's/^\(.\)/0\1/' SHA256SUMS )   # corrupt first hex digit
t "bad checksum aborts"               1 run_inst "$V4" --dry-run
assert_out "checksum failure message" "checksum verification FAILED"
rm "$DIST/firmware/amdgpu/SHA256SUMS"
( cd "$DIST/firmware/amdgpu" && shasum -a 256 psp_13_0_11_toc.bin > SHA256SUMS )
t "good checksum passes"              0 run_inst "$V4" --dry-run
rm "$DIST/firmware/amdgpu/SHA256SUMS"

# ---- uninstall ----------------------------------------------------------------

printf 'raphaeli-gpu-attaching\t1\n' >> "$NVRAM_STATE"
t "uninstall succeeds"                0 run_inst "$V1" --uninstall
[[ ! -e $V1/Library/Raphaeli ]] && \
  { echo "ok    Library/Raphaeli removed"; pass=$((pass + 1)); } || \
  { echo "FAIL  Library/Raphaeli removed"; fail=$((fail + 1)); }
[[ ! -e $V1/Library/Extensions/Raphaeli.kext ]] && \
  { echo "ok    kext removed"; pass=$((pass + 1)); } || \
  { echo "FAIL  kext removed"; fail=$((fail + 1)); }
[[ ! -e $V1/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json ]] && \
  { echo "ok    ICD json removed"; pass=$((pass + 1)); } || \
  { echo "FAIL  ICD json removed"; fail=$((fail + 1)); }
got=$(grep '^boot-args	' "$NVRAM_STATE" | cut -f2-)
if [[ $got == "nv_disable=1" ]]; then
  echo "ok    nvram state: boot-arg gone, others kept"; pass=$((pass + 1))
else
  echo "FAIL  nvram state after uninstall (got '$got')"; fail=$((fail + 1))
fi
grep -q '^raphaeli-gpu-attaching' "$NVRAM_STATE" && \
  { echo "FAIL  guard marker still set"; fail=$((fail + 1)); } || \
  { echo "ok    guard marker cleared in mock"; pass=$((pass + 1)); }

# uninstall with raphaeli-amd=1 as the only boot-arg -> nvram -d boot-args
printf 'boot-args\traphaeli-amd=1\n' > "$NVRAM_STATE"   # lone boot-arg (apply is a no-op then)
V5=$(newvol "Clean HD")
run_inst "$V5" --apply >/dev/null 2>&1
run_inst "$V5" --uninstall >/dev/null 2>&1
grep -q '^boot-args	' "$NVRAM_STATE" && \
  { echo "FAIL  lone boot-arg removed entirely"; fail=$((fail + 1)); } || \
  { echo "ok    lone boot-arg removed entirely"; pass=$((pass + 1)); }

# ---- misc ---------------------------------------------------------------------

t "help exits 0"                      0 run_inst --help
t "unknown option fails"              1 run_inst "$V1" --bogus
t "nonexistent volume fails"          1 run_inst "$WORK/no-such-vol"
t "non-macOS volume fails"            1 run_inst "$WORK"   # no Library/

# bad bundle id rejected
BADKEXT=$WORK/bad/Raphaeli.kext
mkdir -p "$BADKEXT/Contents"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict>\n<key>CFBundleIdentifier</key><string>com.other.kext</string>\n</dict></plist>\n' > "$BADKEXT/Contents/Info.plist"
out=$(RAPHAELI_KEXT=$BADKEXT RAPHAELI_FW_SRC=$DIST/firmware/amdgpu PATH="$SHIM:$PATH" \
      RAPHAELI_VOLUMES_DIR=$VOLDIR "$DIST/tools/recovery-install.sh" "$V1" --dry-run 2>&1)
if [[ $? == 1 && $out == *"unexpected bundle id 'com.other.kext'"* ]]; then
  echo "ok    wrong bundle id rejected"; pass=$((pass + 1))
else
  echo "FAIL  wrong bundle id rejected"; echo "$out" | sed 's/^/      /'; fail=$((fail + 1))
fi

echo
echo "passed=$pass failed=$fail"
exit $((fail > 0))
