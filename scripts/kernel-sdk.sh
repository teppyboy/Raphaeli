# Shared kernel SDK selection. Source from compiler/linker wrappers.
# MAC_KERNEL_SDK may point at a checked-out MacKernelSDK; otherwise use the
# pinned research copy when present, never silently select an active SDK.
KERNEL_SDK_ROOT=${MAC_KERNEL_SDK:-}
if [ -z "$KERNEL_SDK_ROOT" ]; then
    KERNEL_SDK_ROOT=${GPU_SRC_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/research/MacKernelSDK
fi
if [ -d "$KERNEL_SDK_ROOT/Headers" ] && [ -d "$KERNEL_SDK_ROOT/Library" ]; then
    KERNEL_SDK_HEADERS=$KERNEL_SDK_ROOT/Headers
    KERNEL_SDK_KMOD_LIB=$KERNEL_SDK_ROOT/Library/x86_64
    KERNEL_SDK_KMOD_CPP_LIB=$KERNEL_SDK_ROOT/Library/universal
    KERNEL_SDK_PINNED=1
else
    echo "WARNING: MacKernelSDK absent at $KERNEL_SDK_ROOT; falling back to active xcrun macosx SDK" >&2
    KERNEL_SDK_PINNED=0
    KERNEL_SDK_ROOT=$(xcrun --sdk macosx --show-sdk-path)
    KERNEL_SDK_HEADERS=$KERNEL_SDK_ROOT/System/Library/Frameworks/Kernel.framework/Headers
    KERNEL_SDK_KMOD_LIB=$KERNEL_SDK_ROOT/usr/lib
    KERNEL_SDK_KMOD_CPP_LIB=$KERNEL_SDK_ROOT/usr/lib
fi
KERNEL_SDK_INCLUDE="-I$KERNEL_SDK_HEADERS"
KERNEL_SDK_LINK="-L$KERNEL_SDK_KMOD_CPP_LIB -L$KERNEL_SDK_KMOD_LIB"
