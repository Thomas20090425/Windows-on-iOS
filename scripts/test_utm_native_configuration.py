#!/usr/bin/env python3
"""Check patched UTM native bundle persistence on small, temporary host fixtures.

Compiles the actual native model plus UTM's actual generic save/cleanup methods.
Only the surrounding UTM framework types are replaced by Foundation stubs; this
does not run a VM, open a real machine, or assert anything about device booting.
"""

import argparse
import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile


STUBS = r'''
import Foundation
import Combine
protocol UTMConfiguration: Codable, ObservableObject {
    associatedtype Drive: UTMConfigurationDrive
    static var oldestVersion: Int { get }
    static var currentVersion: Int { get }
    var information: UTMConfigurationInfo { get }
    var drives: [Drive] { get set }
    var backend: UTMBackend { get }
    @MainActor func prepareSave(for packageURL: URL) async throws
    @MainActor func saveData(to dataURL: URL) async throws -> [URL]
}
extension UTMConfiguration {
    static var dataDirectoryName: String { "Data" }
    static var oldestVersion: Int { 4 }
    static var currentVersion: Int { 4 }
}
protocol UTMConfigurationDrive: Codable, Hashable, Identifiable {}
enum UTMBackend: String, Codable { case nativeARM64 = "NativeARM64" }
enum UTMConfigurationError: Error { case versionTooLow, versionTooHigh, invalidBackend }
struct UTMConfigurationInfo: Codable {
    var name = "Virtual Machine"
    var iconURL: URL?
    var uuid = UUID()
    var notes: String?
    static func builtinIcon(named: String) -> URL? { nil }
    @MainActor mutating func saveData(to dataURL: URL) async throws -> [URL] { [] }
}
private let kUTMBundleConfigFilename = "config.plist"
'''


def method(source: str, signature: str) -> str:
    """Use the upstream extension's four-space method boundary, without rewriting it."""
    start = source.index("    " + signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--utm-source", type=Path, default=root / "work/references/UTM")
    parser.add_argument("--log", type=Path, default=root / "build/logs/utm-native-model-check.log")
    args = parser.parse_args()
    model_path = args.utm_source / "Platform/Native/UTMNativeConfiguration.swift"
    generic_path = args.utm_source / "Configuration/UTMConfiguration.swift"
    native = model_path.read_text()
    generic = generic_path.read_text()
    if native.count("#if os(iOS)") != 1 or not native.rstrip().endswith("#endif"):
        raise RuntimeError("The native source's outer platform guard changed; review the harness.")
    native = native.replace("#if os(iOS)", "", 1).rstrip().removesuffix("#endif")
    methods = "\n".join([
        method(generic, "func save(to packageURL: URL) async throws {"),
        method(generic, "private static func cleanupAllFiles(at dataURL: URL, notIncluding urls: [URL]) async throws {"),
    ])
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="utm-native-model-") as temp, args.log.open("w") as log:
        for source in (model_path, generic_path):
            log.write(f"SOURCE {source}: sha256={hashlib.sha256(source.read_bytes()).hexdigest()}\n")
        log.flush()
        work = Path(temp)
        generated = work / "ModelUnderTest.swift"
        generated.write_text(STUBS + native + "\nextension UTMConfiguration {\n" + methods + "\n}\n")
        binary = work / "native-model-check"
        harness = root / "scripts/tests/utm_native_configuration_harness.swift"
        compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", str(generated), str(harness), "-o", str(binary)], stdout=log, stderr=subprocess.STDOUT)
        if compiled.returncode:
            print(f"Native model check compilation failed; see {args.log}", file=sys.stderr)
            return compiled.returncode
        tested = subprocess.run([str(binary)], stdout=log, stderr=subprocess.STDOUT)
    print(args.log.read_text())
    return tested.returncode


if __name__ == "__main__":
    raise SystemExit(main())
