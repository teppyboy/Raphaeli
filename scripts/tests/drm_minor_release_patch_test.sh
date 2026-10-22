#!/bin/bash
# drm_minor_release_patch_test.sh: host test for patches/drm-kmod-minor-release.patch. Fixture only: applies the
# patch to the pinned drm_minor_alloc_release text, checks the kpi-init.sh apply rule is idempotent, and checks
# that the patch guards put_device(minor->kdev) without touching the alias teardown. No kpi/ tree required.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
PATCH="$ROOT/patches/drm-kmod-minor-release.patch"
INIT="$ROOT/scripts/kpi-init.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/drm-minor-release.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail=0
ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=$((fail + 1)); }

# fixture: pinned drm_minor_alloc_release (kpi/drm-kmod c16de0f9fa), as a git tree so `git apply` behaves as kpi-init does
mkdir -p "$T/drivers/gpu/drm"
cat > "$T/drivers/gpu/drm/drm_drv.c" <<'EOF'
static void drm_minor_alloc_release(struct drm_device *dev, void *data)
{
	struct drm_minor *minor = data;

	WARN_ON(dev != minor->dev);

#ifdef __FreeBSD__
	/* Destroy the /dev/dri alias, also on a failed probe's drm_dev_put(). */
	drm_dev_alias_free(minor);
#endif

	put_device(minor->kdev);

	xa_erase(drm_minor_get_xa(minor->type), minor->index);
}
EOF
git -C "$T" init -q && git -C "$T" add -A && git -C "$T" -c user.email=t@t -c user.name=t commit -qm fixture

if [ -f "$PATCH" ]; then ok "patch file present"; else bad "patch file present"; fi

# apply rule from kpi-init.sh: apply only when --check passes, so a second run is a no-op
if git -C "$T" apply --check "$PATCH" 2>/dev/null; then
    git -C "$T" apply "$PATCH" && ok "patch applies to pinned fixture"
else
    bad "patch applies to pinned fixture"
fi
if git -C "$T" apply --check "$PATCH" 2>/dev/null; then
    bad "second apply is skipped (patch already applied)"
else
    ok "second apply is skipped (patch already applied)"
fi
if git -C "$T" apply --check -R "$PATCH" 2>/dev/null; then ok "applied patch reverses cleanly"; else bad "applied patch reverses cleanly"; fi

F="$T/drivers/gpu/drm/drm_drv.c"
grep -Fq '	if (!IS_ERR_OR_NULL(minor->kdev))' "$F" && grep -Fq '		put_device(minor->kdev);' "$F" \
    && ok "put_device(minor->kdev) guarded by IS_ERR_OR_NULL" || bad "put_device(minor->kdev) guarded by IS_ERR_OR_NULL"
grep -Fq '	drm_dev_alias_free(minor);' "$F" && ok "alias teardown unchanged" || bad "alias teardown unchanged"
grep -Fq 'xa_erase(drm_minor_get_xa(minor->type), minor->index);' "$F" && ok "xa_erase unchanged" || bad "xa_erase unchanged"

# kpi-init.sh wiring: patch name matches, uses kpi/drm-kmod, gated on --check
if grep -Fq 'p=drm-kmod-minor-release' "$INIT" && grep -Fq 'git -C kpi/drm-kmod apply --check "$ROOT/patches/$p.patch"' "$INIT"; then
    ok "kpi-init.sh applies drm-kmod-minor-release idempotently"
else
    bad "kpi-init.sh applies drm-kmod-minor-release idempotently"
fi
bash -n "$INIT" && ok "kpi-init.sh syntax" || bad "kpi-init.sh syntax"

echo
if [ "$fail" != 0 ]; then echo "drm_minor_release_patch_test: $fail failed"; exit 1; fi
echo "drm_minor_release_patch_test: all passed"
