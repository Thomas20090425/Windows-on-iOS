// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

enum VMDisplayResolution: String, Codable, CaseIterable, Identifiable {
    case native, window, hd, fullHD, qhd, uhd
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "Native screen"
        case .window: return "Fit app window"
        case .hd: return "1280 × 720"
        case .fullHD: return "1920 × 1080"
        case .qhd: return "2560 × 1440"
        case .uhd: return "3840 × 2160"
        }
    }
    var mode: Int { self == .native ? 1 : self == .window ? 2 : 0 }
    var size: (width: Int, height: Int) {
        switch self {
        case .hd: return (1280, 720)
        case .qhd: return (2560, 1440)
        case .uhd: return (3840, 2160)
        default: return (1920, 1080)
        }
    }
}

/// Runtime options understood by the existing engine.
struct VMConfiguration: Codable, Equatable {
    var name: String = "Windows 11 ARM64"
    var memoryMB: UInt64 = 4096
    var cpuCount: Int = 4
    var networkEnabled: Bool = true
    var audioEnabled: Bool = true
    var primaryDiskReadOnly: Bool = false
    var sharedFolderEnabled: Bool = true
    var microphoneEnabled: Bool = false
    var displayRefreshRate: Int = 60
    var displayResolution: VMDisplayResolution = .native
    var dynamicResolution: Bool = true
    var diagnosticLogging: Bool = false
    var tcpForwardHostPort: Int = 0
    var tcpForwardGuestPort: Int = 0
    var touchTrackpad: Bool = false
    var commandToControl: Bool = false
    var pointerSensitivity: Double = 1
    var diskSizeGiB: Int = 64
    var installationISO: String?

    init(name: String = "Windows 11 ARM64") { self.name = name }

    private enum CodingKeys: String, CodingKey {
        case name, memoryMB, cpuCount, networkEnabled, audioEnabled
        case primaryDiskReadOnly, sharedFolderEnabled, microphoneEnabled, displayRefreshRate
        case displayResolution, dynamicResolution
        case diagnosticLogging, tcpForwardHostPort, tcpForwardGuestPort
        case touchTrackpad, commandToControl, pointerSensitivity
        case diskSizeGiB, installationISO
    }

    /// Each added option has a default so existing machine configurations remain readable.
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? name
        memoryMB = try values.decodeIfPresent(UInt64.self, forKey: .memoryMB) ?? memoryMB
        cpuCount = try values.decodeIfPresent(Int.self, forKey: .cpuCount) ?? cpuCount
        networkEnabled = try values.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? networkEnabled
        audioEnabled = try values.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? audioEnabled
        primaryDiskReadOnly = try values.decodeIfPresent(Bool.self, forKey: .primaryDiskReadOnly) ?? primaryDiskReadOnly
        sharedFolderEnabled = try values.decodeIfPresent(Bool.self, forKey: .sharedFolderEnabled) ?? sharedFolderEnabled
        microphoneEnabled = try values.decodeIfPresent(Bool.self, forKey: .microphoneEnabled) ?? microphoneEnabled
        displayRefreshRate = try values.decodeIfPresent(Int.self, forKey: .displayRefreshRate) ?? displayRefreshRate
        displayResolution = try values.decodeIfPresent(VMDisplayResolution.self, forKey: .displayResolution) ?? displayResolution
        dynamicResolution = try values.decodeIfPresent(Bool.self, forKey: .dynamicResolution) ?? dynamicResolution
        diagnosticLogging = try values.decodeIfPresent(Bool.self, forKey: .diagnosticLogging) ?? diagnosticLogging
        tcpForwardHostPort = try values.decodeIfPresent(Int.self, forKey: .tcpForwardHostPort) ?? tcpForwardHostPort
        tcpForwardGuestPort = try values.decodeIfPresent(Int.self, forKey: .tcpForwardGuestPort) ?? tcpForwardGuestPort
        touchTrackpad = try values.decodeIfPresent(Bool.self, forKey: .touchTrackpad) ?? touchTrackpad
        commandToControl = try values.decodeIfPresent(Bool.self, forKey: .commandToControl) ?? commandToControl
        pointerSensitivity = try values.decodeIfPresent(Double.self, forKey: .pointerSensitivity) ?? pointerSensitivity
        diskSizeGiB = try values.decodeIfPresent(Int.self, forKey: .diskSizeGiB) ?? diskSizeGiB
        installationISO = try values.decodeIfPresent(String.self, forKey: .installationISO)
    }

    var runtimeOptions: [String: NSNumber] {
        ["primaryDiskReadOnly": NSNumber(value: primaryDiskReadOnly), "sharedFolderEnabled": NSNumber(value: sharedFolderEnabled),
         "microphoneEnabled": NSNumber(value: microphoneEnabled), "displayRefreshRate": NSNumber(value: displayRefreshRate),
         "diagnosticLogging": NSNumber(value: diagnosticLogging), "tcpForwardHostPort": NSNumber(value: tcpForwardHostPort),
         "tcpForwardGuestPort": NSNumber(value: tcpForwardGuestPort),
         "displayResolutionMode": NSNumber(value: displayResolution.mode),
         "displayWidth": NSNumber(value: displayResolution.size.width), "displayHeight": NSNumber(value: displayResolution.size.height),
         "dynamicResolution": NSNumber(value: dynamicResolution)]
    }

    func validated() throws -> VMConfiguration {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 100 else { throw VMLibraryError.invalidName }
        let noForward = tcpForwardHostPort == 0 && tcpForwardGuestPort == 0
        let validForward = (1024...65535).contains(tcpForwardHostPort) && (1...65535).contains(tcpForwardGuestPort)
        let memoryMapLimitMB: UInt64 = (0x4010000000 - 0x40000000) >> 20
        guard (1...4).contains(cpuCount), (4096...memoryMapLimitMB).contains(memoryMB),
              [30, 60, 120].contains(displayRefreshRate), pointerSensitivity.isFinite,
              (0.25...3).contains(pointerSensitivity), (64...512).contains(diskSizeGiB),
              installationISO == nil || installationISO == "installer.iso", installationISO == nil || !primaryDiskReadOnly,
              noForward || validForward else {
            throw VMLibraryError.invalidConfiguration
        }
        return self
    }
}

