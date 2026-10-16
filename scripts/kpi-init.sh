#!/bin/bash
# kpi-init.sh: make sure kpi/ submodules exist and carry our patches.
# Idempotent - run before any build; cheap when already applied.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

git -c protocol.file.allow=always submodule update --init kpi/drm-kmod

# freebsd-src: shallow submodule; init if missing
if [ ! -f kpi/freebsd-src/sys/compat/linuxkpi/common/include/linux/kobject.h ]; then
    git -c protocol.file.allow=always submodule update --init kpi/freebsd-src
fi

echo "kpi-init: ok"
