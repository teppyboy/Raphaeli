#!/bin/bash
# Validate target metadata before selecting or packaging an OS-specific kext.
# Bash 3.2-compatible; no arrays.
set -e
TARGET=$1
LOCK=$2
[ -n "$TARGET" ] && [ -n "$LOCK" ] || { echo "target-preflight: target and SOURCE.lock required" >&2; exit 1; }
[ -f "$LOCK" ] || { echo "target-preflight: missing SOURCE.lock: $LOCK" >&2; exit 1; }
get_value() { sed -n "s/^$1=//p" "$LOCK" | head -n 1; }
repository=$(get_value repository)
commit=$(get_value commit)
source_path=$(get_value source_path)
[ "$repository" = "https://github.com/nullmoth/nvidia-macos-driver.git" ] || { echo "target-preflight: SOURCE.lock repository is not approved" >&2; exit 1; }
[ "$commit" = "637282334617d27bccf8aa2448497c0f19465dc8" ] || { echo "target-preflight: SOURCE.lock commit is not approved" >&2; exit 1; }
[ "$source_path" = "kexts/NVRM/accel" ] || { echo "target-preflight: SOURCE.lock source_path is not approved" >&2; exit 1; }
for key in tahoe_forwarding_provenance target_audit tahoe_target_validated; do
  value=$(get_value "$key")
  [ -n "$value" ] || { echo "target-preflight: SOURCE.lock missing $key" >&2; exit 1; }
done
if [ "$TARGET" = tahoe ]; then
  validated=$(get_value tahoe_target_validated)
  [ "$validated" = yes ] || { echo "target-preflight: refusing Tahoe: SOURCE.lock marks tahoe_target_validated=$validated" >&2; exit 1; }
fi
