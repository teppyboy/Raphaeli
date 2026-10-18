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
cp "$HERE/target-preflight.sh" "$DIST/tools/"
cp "$HERE/../Raphaeli/Kernel/Accel/upstream/SOURCE.lock" "$DIST/tools/"
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
printf 'fixture executable sequoia\n' > "$DIST/target/Sequoia/Raphaeli.kext/Contents/MacOS/raphaeli"
printf 'fixture executable tahoe\n' > "$DIST/target/Tahoe/Raphaeli.kext/Contents/MacOS/raphaeli"
chmod +x "$DIST/target/Sequoia/Raphaeli.kext/Contents/MacOS/raphaeli" "$DIST/target/Tahoe/Raphaeli.kext/Contents/MacOS/raphaeli"

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

run_inst() { # run_inst <volume> <args...>; package installs select Sequoia by default in tests
  case " $* " in
    *" --target "*|*--target=*) ;;
    *) set -- "$@" --target sequoia ;;
  esac
  PATH="$SHIM:$PATH" RAPHAELI_VOLUMES_DIR=$VOLDIR "$DIST/tools/recovery-install.sh" "$@"
}

# ---- volume detection ---------------------------------------------------------

V1=$(newvol "Macintosh HD")
V2=$(newvol "Other HD")
t "explicit volume works"            0 run_inst "$V1" --dry-run
t "ambiguous volumes fail"           1 env PATH="$SHIM:$PATH" RAPHAELI_VOLUMES_DIR=$VOLDIR \
                                        "$DIST/tools/recovery-install.sh" --dry-run --target sequoia
assert_out "ambiguity prints usage"  "usage: recovery-install.sh /Volumes/Macintosh"

t "two candidates: explicit still ok" 0 run_inst "$V2" --dry-run

t "Sequoia target resolves package bundle" 0 run_inst "$V1" --target sequoia --dry-run
assert_out "Sequoia bundle selected" "$DIST/target/Sequoia/Raphaeli.kext"
t "unvalidated Tahoe target is refused" 1 run_inst "$V1" --target=tahoe --dry-run
assert_out "Tahoe validation gate reported" "tahoe_target_validated=no"
# The packaged script must not silently fall back to the repository firmware census.
# Remove the package copy while keeping the source-tree copy available.
mv "$DIST/tools/fw/stage.sh" "$WORK/stage.sh.missing"
t "packaged stage.sh is required" 1 run_inst "$V1" --target sequoia --dry-run
assert_out "missing packaged stage path reported" "$DIST/tools/fw/stage.sh"
mv "$WORK/stage.sh.missing" "$DIST/tools/fw/stage.sh"
KEXT_OVERRIDE=$DIST/kext/Raphaeli.kext
run_override() { RAPHAELI_KEXT=$KEXT_OVERRIDE run_inst "$@"; }
t "Tahoe override remains fail-closed" 1 run_override "$V1" --target tahoe --dry-run
assert_out "override validation gate reported" "tahoe_target_validated=no"
# An override changes only the bundle source; target preflight still runs.
cp "$DIST/tools/SOURCE.lock" "$WORK/SOURCE.lock.valid"
sed -i '' 's/^commit=.*/commit=invalid/' "$DIST/tools/SOURCE.lock"
t "Sequoia override still runs target preflight" 1 run_override "$V1" --target sequoia --dry-run
assert_out "Sequoia override preflight reported" "commit is not approved"
mv "$WORK/SOURCE.lock.valid" "$DIST/tools/SOURCE.lock"

# Target selection must install the matching executable, not merely print its path.
V_TARGET_SEQUOIA=$(newvol "Sequoia target HD")
t "Sequoia target apply succeeds" 0 run_inst "$V_TARGET_SEQUOIA" --target sequoia --apply
if grep -q '^fixture executable sequoia$' "$V_TARGET_SEQUOIA/Library/Extensions/Raphaeli.kext/Contents/MacOS/raphaeli"; then
  echo "ok    Sequoia executable marker installed"; pass=$((pass + 1))
else
  echo "FAIL  Sequoia executable marker installed"; fail=$((fail + 1))
fi
V_TARGET_TAHOE=$(newvol "Tahoe target HD")
t "unvalidated Tahoe apply is refused" 1 run_inst "$V_TARGET_TAHOE" --target tahoe --apply
rm -rf "$V_TARGET_SEQUOIA" "$V_TARGET_TAHOE"
printf 'boot-args\tnv_disable=1\n' > "$NVRAM_STATE"

rm -rf "$V2"                          # single candidate -> auto-detected
out=$(PATH="$SHIM:$PATH" RAPHAELI_VOLUMES_DIR=$VOLDIR "$DIST/tools/recovery-install.sh" --dry-run --target sequoia 2>&1)
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
assert_out "prints kext ditto"            "ditto *dist/target/Sequoia/Raphaeli.kext"
assert_out "prints chown root:wheel"      "chown -R root:wheel"
assert_out "prints packaged firmware staging" "$DIST/tools/fw/stage.sh"
assert_out "prints packaged stage destination" "$V1/Library/Raphaeli/firmware"
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