struct VMMachine: Identifiable, Equatable {
    let directory: URL
    var configuration: VMConfiguration
    var storedBytes: Int64
    var missingFiles: [String]
    var hasSecondaryDisk: Bool
    var hasInstallerISO: Bool
    var id: String { directory.path }
    var isReady: Bool { missingFiles.isEmpty }
}

enum VMMediaKind: String, CaseIterable, Identifiable {
    case disk, secondaryDisk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disk: return "Prepared Windows disk (.img or .hvsparse)"
        case .secondaryDisk: return "Optional read-only secondary disk (.img or .raw)"
        }
    }
    var filename: String {
        switch self {
        case .disk: return "windows11.img"
        case .secondaryDisk: return "secondary.img"
        }
    }
}

enum VMLibraryError: LocalizedError {
    case invalidName, invalidConfiguration, invalidMedia(String), alreadyExists(String), invalidDirectory
    case missingBundledFirmware, missingBundledDrivers, insufficientStorage(required: Int64, available: Int64), cannotCreateDisk
    case machineInUse
    var errorDescription: String? {
        switch self {
        case .invalidName: return "Enter a machine name between 1 and 100 characters."
        case .invalidConfiguration: return "Choose valid CPU, memory, refresh rate and input settings. A TCP forward requires a host port in 1024–65535 and guest port in 1–65535, or both 0 to disable it."
        case .invalidMedia(let reason): return reason
        case .alreadyExists(let file): return "\(file) already exists. Import into a new machine to preserve existing data."
        case .invalidDirectory: return "The machine must be inside Documents/Machines."
        case .missingBundledFirmware: return "This app build is missing its bundled UEFI firmware. Rebuild or reinstall WindowsiOS; no firmware import is required."
        case .missingBundledDrivers: return "The bundled Windows ARM64 driver media is missing or damaged. Reinstall the current WindowsiOS build."
        case .insufficientStorage(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Windows setup needs at least \(formatter.string(fromByteCount: required)) free for the ISO copy and installation headroom. Available: \(formatter.string(fromByteCount: available))."
        case .cannotCreateDisk: return "The app could not create the Windows virtual disk. Check available iPad storage."
        case .machineInUse: return "This machine is still in use. Stop Windows and close and relaunch WindowsiOS before deleting it."
        }
    }
}

/// File operations are independent of UIKit so persistence and import safety can be tested on macOS.
struct VMLibraryFiles {
    let root: URL
    private var manager: FileManager { .default }
    private let configurationName = "configuration.json"

    func machines() throws -> [VMMachine] {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let children = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        return try children.filter {
            let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values.isDirectory == true && values.isSymbolicLink != true
        }.map { try machine(at: $0) }.sorted { $0.configuration.name.localizedStandardCompare($1.configuration.name) == .orderedAscending }
    }

    func create(name: String) throws -> VMMachine {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let configuration = try VMConfiguration(name: name).validated()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do { try save(configuration, in: directory) }
        catch { try? manager.removeItem(at: directory); throw error }
        return try machine(at: directory)
    }

    func save(_ configuration: VMConfiguration, in directory: URL) throws {
        try validateDirectory(directory)
        let data = try JSONEncoder().encode(configuration.validated())
        try data.write(to: directory.appendingPathComponent(configurationName), options: .atomic)
    }

