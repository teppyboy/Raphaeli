# Recovery evidence collector

Added `scripts/collect-recovery.sh`; shipped in future release zips under
`tools/`. Run in Recovery Terminal, supplying a new output directory on a
writable USB volume and optionally an already-mounted EFI volume root.

Collects the running Recovery SystemVersion.plist and BootKernelExtensions.kc,
sw_vers/uname, optional OpenCore text logs (EFI root and EFI/OC), Raphaeli plist,
and EFI executable SHA-256. Produces a checksummed directory plus `.tar.gz`.
Does not mount volumes, read/write NVRAM, copy OC config, or alter input files.
Existing evidence is not overwritten. Logs can contain identifiers: review
before sharing. Multiple logs may include old boots; compare timestamps.

Verification: `/bin/bash scripts/collect-recovery.test.sh` passes under Apple
bash 3.2.57. Fixtures cover spaced paths, tar extraction/checksums, duplicate
log basenames, optional/invalid EFI, overwrite refusal, and missing KC.
`bash -n` and `git diff --check` pass. Active LSP probe was inconclusive;
no clean-LSP claim. Actual Recovery execution awaits target hardware.
