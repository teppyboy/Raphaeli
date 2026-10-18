#!/bin/bash
# Static and mocked compiler checks for target-aware build routing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/raphaeli-target-build.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fail=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }
assert_grep() {
  grep -Eq -- "$1" "$2" && ok "$3" || bad "$3"
}

assert_grep '--target' "$ROOT/scripts/build.sh" "build accepts target selector"
assert_grep '--target' "$ROOT/scripts/rt.sh" "rt accepts target selector"
assert_grep '--target' "$ROOT/scripts/link.sh" "link accepts target selector"
assert_grep 'obj/target|OBJ_ROOT' "$ROOT/scripts/build.sh" "build isolates target objects"
assert_grep 'obj/target|OBJ_ROOT' "$ROOT/scripts/rt.sh" "rt isolates target objects"
assert_grep 'out/target|OUT.*target' "$ROOT/scripts/link.sh" "link isolates target bundles"
assert_grep 'NM_TAHOE' "$ROOT/scripts/ccxx.sh" "Tahoe compiler define exists"

# Fake xcrun captures the final compiler command without requiring a KDK.
mkdir -p "$TMP/bin" "$TMP/obj"
cat > "$TMP/bin/xcrun" <<'EOF'
#!/bin/bash
if [ "$1" = --sdk ]; then echo /sdk; exit 0; fi
printf '%s\n' "$*" >> "${NMX_COMMAND_LOG:?}"
exit 0
EOF
chmod 755 "$TMP/bin/xcrun"
: > "$TMP/nmx_accel.cpp"
for target in sequoia tahoe; do
  : > "$TMP/commands-$target.log"
  if PATH="$TMP/bin:$PATH" NMX_COMMAND_LOG="$TMP/commands-$target.log" NMX_TARGET="$target" NMX_OBJ="$TMP/obj/$target.o" \
      GPU_SRC_ROOT="$ROOT" "$ROOT/scripts/ccxx.sh" "$TMP/nmx_accel.cpp"; then
    if [ "$target" = tahoe ]; then
      grep -Fq -- '-DNM_TAHOE' "$TMP/commands-$target.log" && ok "Tahoe command has NM_TAHOE" || bad "Tahoe command has NM_TAHOE"
      ! grep -Fq -- '-DNM_TAHOE' "$TMP/commands-sequoia.log" && ok "Sequoia command omits NM_TAHOE" || bad "Sequoia command omits NM_TAHOE"
    fi
  else
    bad "$target compiler wrapper invocation"
  fi
done

echo "passed=$((fail == 0 ? 1 : 0)) failed=$fail"
exit "$fail"
