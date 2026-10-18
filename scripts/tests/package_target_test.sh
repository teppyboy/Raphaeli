#!/bin/bash
# Fixture test for target-specific package layout. Uses fake macOS packaging tools.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-package.XXXXXX")
for path in "$ROOT/out/target" "$ROOT/out/usr/lib" "$ROOT/firmware/amdgpu" "$ROOT/dist"; do
  if [ -e "$path" ]; then
    mv "$path" "$TMP/$(basename "$path").original"
  fi
done
cleanup() {
  rm -rf "$ROOT/out/target" "$ROOT/out/usr/lib" "$ROOT/firmware/amdgpu" "$ROOT/dist"
  [ -e "$TMP/target.original" ] && mv "$TMP/target.original" "$ROOT/out/target"
  [ -e "$TMP/lib.original" ] && mkdir -p "$ROOT/out/usr" && mv "$TMP/lib.original" "$ROOT/out/usr/lib"
  [ -e "$TMP/amdgpu.original" ] && mkdir -p "$ROOT/firmware" && mv "$TMP/amdgpu.original" "$ROOT/firmware/amdgpu"
  [ -e "$TMP/dist.original" ] && mv "$TMP/dist.original" "$ROOT/dist"
  rm -rf "$TMP"
}
trap cleanup EXIT

fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }

# Minimal command shims keep this fixture host-portable while exercising package.sh.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/ditto" <<'EOF'
#!/bin/bash
cp -R "$1" "$2"
EOF
cat > "$TMP/bin/plutil" <<'EOF'
#!/bin/bash
case "$1" in
  -replace) exit 0 ;;
  *) exec /usr/bin/plutil "$@" ;;
