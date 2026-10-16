#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/inputs with spaces"
INPUT="$WORK/inputs with spaces"
printf 'KC\n' > "$INPUT/BootKernelExtensions.kc"
printf 'binary\n' > "$INPUT/Raphaeli"
printf 'plist\n' > "$INPUT/Info.plist"
cat > "$WORK/KextInject" <<'EOF'
#!/bin/bash
shift
while [ "$#" -gt 0 ]; do
    case "$MODE" in
        success|quirks|crash) printf '[OK] %s injected - Success (vtest)\n' "$1" ;;
        failure) printf '[FAIL] %s injected - Invalid Parameter\n' "$1" ;;
        dependency) if [ "$1" = "$DEPENDENCY" ]; then
            printf '[FAIL] %s injected - Invalid Parameter\n' "$1"
        else
            printf '[OK] %s injected - Success (vtest)\n' "$1"
        fi ;;
        unresolved) printf '[OK] %s injected - Success (vtest)\nOCAK: Symbol _bad has 0-value\n' "$1" ;;
        *) : ;;
    esac
    shift 2
done
if [ "$MODE" != incomplete ]; then echo '[OK] Prelink inject complete success'; fi
case "$MODE" in quirks) exit 255 ;; crash) exit 134 ;; esac
EOF
chmod +x "$WORK/KextInject"
check() {
    local mode=$1 want=$2 got=0
    MODE=$mode /bin/bash "$HERE/check-oc-injection.sh" "$WORK/KextInject" \
        "$INPUT/BootKernelExtensions.kc" "$WORK/$mode" "$INPUT/Raphaeli" "$INPUT/Info.plist" || got=$?
    [ "$got" = "$want" ] || { echo "FAIL: $mode exit=$got expected=$want"; exit 1; }
}
check success 0
check quirks 0
check failure 1
check missing 1
check incomplete 1
check crash 1
check unresolved 1
printf 'dependency\n' > "$INPUT/Dependency"
if MODE=dependency DEPENDENCY="$INPUT/Dependency" /bin/bash "$HERE/check-oc-injection.sh" \
    "$WORK/KextInject" "$INPUT/BootKernelExtensions.kc" "$WORK/failed-dependency" \
    "$INPUT/Dependency" "$INPUT/Info.plist" "$INPUT/Raphaeli" "$INPUT/Info.plist"; then
    echo 'FAIL: accepted failed dependency with successful Raphaeli'; exit 1
fi
if MODE=success /bin/bash "$HERE/check-oc-injection.sh" "$WORK/KextInject" \
    "$INPUT/BootKernelExtensions.kc" "$WORK/success" "$INPUT/Raphaeli" "$INPUT/Info.plist"; then
    echo 'FAIL: reused scratch directory'; exit 1
fi
(cd "$WORK" && MODE=success /bin/bash "$HERE/check-oc-injection.sh" ./KextInject \
    'inputs with spaces/BootKernelExtensions.kc' relative \
    'inputs with spaces/Raphaeli' 'inputs with spaces/Info.plist')
echo 'PASS: per-binary injection results, unrelated quirk errors, absent success, incomplete run, crash, scratch protection, relative/spaced paths'
