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
exit 0
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
  cat > "$path/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>me.tretrauit.raphaeli.$marker</string></dict></plist>
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

run_package() {
  local selector=$1
  (cd "$ROOT" && PATH="$TMP/bin:$PATH" ./scripts/package.sh --target "$selector" >/dev/null)
}
archive_path() {
  find "$ROOT/dist" -name '*.zip' -type f -print -quit
}
assert_archive_has() {
  local archive=$1 expected=$2 listing
  listing=$(unzip -Z1 "$archive")
  printf '%s\n' "$listing" | grep -Fxq "$expected" && ok "$3" || { bad "$3"; printf '%s\n' "$listing"; }
}

for selector in sequoia tahoe all; do
  rm -rf "$ROOT/dist"
  if run_package "$selector"; then ok "$selector selector accepted"; else bad "$selector selector accepted"; continue; fi
  archive=$(archive_path)
  [ -n "$archive" ] || { bad "$selector archive produced"; continue; }
  assert_archive_has "$archive" "$(basename "${archive%.zip}")/usr/lib/libvulkan_radeon.dylib" "$selector shared userspace staged"
  assert_archive_has "$archive" "$(basename "${archive%.zip}")/firmware/amdgpu/test.bin" "$selector shared firmware staged"
  case "$selector" in
    sequoia)
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Sequoia/Raphaeli.kext/Contents/MacOS/Raphaeli" "sequoia kext layout"
      ! unzip -Z1 "$archive" | grep -q '/target/Tahoe/' && ok "sequoia excludes tahoe" || bad "sequoia excludes tahoe"
      ;;
    tahoe)
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Tahoe/Raphaeli.kext/Contents/MacOS/Raphaeli" "tahoe kext layout"
      ! unzip -Z1 "$archive" | grep -q '/target/Sequoia/' && ok "tahoe excludes sequoia" || bad "tahoe excludes sequoia"
      ;;
    all)
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Sequoia/Raphaeli.kext/Contents/MacOS/Raphaeli" "all sequoia kext layout"
      assert_archive_has "$archive" "$(basename "${archive%.zip}")/target/Tahoe/Raphaeli.kext/Contents/MacOS/Raphaeli" "all tahoe kext layout"
      ;;
  esac
done

echo "passed=$((fail == 0 ? 1 : 0)) failed=$fail"
exit "$fail"