# ---- transaction rollback -----------------------------------------------------

# A failure after userspace and ICD publication must restore every original
# destination, including the partially written firmware staging tree.
V_FAIL=$(newvol "Failure HD")
mkdir -p "$V_FAIL/Library/Raphaeli/usr/lib" "$V_FAIL/Library/Raphaeli/firmware/amdgpu" \
  "$V_FAIL/usr/local/share/vulkan/icd.d" "$V_FAIL/Library/Extensions/Raphaeli.kext/Contents/MacOS"
printf 'original drm\n' > "$V_FAIL/Library/Raphaeli/usr/lib/libdrm.2.dylib"
printf 'original icd\n' > "$V_FAIL/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json"
printf 'original firmware\n' > "$V_FAIL/Library/Raphaeli/firmware/amdgpu/psp_13_0_11_toc.bin"
printf 'original kext\n' > "$V_FAIL/Library/Extensions/Raphaeli.kext/Contents/MacOS/raphaeli"
cp "$DIST/tools/fw/stage.sh" "$WORK/stage.sh.valid"
cat > "$DIST/tools/fw/stage.sh" <<'EOF'
#!/bin/sh
mkdir -p "$2/amdgpu" || exit 1
printf 'partial firmware\n' > "$2/amdgpu/partial.bin" || exit 1
exit 42
EOF
chmod +x "$DIST/tools/fw/stage.sh"
t "failed apply rolls back all filesystem writes" 1 run_inst "$V_FAIL" --target sequoia --apply
[[ $(cat "$V_FAIL/Library/Raphaeli/usr/lib/libdrm.2.dylib") == 'original drm' ]] && \
  { echo "ok    rollback preserves userspace"; pass=$((pass + 1)); } || \
  { echo "FAIL  rollback preserves userspace"; fail=$((fail + 1)); }
[[ $(cat "$V_FAIL/usr/local/share/vulkan/icd.d/radeon_icd.x86_64.json") == 'original icd' ]] && \
  { echo "ok    rollback preserves ICD"; pass=$((pass + 1)); } || \
  { echo "FAIL  rollback preserves ICD"; fail=$((fail + 1)); }
[[ $(cat "$V_FAIL/Library/Raphaeli/firmware/amdgpu/psp_13_0_11_toc.bin") == 'original firmware' && \
   ! -e "$V_FAIL/Library/Raphaeli/firmware/amdgpu/partial.bin" ]] && \
  { echo "ok    rollback preserves firmware"; pass=$((pass + 1)); } || \
  { echo "FAIL  rollback preserves firmware"; fail=$((fail + 1)); }
[[ $(cat "$V_FAIL/Library/Extensions/Raphaeli.kext/Contents/MacOS/raphaeli") == 'original kext' ]] && \
  { echo "ok    rollback preserves kext"; pass=$((pass + 1)); } || \
  { echo "FAIL  rollback preserves kext"; fail=$((fail + 1)); }
if find "$V_FAIL" -name '*.raphaeli-*' -print | grep -q .; then
  echo "FAIL  rollback leaves transaction artifacts"; fail=$((fail + 1))
else
  echo "ok    rollback removes transaction artifacts"; pass=$((pass + 1))
fi
mv "$WORK/stage.sh.valid" "$DIST/tools/fw/stage.sh"

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

for userspace_name in libdrm.2.dylib libdrm_amdgpu.1.dylib libvulkan_radeon.dylib; do
  mv "$DIST/usr/lib/$userspace_name" "$WORK/$userspace_name.missing"
  t "missing required userspace input: $userspace_name" 1 run_inst "$V1" --dry-run
  mv "$WORK/$userspace_name.missing" "$DIST/usr/lib/$userspace_name"
done
for firmware_name in \
  gc_11_0_1_pfp.bin gc_11_0_1_me.bin gc_11_0_1_rlc.bin \
  gc_11_0_1_mec.bin gc_11_0_1_imu.bin gc_11_0_1_mes1.bin \
  sdma_6_0_2.bin psp_13_0_11_toc.bin psp_13_0_11_ta.bin \
  vcn_4_0_2.bin dcn_3_1_4_dmcub.bin; do
  mv "$DIST/firmware/amdgpu/$firmware_name" "$WORK/$firmware_name.missing"
  t "missing required firmware input: $firmware_name" 1 run_inst "$V1" --dry-run
  mv "$WORK/$firmware_name.missing" "$DIST/firmware/amdgpu/$firmware_name"
done

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
      RAPHAELI_VOLUMES_DIR=$VOLDIR "$DIST/tools/recovery-install.sh" "$V1" --dry-run --target sequoia 2>&1)
if [[ $? == 1 && $out == *"unexpected bundle id 'com.other.kext'"* ]]; then
  echo "ok    wrong bundle id rejected"; pass=$((pass + 1))
else
  echo "FAIL  wrong bundle id rejected"; echo "$out" | sed 's/^/      /'; fail=$((fail + 1))
fi

echo
echo "passed=$pass failed=$fail"
exit $((fail > 0))