esac
EOF
cat > "$TMP/bin/pkgbuild" <<'EOF'
#!/bin/bash
touch "${!#}"
EOF
cat > "$TMP/bin/productbuild" <<'EOF'
#!/bin/bash
touch "${!#}"
EOF
cat > "$TMP/bin/install_name_tool" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 755 "$TMP/bin"/*

mk_kext() {
  local path=$1 marker=$2
  mkdir -p "$path/Contents/MacOS"
  printf 'marker=%s\n' "$marker" > "$path/Contents/MacOS/Raphaeli"
  chmod 755 "$path/Contents/MacOS/Raphaeli"
  cat > "$path/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>me.tretrauit.raphaeli</string>
<key>CFBundleExecutable</key><string>Raphaeli</string>
<key>IOKitPersonalities</key><dict>
<key>Raphaeli780M</key><dict><key>IOPCIPrimaryMatch</key><string>0x000015bf&amp;0xffffffff</string></dict>
</dict>
</dict></plist>
EOF
}

mkdir -p "$ROOT/out/target/Sequoia" "$ROOT/out/target/Tahoe" "$ROOT/out/usr/lib" "$ROOT/firmware/amdgpu"
mk_kext "$ROOT/out/target/Sequoia/Raphaeli.kext" sequoia
mk_kext "$ROOT/out/target/Tahoe/Raphaeli.kext" tahoe
: > "$ROOT/out/usr/lib/libdrm.2.dylib"
: > "$ROOT/out/usr/lib/libdrm_amdgpu.1.dylib"
: > "$ROOT/out/usr/lib/libvulkan_radeon.dylib"
: > "$ROOT/out/usr/lib/radeon_icd.x86_64.json"
: > "$ROOT/firmware/amdgpu/test.bin"
for firmware_name in \
  gc_11_0_1_pfp.bin gc_11_0_1_me.bin gc_11_0_1_rlc.bin \
  gc_11_0_1_mec.bin gc_11_0_1_imu.bin gc_11_0_1_mes1.bin \
  sdma_6_0_2.bin psp_13_0_11_toc.bin psp_13_0_11_ta.bin \
  vcn_4_0_2.bin dcn_3_1_4_dmcub.bin; do
  : > "$ROOT/firmware/amdgpu/$firmware_name"
done

run_package() {
  local selector=$1
  (cd "$ROOT" && PATH="$TMP/bin:$PATH" ./scripts/package.sh --target "$selector" >/dev/null)
}
run_package_args() {
  (cd "$ROOT" && PATH="$TMP/bin:$PATH" ./scripts/package.sh "$@" >/dev/null)
}
assert_package_fails() {
  local name=${!#}
  set -- "${@:1:$(($# - 1))}"
  if run_package_args "$@"; then bad "$name"; else ok "$name"; fi
}
archive_path() {
  find "$ROOT/dist" -name '*.zip' -type f -print -quit
}
assert_archive_has() {
  local archive=$1 expected=$2 listing
  listing=$(unzip -Z1 "$archive")
  printf '%s\n' "$listing" | grep -Fxq "$expected" && ok "$3" || { bad "$3"; printf '%s\n' "$listing"; }
}
assert_archive_text() {
  local archive=$1 path=$2 expected=$3 text
  text=$(unzip -p "$archive" "$path")
  printf '%s\n' "$text" | grep -Fq -- "$expected" && ok "$4" || { bad "$4"; printf '%s\n' "$text"; }
}
assert_archive_lacks_text() {
  local archive=$1 path=$2 unexpected=$3 text
  text=$(unzip -p "$archive" "$path")
  printf '%s\n' "$text" | grep -Fq -- "$unexpected" && bad "$4" || ok "$4"
}
assert_archive_executable_marker() {
  local archive=$1 path=$2 expected=$3 text
  text=$(unzip -p "$archive" "$path")
  [ "$text" = "$expected" ] && ok "$4" || { bad "$4"; printf '%s\n' "$text"; }
}

# Release packaging is target-aware: parser accepts version + both target spellings,
# normalizes case, rejects duplicate/invalid selectors, and requires --target.
grep -Fq -- 'target is required for release packaging' "$ROOT/scripts/package.sh" && ok "source target requirement marker" || bad "source target requirement marker"
grep -Fq -- 'INSTALL_TARGET' "$ROOT/scripts/package.sh" && ok "source layout marker" || bad "source layout marker"
grep -Fq -- 'INSTALL.md' "$ROOT/scripts/package.sh" && ok "source install marker" || bad "source install marker"
run_package_args 1.2 --target sequoia && ok "version + target accepted" || bad "version + target accepted"
run_package_args 1.3 --target=SEQUOIA && ok "equals target case normalized" || bad "equals target case normalized"
run_package_args 1.4 --target && bad "missing target value rejected" || ok "missing target value rejected"
run_package_args 1.5 --target= && bad "empty equals target rejected" || ok "empty equals target rejected"
run_package_args 1.6 && bad "missing target rejected" || ok "missing target rejected"
run_package_args 1.7 --target sequoia --target tahoe && bad "duplicate target rejected" || ok "duplicate target rejected"
run_package_args 1.8 --target invalid && bad "invalid target rejected" || ok "invalid target rejected"

for selector in sequoia tahoe all; do
  rm -rf "$ROOT/dist"
  if run_package "$selector"; then ok "$selector selector accepted"; else
    case "$selector" in tahoe|all) ok "$selector selector fail-closed" ;; *) bad "$selector selector accepted"; continue ;; esac
    continue
  fi
  archive=$(archive_path)
  [ -n "$archive" ] || { bad "$selector archive produced"; continue; }
  assert_archive_has "$archive" "$(basename "${archive%.zip}")/usr/lib/libvulkan_radeon.dylib" "$selector shared userspace staged"
  assert_archive_has "$archive" "$(basename "${archive%.zip}")/firmware/amdgpu/test.bin" "$selector shared firmware staged"
  install_path="$(basename "${archive%.zip}")/INSTALL.md"
  assert_archive_has "$archive" "$install_path" "$selector INSTALL.md staged"
  case "$selector" in
    sequoia)
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Sequoia/Raphaeli.kext/Contents/MacOS/Raphaeli" "sequoia kext layout"
      assert_archive_executable_marker "$archive" "$(basename "${archive%.zip}")/target/Sequoia/Raphaeli.kext/Contents/MacOS/Raphaeli" "marker=sequoia" "sequoia executable marker"
      assert_archive_text "$archive" "$install_path" "--target sequoia" "sequoia INSTALL.md target command"
      assert_archive_text "$archive" "$install_path" "target/Sequoia/Raphaeli.kext" "sequoia INSTALL.md direct path"
      assert_archive_lacks_text "$archive" "$install_path" "target/Tahoe/Raphaeli.kext" "sequoia INSTALL.md excludes tahoe path"
      ! unzip -Z1 "$archive" | grep -q '/target/Tahoe/' && ok "sequoia excludes tahoe" || bad "sequoia excludes tahoe"
      ;;
    tahoe)
      # Tahoe packaging must remain blocked while SOURCE.lock is unvalidated.
      bad "tahoe selector accepted"
      continue
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Tahoe/Raphaeli.kext/Contents/MacOS/Raphaeli" "tahoe kext layout"
      assert_archive_executable_marker "$archive" "$(basename "${archive%.zip}")/target/Tahoe/Raphaeli.kext/Contents/MacOS/Raphaeli" "marker=tahoe" "tahoe executable marker"
      assert_archive_text "$archive" "$install_path" "--target tahoe" "tahoe INSTALL.md target command"
      assert_archive_text "$archive" "$install_path" "target/Tahoe/Raphaeli.kext" "tahoe INSTALL.md direct path"
      assert_archive_lacks_text "$archive" "$install_path" "target/Sequoia/Raphaeli.kext" "tahoe INSTALL.md excludes sequoia path"
      ! unzip -Z1 "$archive" | grep -q '/target/Sequoia/' && ok "tahoe excludes sequoia" || bad "tahoe excludes sequoia"
      ;;
    all)
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Sequoia/Raphaeli.kext/Contents/MacOS/Raphaeli" "all sequoia kext layout"
      assert_archive_executable_marker "$archive" "$(basename "${archive%.zip}")/target/Sequoia/Raphaeli.kext/Contents/MacOS/Raphaeli" "marker=sequoia" "all sequoia executable marker"
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Tahoe/Raphaeli.kext/Contents/MacOS/Raphaeli" "all tahoe kext layout"
      assert_archive_executable_marker "$archive" "$(basename "${archive%.zip}")/target/Tahoe/Raphaeli.kext/Contents/MacOS/Raphaeli" "marker=tahoe" "all tahoe executable marker"
      assert_archive_text "$archive" "$install_path" "--target sequoia" "all INSTALL.md sequoia command"
      assert_archive_text "$archive" "$install_path" "--target tahoe" "all INSTALL.md tahoe command"
      assert_archive_text "$archive" "$install_path" "target/Sequoia/Raphaeli.kext" "all INSTALL.md sequoia direct path"
      assert_archive_text "$archive" "$install_path" "target/Tahoe/Raphaeli.kext" "all INSTALL.md tahoe direct path"
      ;;
  esac
done

# A stale build artifact with a vendor-wide PCI personality must never enter a release.
plist="$ROOT/out/target/Sequoia/Raphaeli.kext/Contents/Info.plist"
cp "$plist" "$TMP/Sequoia.Info.plist.original"
cat > "$plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>me.tretrauit.raphaeli</string>
<key>CFBundleExecutable</key><string>Raphaeli</string>
<key>IOKitPersonalities</key><dict>
<key>StaleVendorWide</key><dict><key>IOPCIPrimaryMatch</key><string>0x00001002&amp;0x0000ffff</string></dict>
</dict>
</dict></plist>
EOF
assert_package_fails --target sequoia "stale vendor-wide Info.plist rejected"
mv "$TMP/Sequoia.Info.plist.original" "$plist"

# Every required input failure must be explicit, including each target bundle
# and each shared userspace/firmware input.
for missing_target in Sequoia Tahoe; do
  mv "$ROOT/out/target/$missing_target" "$TMP/$missing_target.missing"
  assert_package_fails --target all "missing $missing_target input rejected"
  mv "$TMP/$missing_target.missing" "$ROOT/out/target/$missing_target"
done
for userspace_name in libdrm.2.dylib libdrm_amdgpu.1.dylib libvulkan_radeon.dylib; do
  mv "$ROOT/out/usr/lib/$userspace_name" "$TMP/$userspace_name.missing"
  assert_package_fails --target sequoia "missing userspace input: $userspace_name"
  mv "$TMP/$userspace_name.missing" "$ROOT/out/usr/lib/$userspace_name"
done
for firmware_name in \
  gc_11_0_1_pfp.bin gc_11_0_1_me.bin gc_11_0_1_rlc.bin \
  gc_11_0_1_mec.bin gc_11_0_1_imu.bin gc_11_0_1_mes1.bin \
  sdma_6_0_2.bin psp_13_0_11_toc.bin psp_13_0_11_ta.bin \
  vcn_4_0_2.bin dcn_3_1_4_dmcub.bin; do
  mv "$ROOT/firmware/amdgpu/$firmware_name" "$TMP/$firmware_name.missing"
  assert_package_fails --target sequoia "missing firmware input: $firmware_name"
  mv "$TMP/$firmware_name.missing" "$ROOT/firmware/amdgpu/$firmware_name"
done

echo "passed=$((fail == 0 ? 1 : 0)) failed=$fail"
exit "$fail"