    func machine(at directory: URL) throws -> VMMachine {
        try validateDirectory(directory)
        let configURL = directory.appendingPathComponent(configurationName)
        let configuration: VMConfiguration
        var configurationIssue: String?
        if manager.fileExists(atPath: configURL.path) {
            do {
                configuration = try JSONDecoder().decode(VMConfiguration.self, from: Data(contentsOf: configURL)).validated()
            } catch {
                // Keep damaged configurations visible so the owner can delete
                // an old VM instead of making the whole library inaccessible.
                configuration = VMConfiguration(name: directory.lastPathComponent)
                configurationIssue = "configuration.json could not be read: \(error.localizedDescription)"
            }
        } else { configuration = VMConfiguration(name: directory.lastPathComponent == "Win11" ? "Windows 11 ARM64" : directory.lastPathComponent) }
        let names = try manager.contentsOfDirectory(atPath: directory.path)
        var missing = [String]()
        if let configurationIssue { missing.append(configurationIssue) }
        if !names.contains("code.fd") && VMBundledFirmware.codeURL == nil { missing.append("bundled UEFI firmware") }
        if !names.contains("vars.fd") { missing.append("automatic firmware initialization") }
        if !names.contains("windows11.img") && !names.contains("windows11.hvsparse") { missing.append("windows11.img or windows11.hvsparse") }
        if configuration.installationISO != nil && !names.contains("installer.iso") { missing.append("Windows installation ISO") }
        var stored: Int64 = 0
        for file in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileAllocatedSizeKey], options: [.skipsHiddenFiles]) {
            stored += Int64((try? file.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize) ?? 0)
        }
        return VMMachine(directory: directory, configuration: configuration, storedBytes: stored, missingFiles: missing, hasSecondaryDisk: names.contains("secondary.img"), hasInstallerISO: names.contains("installer.iso"))
    }

    /// Deletes only a real, direct child of this library. Symlinked roots and
    /// machine directories are never followed; original imports live elsewhere.
    func deleteMachine(at directory: URL) throws {
        let library = root.standardizedFileURL
        let target = directory.standardizedFileURL
        guard library.isFileURL, target.isFileURL,
              !target.lastPathComponent.hasPrefix("."),
              target.deletingLastPathComponent() == library else {
            throw VMLibraryError.invalidDirectory
        }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let libraryValues = try library.resourceValues(forKeys: keys)
        let targetValues = try target.resourceValues(forKeys: keys)
        guard libraryValues.isDirectory == true, libraryValues.isSymbolicLink != true,
              targetValues.isDirectory == true, targetValues.isSymbolicLink != true else {
            throw VMLibraryError.invalidDirectory
        }
        let canonicalLibrary = library.resolvingSymlinksInPath()
        let canonicalTarget = target.resolvingSymlinksInPath()
        guard canonicalTarget.deletingLastPathComponent() == canonicalLibrary else {
            throw VMLibraryError.invalidDirectory
        }
        try manager.removeItem(at: target)
    }

    /// Copy into a private staging path and rename only after complete validation. Never replace media.
    func importMedia(from source: URL, kind: VMMediaKind, into directory: URL) throws {
        try validateDirectory(directory)
        let sourceValues = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw VMLibraryError.invalidMedia("Choose a regular file.")
        }
        let size = sourceValues.fileSize ?? 0
        var name = kind.filename
        if kind == .disk || kind == .secondaryDisk {
            let ext = source.pathExtension.lowercased()
            let supported = kind == .secondaryDisk ? ["img", "raw"] : ["img", "raw", "hvsparse"]
            guard supported.contains(ext) else {
                throw VMLibraryError.invalidMedia("Import a prepared ARM64 raw .img/.raw disk or .hvsparse archive. Installation ISOs, VHDX and QCOW2 require conversion on a Mac.")
            }
            if ext == "hvsparse" {
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                let header = try handle.read(upToCount: 16) ?? Data()
                guard header.count == 16, header.prefix(8) == Data("HVSPARSE".utf8) else {
                    throw VMLibraryError.invalidMedia("This file does not have a valid HVSPARSE header.")
                }
                let logicalSize = header.suffix(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
                guard logicalSize >= 64 * 1024 * 1024 else {
                    throw VMLibraryError.invalidMedia("The HVSPARSE logical disk must be at least 64 MiB.")
                }
                name = "windows11.hvsparse"
            } else if size < 64 * 1024 * 1024 {
                throw VMLibraryError.invalidMedia("A prepared raw Windows disk must be at least 64 MiB.")
            }
            let existingNames = kind == .secondaryDisk ? ["secondary.img"] : ["windows11.img", "windows11.hvsparse"]
            for existing in existingNames where manager.fileExists(atPath: directory.appendingPathComponent(existing).path) {
                throw VMLibraryError.alreadyExists(existing)
            }
        } else {
            guard source.pathExtension.lowercased() == "fd", size > 0, size <= 64 * 1024 * 1024 else {
                throw VMLibraryError.invalidMedia("Choose a nonempty EDK2 .fd file no larger than 64 MiB.")
            }
        }
        let destination = directory.appendingPathComponent(name)
        guard !manager.fileExists(atPath: destination.path) else { throw VMLibraryError.alreadyExists(name) }
        let staging = directory.appendingPathComponent(".import-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        // FileManager refuses to overwrite if another import wins this race.
        try manager.moveItem(at: staging, to: destination)
    }

    private func validateDirectory(_ directory: URL) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalDirectory.deletingLastPathComponent() == canonicalRoot else { throw VMLibraryError.invalidDirectory }
    }
}
