#!/bin/bash
# kpi-init.sh: make sure kpi/ + deps/ submodules exist and carry our patches.
# Fresh machine: git clone --recurse-submodules --shallow-submodules --depth 1 <repo>
# (or: git submodule update --init --depth 1) - pins fetch fine from upstream.
# Idempotent - run before any build; cheap when already applied.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git -c protocol.file.allow=always submodule update --init kpi/drm-kmod deps/metal2vulkan deps/libdrm

# freebsd-src: shallow submodule; init if missing
if [ ! -f deps/mesa/src/gallium/frontends/drm ] && [ ! -d deps/mesa/src ]; then
    git -c protocol.file.allow=always submodule update --init deps/mesa
fi

if [ ! -f kpi/freebsd-src/sys/compat/linuxkpi/common/include/linux/kobject.h ]; then
    git -c protocol.file.allow=always submodule update --init kpi/freebsd-src
fi

# mesa + libdrm carry macOS build patches; apply when not yet applied
for p in mesa-macos libdrm-macos; do
    [ -f "$ROOT/patches/$p.patch" ] || continue
    tree="deps/$(echo "$p" | cut -d- -f1)"
    if git -C "$tree" apply --check "$ROOT/patches/$p.patch" 2>/dev/null; then
        git -C "$tree" apply "$ROOT/patches/$p.patch"
        echo "kpi-init: applied patches/$p.patch"
    fi
done

# drm-kmod minor-release guard (drm_minor_alloc_release): kpi/ is pinned upstream + patches; same apply-when-unapplied rule
p=drm-kmod-minor-release
if [ -f "$ROOT/patches/$p.patch" ]; then
    if git -C kpi/drm-kmod apply --check "$ROOT/patches/$p.patch" 2>/dev/null; then
        git -C kpi/drm-kmod apply "$ROOT/patches/$p.patch"
        echo "kpi-init: applied patches/$p.patch"
    fi
fi
echo "kpi-init: ok"
