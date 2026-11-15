# Software TPM dependency provenance

The app's software TPM uses **libtpms 0.10.2** with its TPM 2.0 implementation
and **OpenSSL 3.5.9 LTS** for cryptography. It does not use the iPad's Secure
Enclave as a guest TPM and does not provide hardware-backed attestation.

`scripts/build_ios_tpm_deps.sh` downloads the official source archives below,
verifies their SHA-256 hashes, and cross-compiles static arm64 iOS libraries
with a minimum deployment target of iOS 17.0. It builds no TPM 1.2 support,
OpenSSL modules, command-line apps, or test programs. No test or virtual
machine is executed by the script. Autoconf probes are cross-compiled rather
than run on the build host.

| Source | Pinned SHA-256 |
| --- | --- |
| [libtpms v0.10.2 tag archive](https://github.com/stefanberger/libtpms/archive/refs/tags/v0.10.2.tar.gz) | `edac03680f8a4a1c5c1d609a10e3f41e1a129e38ff5158f0c8deaedc719fb127` |
| [OpenSSL 3.5.9 release archive](https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz) | `603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a` |

The script stages `libtpms.a`, `libcrypto.a`, public headers, licenses and a
machine-readable provenance manifest under `ios/deps/`. The notices in
`ios/deps/licenses/TPM` are included with the built app. Full upstream license
texts are also retained in `licenses/libtpms-LICENSE.txt` and
`licenses/OpenSSL-LICENSE.txt`. The combined iOS binary uses the GPL version 3
option in this repository's GPL-2.0-or-later notices, with full GPLv3 and linking
notice also bundled; see [Apache's license compatibility reference](https://www.apache.org/licenses/GPL-compatibility).
OpenSSL source is unmodified. The libtpms source
has one recorded patch:
`scripts/patches/libtpms-0.10.2-entropy-fail-closed.patch` makes an OpenSSL
random-generator failure fatal instead of accepting upstream's simulator
`rand()` fallback. Its hash and a copy accompany the dependency provenance.

Upstream references: [libtpms release notes](https://github.com/stefanberger/libtpms/releases/tag/v0.10.2),
[libtpms API](https://github.com/stefanberger/libtpms/blob/v0.10.2/include/libtpms/tpm_library.h),
[OpenSSL downloads](https://www.openssl-library.org/source/), and
[OpenSSL iOS build targets](https://github.com/openssl/openssl/blob/openssl-3.5.9/Configurations/15-ios.conf).

Compilation and packaging establish which code is linked; they do not prove
Windows TPM enrollment, firmware measured boot, key persistence, BitLocker
recovery, or guest compatibility. Those need separate device validation.

The guest exposes a polling CRB interface at `0x090c0000` through ACPI
`MSFT0101` and a revision 4 TPM2 table (start method 7). The firmware discovers
a genuine FIFO/TIS interface at `0x090d0000` through the device tree. Both
frontends serialize commands into one library instance, one locality arbiter
and the same NV state. No physical-presence method or interrupt is advertised.
The pinned Debian ArmVirtQemu build enables `TPM2_ENABLE` and
`TPM2_CONFIG_ENABLE`; its PlatformPeiLib discovers FIFO/TIS, and Tcg2Pei/Tcg2Dxe
and DxeTpm2MeasureBootLib supply the firmware TPM path. Firmware source review
does not establish successful measurements on the device.

TPM state uses app-private per-VM files, exclusive locking and atomic durable
NV updates. Unreadable state is preserved and rejected. A marker outside the
TPM directory prevents silent recreation after the entire directory is lost.
Warm resets reinitialize volatile TPM state while preserving permanent keys.
The app stops the VM if persistence or the backend fails. Back up the VM disk,
firmware variables, `TPM/` directory and `tpm-state-initialized` marker together.
