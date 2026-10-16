# Acceleration selftest fence timeout correctness

## Defect

`nmx_accel_bridge_fence_wait` treated `dma_fence_wait_timeout` returning zero
(timeout) as success. It also discarded a signaled fence's negative error status.
The IOKit wrapper maps zero to KERN_SUCCESS, so the boot-argument selftest could
log PASS despite no completion, then free the 4 KiB indirect buffer while the GPU
might still read it.

Callers inspected: Kernel `nmx_xnu_accel_fence_wait` and the bridge's
`nmx_accel_selftest`; declarations in nmx_accel.h/nmx_port.h. No external/user
submit selector added. Existing KERN_OPERATION_TIMED_OUT mapping uses -ETIME.

## Fix

- Zero wait result (or unexpectedly unsignaled status) returns `-ETIME`.
- Negative wait result propagates unchanged.
- Positive wait result checks `dma_fence_get_status` before dropping the fence
  reference; negative fence error propagates, successful completion returns zero.
- Selftest only frees its IB on refused submit or confirmed successful wait.
  Failed waits retain the IB and log the deliberate 4 KiB retention. This is a
  conservative safety limit until reset cleanup exists, not a runtime allocator
  feature or a GPU acceleration completion claim.

## Host regression

`python3 scripts/tests/accel_fence_test.py` compiles the actual production
wait/selftest function bodies with mock fence/BO APIs, then runs assertions for:
null fence; zero/negative wait; signaled error/success; unexpectedly zero status;
one reference put on each real wait; successful selftest frees; timed-out,
interrupted, and error waits retain the IB; refused submit frees; disabled test
performs no allocation/free.

The harness is host C only and does not submit commands to any GPU. Full
`build.sh` 900/900, `rt.sh` 81/81, link SHA prefix `391c64ee` (14,301,808 bytes),
kmutil inspect exit 0. Exact 25G83 Recovery Boot KC with matching graphics
families passes the real OpenCore injection gate after this change. Firmware
census and OC installer host tests pass; git diff --check passes. LSP analysis
is partly inconclusive; its ownership warning is on the pre-existing
`free(kids, M_TEMP)` after device_get_children, not newly introduced allocation.
Target selftest remains unverified. No VM mappings or user command submission
enabled.
