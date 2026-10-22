#!/usr/bin/env python3
"""Static contract for DRM node opens: the vnode reaches LinuxKPI's open, and failed opens release their refs."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CDEV = (ROOT / "Raphaeli/Override/src/nmx_linux_cdev.c").read_text()
COMPAT = (ROOT / "Raphaeli/Override/src/linux_compat.c").read_text()


def strip_comments(text):
    return re.sub(r"/\*.*?\*/", "", text, flags=re.S)


def function_body(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return strip_comments(source[opening + 1:end - 1])


open_body = function_body(CDEV, "int nmx_cdev_open(void *cookie, int open_id, int fflags)")
close_body = function_body(CDEV, "int nmx_cdev_close(int open_id, int fflags)")
fdopen_body = function_body(COMPAT, "linux_dev_fdopen(struct cdev *dev, int fflags, struct thread *td,")

# The inode LinuxKPI's open receives is a vnode whose v_rdev is the node; iminor() reads the minor through it.
assert "struct vnode vnode;" in CDEV[CDEV.index("struct nmx_open {"):CDEV.index("};", CDEV.index("struct nmx_open {"))]
assert "o->vnode.v_rdev = c;" in open_body
assert "fp->f_vnode = &o->vnode;" in open_body
assert open_body.index("fp->f_vnode = &o->vnode;") < open_body.index("d_fdopen(c, fflags")

# Failure of d_fdopen/d_open releases the file and the cdev reference taken above; the vnode lives in the open.
failure = open_body[open_body.index("if (err) {"):open_body.index("leave(prev);\n\n    mtx_lock")]
assert "free(fp, M_NMXCDEV);" in failure
assert "free(o, M_NMXCDEV);" in failure
assert "dev_rel(c);" in failure
assert "return err;" in failure

# Close frees the open only after fdrop has dropped the linux_file's vnode ref.
assert close_body.index("fdrop(o->fp, curthread);") < close_body.index("free(o, M_NMXCDEV);")

# linux_dev_fdopen's success is 0: nmx_cdev_open treats any nonzero d_fdopen return as a failed open.
assert "return (ENXIO);" not in fdopen_body
assert fdopen_body.rstrip().endswith("return (0);")
assert "vref(filp->f_vnode);" in fdopen_body
assert "filp->f_vnode = file->f_vnode;" in fdopen_body

# Failure of fop->open releases the cdev reference taken by refcount_acquire and the linux_get_fop reference.
failure = fdopen_body[fdopen_body.index("if (error != 0) {"):fdopen_body.index("vref(filp->f_vnode);")]
assert "linux_drop_fop(ldev);" in failure
assert "linux_cdev_deref(filp->f_cdev);" in failure
assert "return (error);" in failure
assert "refcount_acquire(&ldev->refs);" in fdopen_body

print("nmx_linux_cdev_open_test: ok")
