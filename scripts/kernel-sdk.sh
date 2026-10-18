# Shared kernel SDK selection. Source from compiler/linker wrappers.
# MAC_KERNEL_SDK may point at a checked-out MacKernelSDK, but both the default
# checkout and override must be the pinned revision below. Never fall back to an
# active xcrun SDK: its private kernel ABI is not interchangeable.
KERNEL_SDK_COMMIT=3f750085caa17ec3a7880f11c11bf4f48cd6a164
KERNEL_SDK_ROOT=${MAC_KERNEL_SDK:-}
if [ -z "$KERNEL_SDK_ROOT" ]; then
    KERNEL_SDK_ROOT=${GPU_SRC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/research/MacKernelSDK
fi
if [ ! -d "$KERNEL_SDK_ROOT" ]; then
    echo "ERROR: MacKernelSDK missing at $KERNEL_SDK_ROOT; refusing active SDK fallback" >&2
    return 1 2>/dev/null || exit 1
fi
KERNEL_SDK_REVISION=$(git -C "$KERNEL_SDK_ROOT" rev-parse HEAD 2>/dev/null) || {
    echo "ERROR: MacKernelSDK at $KERNEL_SDK_ROOT is not a Git checkout at pinned commit $KERNEL_SDK_COMMIT" >&2
    return 1 2>/dev/null || exit 1
}
if [ "$KERNEL_SDK_REVISION" != "$KERNEL_SDK_COMMIT" ]; then
    echo "ERROR: MacKernelSDK at $KERNEL_SDK_ROOT is $KERNEL_SDK_REVISION; required $KERNEL_SDK_COMMIT" >&2
    return 1 2>/dev/null || exit 1
fi
if [ ! -d "$KERNEL_SDK_ROOT/Headers" ] || \
   [ ! -d "$KERNEL_SDK_ROOT/Library/x86_64" ] || \
   [ ! -d "$KERNEL_SDK_ROOT/Library/universal" ]; then
    echo "ERROR: MacKernelSDK at $KERNEL_SDK_ROOT lacks pinned Headers/Library directories" >&2
    return 1 2>/dev/null || exit 1
fi
KERNEL_SDK_HEADERS=$KERNEL_SDK_ROOT/Headers
KERNEL_SDK_KMOD_LIB=$KERNEL_SDK_ROOT/Library/x86_64
KERNEL_SDK_KMOD_CPP_LIB=$KERNEL_SDK_ROOT/Library/universal
KERNEL_SDK_PINNED=1
KERNEL_SDK_INCLUDE="-I$KERNEL_SDK_HEADERS"
KERNEL_SDK_LINK="-L$KERNEL_SDK_KMOD_CPP_LIB -L$KERNEL_SDK_KMOD_LIB"
