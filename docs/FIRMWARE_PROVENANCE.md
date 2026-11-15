# Bundled ARM64 UEFI firmware

The app supplies redistributable TianoCore EDK2 ArmVirtQemu firmware. Users do
not need to find, import, or initialize firmware/variable-store files.

## Pinned binary distribution

- Distributor: Debian, `qemu-efi-aarch64`, version `2025.02-8+deb13u1`.
- Package: [official Debian archive](https://deb.debian.org/debian/pool/main/e/edk2/qemu-efi-aarch64_2025.02-8+deb13u1_all.deb).
- Published checksum: [Debian download page](https://packages.debian.org/trixie/all/qemu-efi-aarch64/download).
- Package SHA-256: `a00b2411a79c8aeafd95a7c868ac3cd1aab592f1af9fff965f02d81a625276ed`.
- Corresponding source and Debian patches: [Debian source package](https://sources.debian.org/src/edk2/2025.02-8%2Bdeb13u1/).
- Upstream: [TianoCore EDK2](https://github.com/tianocore/edk2).

`scripts/prepare_firmware.py` verifies the downloaded package, extracts only the
named regular resources, and stages the following folder for the app bundle:

| App resource | Package member | Size |
| --- | --- | --- |
| `Firmware/code.fd` | `usr/share/AAVMF/AAVMF_CODE.secboot.fd` | 64 MiB |
| `Firmware/vars-template.fd` | `usr/share/AAVMF/AAVMF_VARS.ms.fd` | 64 MiB |
| `Firmware/EDK2-LICENSES.txt` | `usr/share/doc/qemu-efi-aarch64/copyright` | Complete notices |
| `Firmware/README.Debian.txt` | `usr/share/doc/qemu-efi-aarch64/README.Debian` | Firmware variants explained |
| `Firmware/provenance.json` | Generated build manifest | Source and per-file SHA-256 |

The explicit Secure Boot code build is paired with the distribution's
Microsoft-enrolled variable template. The code bank is read-only; each newly
created VM receives a private writable copy of the matching template as
`vars.fd`. The variable template contains an initialized firmware volume and
keys; zero-filling a file is not an equivalent replacement. Snakeoil/test keys
are not extracted or distributed.

The engine implements two 64 MiB flash banks, matching the selected firmware
geometry. Selecting this pair does not establish that the engine implements all
Windows 11 platform requirements; in particular it does not add a virtual TPM.
No Windows requirements bypass is provided by this firmware preparation step.

## Build integration and updating

The compile-only `scripts/build_ios_app.sh` runs firmware preparation before
XcodeGen. The Xcode project also has a firmware preparation build phase. The
folder reference preserves `Firmware/` in the signed app. Cache/package files
live in ignored `work/firmware/`; extracted bundle resources live in ignored
`build/firmware/Firmware/`. No download or firmware configuration is required
from the app user, and no Windows image is downloaded by these scripts.

To update deliberately, select a current Debian release package, verify the
official published checksum, update the pinned version/checksum and source URL
in the preparation script, and retain the package's updated full license file.
Rebuild to produce an updated manifest. Do not substitute an arbitrary firmware
or mix its code with a different version's variable template.

Firmware package extraction, hashes, resource packaging and compilation can be
checked without running a VM. JIT availability, actual UEFI/Windows startup,
Secure Boot behavior and installation still require later physical-device
verification; no such runtime check was performed during this build-only work.
