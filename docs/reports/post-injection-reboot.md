# Post-injection reboot: evidence and attach-gate correction

## Target evidence

User reports all three kext injections now succeed (Apple graphics dependencies
and Raphaeli), but Recovery still reboots. `raphaeli-amd=1` was present. No panic
text observed; that alone neither proves nor rules out a kernel panic. Latest
OC log and a boot video/panic evidence remain requested. EFI configuration,
cross-KC duplicate-family behavior, class initialization and driver startup are
not yet distinguished.

Existing diagnostic: keep all entries enabled, preserve verbose/panic-stop boot
args, temporarily add existing `-nvoff`. Source `opted_in` checks it before the
AMD opt-in and device property. This is a one-boot diagnostic, not an automatic
Recovery opt-out. Do not clear the failed-attach NVRAM park marker.

## Actual code defect found

`nmx_xnu_pci_bar_info` returns **1** for an assigned BAR, **0** for unavailable.
The FB and Compat callers correctly check that convention. `Raphaeli::start`
incorrectly rejected `!= 0`, refusing valid devices before port startup. If the
helper returned 0 without filling its output pointers, start also examined or
logged uninitialized locals.

Fixed the caller to require result 1 and initialized its three outputs to zero.
No API, plist, matching-policy, MSI gate or Recovery behavior changed.

This defect blocks attach; it is **not demonstrated as the reset cause**.
In particular, a valid BAR was previously rejected before amdgpu ran. The new
build can reach previously unexecuted initialization, so retain a bootable EFI
backup and test the inert path before opting into attach.

## Startup checkpoints

Added bounded IOLog messages to module entry/lock result, parked probe, successful
PCI checks, port-start completion, attach-thread entry, guard-setting, amdgpu
attach call/return, PM setup, FB/accel claim publication and completion. No new
boot switch, sleep, guessed hardware operation or persistent state introduced.
These messages are kernel logs; they do not appear in the pre-kernel OpenCore
file log. Console visibility is not guaranteed if display output is lost.

Source audit ruled out returning from the attach thread as an automatic fault:
XNU x86_64 `call_continuation` calls `thread_terminate` after the continuation
returns (`osfmk/x86_64/machine_routines_asm.s`). No speculative thread-exit patch.

## Host regression

`python3 scripts/tests/pci_start_gate_test.py` compiles the actual production
BAR helper plus the exact `Raphaeli::start` prefix through BAR/MSI gates against
IOKit mocks. Asserts valid MMIO is accepted; missing/empty/IO BAR, absent MSI,
null provider and null module lock are rejected. Missing-BAR log is deterministic
(size 0, io 0), not uninitialized data. Does not emulate real PCI or attach a GPU.

Validation: build.sh 900/900; final rt.sh 81/81; direct nmx_kext.cpp compilation
clean; link SHA prefix 750a9778 (14,301,904 bytes); kmutil inspect exit 0.
Exact Recovery Boot KC with matching dependency bundles passes real OC injection
for all three modules. BAR-gate, fence/selftest, firmware census tests pass;
git diff --check passes. Active LSP probes timed out, not a clean assertion.
Target reboot cause and all hardware behavior remain unverified.
