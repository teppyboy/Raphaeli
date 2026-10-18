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
assert_grep 'OUT=.*out-disp' "$ROOT/scripts/link.sh" "legacy link output remains out-disp"
assert_grep 'OUT_TARGET=.*OUT' "$ROOT/scripts/link.sh" "legacy bundle stays at requested output root"
assert_grep 'OUT_TARGET="\$OUT/target/\$name"' "$ROOT/scripts/link.sh" "target bundle uses isolated output path"
assert_grep 'OUT_TARGET="\$OUT"' "$ROOT/scripts/link.sh" "legacy bundle uses output root"
assert_grep 'LOG_DIR=.*OUT_TARGET' "$ROOT/scripts/link.sh" "link logs live under target output"
assert_grep 'missing matching Tahoe ABI header' "$ROOT/scripts/build.sh" "build rejects Tahoe before compilation"
assert_grep 'missing matching Tahoe ABI header' "$ROOT/scripts/rt.sh" "rt rejects Tahoe before compilation"
assert_grep 'missing matching Tahoe ABI header' "$ROOT/scripts/link.sh" "link rejects Tahoe before linking"

# Duplicate selectors reject before any build or link work.
for script in build.sh rt.sh link.sh; do
  if "$ROOT/scripts/$script" --target sequoia --target tahoe >"$TMP/$script.duplicate.log" 2>&1; then
    bad "$script rejects duplicate --target"
  else
    grep -Fq -- '--target specified more than once' "$TMP/$script.duplicate.log" && ok "$script rejects duplicate --target" || bad "$script rejects duplicate --target"
  fi
done

# --target all preflights Tahoe before Sequoia work, so a missing ABI cannot leave partial output.
for script in build.sh rt.sh link.sh; do
  rm -rf "$TMP/$script.all-output"
  mkdir -p "$TMP/$script.all-output"
  if GPU_SRC_ROOT="$TMP/$script.all-output" "$ROOT/scripts/$script" --target all >"$TMP/$script.all.log" 2>&1; then
    bad "$script rejects incomplete all"
  else
    grep -Fq -- 'missing matching Tahoe ABI header' "$TMP/$script.all.log" && ok "$script rejects incomplete all" || bad "$script rejects incomplete all"
    [ ! -e "$TMP/$script.all-output/obj" ] && [ ! -e "$TMP/$script.all-output/out" ] && ok "$script all leaves no partial artifacts" || bad "$script all leaves no partial artifacts"
  fi
done

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
