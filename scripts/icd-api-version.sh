#!/bin/bash
# icd-api-version.sh: source this file, then call icd_api_version <manifest>. Prints the one api_version
# of a generated Vulkan ICD manifest, or returns 1 with a diagnostic on stderr. Uses only plutil, grep,
# and wc, which RecoveryOS ships; bash 3.2 compatible.
icd_api_version() {
    local manifest=$1 keys v
    [ -f "$manifest" ] || { echo "icd-api-version: no manifest $manifest" >&2; return 1; }
    # plutil keeps the last of duplicate keys, so count the key first to reject ambiguous manifests.
    keys=$(grep -o '"api_version"' "$manifest" | wc -l | tr -d ' ')
    [ "$keys" = 1 ] || { echo "icd-api-version: $manifest has $keys api_version keys, want 1" >&2; return 1; }
    v=$(plutil -extract ICD.api_version raw "$manifest" 2>/dev/null) || {
        echo "icd-api-version: $manifest has no readable ICD.api_version" >&2; return 1; }
    printf '%s\n' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
        echo "icd-api-version: $manifest api_version '$v' is not MAJOR.MINOR.PATCH" >&2; return 1; }
    printf '%s\n' "$v"
}
