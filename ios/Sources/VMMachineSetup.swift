// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum VMBundledFirmware {
    static var codeURL: URL? {
        Bundle.main.url(forResource: "code", withExtension: "fd", subdirectory: "Firmware")
    }

    static var variablesURL: URL? {
        Bundle.main.url(forResource: "vars-template", withExtension: "fd", subdirectory: "Firmware")
    }
}

extension VMLibraryFiles {
    /// Build an entirely new VM privately, then publish it after every file is ready.
    /// Existing VM directories and disks are never opened for writing here.
    func createFromISO(name: String, diskSizeGiB: Int, iso: URL) throws -> VMMachine {
        let manager = FileManager.default
        var configuration = VMConfiguration(name: name)
        configuration.diskSizeGiB = diskSizeGiB
        configuration.installationISO = "installer.iso"
        _ = try configuration.validated()

        guard let code = VMBundledFirmware.codeURL, let variables = VMBundledFirmware.variablesURL,
              manager.fileExists(atPath: code.path), manager.fileExists(atPath: variables.path) else {
            throw VMLibraryError.missingBundledFirmware
        }
        let sourceValues = try iso.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true,
              iso.pathExtension.lowercased() == "iso", let sourceSize = sourceValues.fileSize,
              sourceSize >= 64 * 1024 * 1024, sourceSize <= 32 * 1024 * 1024 * 1024 else {
            throw VMLibraryError.invalidMedia("Choose an official Windows 11 ARM64 installation .iso file. A raw disk, VHDX or ESD is not installation ISO media.")
        }
        try validateISOContainer(iso)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let freeSpace = try availableStorage(at: root)
        // The virtual disk is sparse. Do not require its full logical capacity,
        // but leave room for a normal Windows installation in addition to the ISO.
        let requiredSpace = Int64(sourceSize) + (32 << 30) + (128 << 20)
        guard freeSpace >= requiredSpace else {
            throw VMLibraryError.insufficientStorage(required: requiredSpace, available: freeSpace)
        }

        let identifier = UUID().uuidString
        let staging = root.appendingPathComponent(".creating-\(identifier)", isDirectory: true)
        let destination = root.appendingPathComponent(identifier, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }

        let importedISO = staging.appendingPathComponent("installer.iso")
        try manager.copyItem(at: iso, to: importedISO)
        try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: importedISO.path)

        let variableStore = staging.appendingPathComponent("vars.fd")
        try manager.copyItem(at: variables, to: variableStore)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: variableStore.path)

        let disk = staging.appendingPathComponent("windows11.img")
        guard manager.createFile(atPath: disk.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VMLibraryError.cannotCreateDisk
        }
        let handle = try FileHandle(forWritingTo: disk)
        do {
            try handle.truncate(atOffset: UInt64(diskSizeGiB) << 30)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        try save(configuration, in: staging)
        try WindowsInstallationMedia.prepare(in: staging, diskSizeGiB: diskSizeGiB)
        // Move fails if the destination already exists; it never replaces a VM.
        try manager.moveItem(at: staging, to: destination)
        return try machine(at: destination)
    }

    private func availableStorage(at directory: URL) throws -> Int64 {
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage { return available }
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }

    private func validateISOContainer(_ source: URL) throws {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: 16 * 2048)
        let descriptors = try handle.read(upToCount: 16 * 2048) ?? Data()
        let hasDescriptor = (0..<16).contains { sector in
            let start = sector * 2048 + 1
            guard start + 5 <= descriptors.count else { return false }
            let signature = String(data: descriptors.subdata(in: start..<(start + 5)), encoding: .ascii)
            return signature == "CD001" || signature == "BEA01" || signature == "NSR02" || signature == "NSR03"
        }
        guard hasDescriptor else {
            throw VMLibraryError.invalidMedia("The selected file does not contain an ISO 9660 or UDF optical-disc descriptor. Choose the original Windows ARM64 ISO.")
        }
    }
}
