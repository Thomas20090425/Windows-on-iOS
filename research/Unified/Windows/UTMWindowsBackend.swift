// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import Darwin
import Foundation
import SwiftUI
import UIKit

@MainActor
@objc(UTMWindowsBackend)
public final class UTMWindowsBackend: NSObject {
    private static var activeSession: WindowsPackageSession?

    @objc public static func prepareJIT() -> Bool {
        WinIOSBridge.shared.installTrapGuard()
        return WinIOSBridge.shared.tryAcquireJIT(true)
    }

    @objc public static func makeViewController(packageURL: URL, configuration: NSDictionary,
                                               stateChanged: @escaping (String, String?) -> Void) -> UIViewController {
        let canonical = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        if let current = activeSession {
            guard current.packageURL == canonical else {
                let message = "Close and reopen the app before starting a different Windows machine."
                stateChanged("error", message)
                return UIHostingController(rootView: Text(message).padding())
            }
            current.stateChanged = stateChanged
            current.reportState()
            return UIHostingController(rootView: EmbeddedWindowsSession(session: current))
        }
        let session = WindowsPackageSession(packageURL: canonical, configuration: configuration, stateChanged: stateChanged)
        activeSession = session
        return UIHostingController(rootView: EmbeddedWindowsSession(session: session))
    }

    @objc public static func requestStop(force: Bool) {
        if force { WinIOSBridge.shared.stopVM() }
        else { WinIOSBridge.shared.pressPowerButton() }
        activeSession?.vm.syncFromBridge()
        activeSession?.reportState()
    }
}

@MainActor
private final class WindowsPackageSession: ObservableObject {
    let packageURL: URL
    let vm = VMViewModel()
    @Published var configuration: VMConfiguration
    @Published var preparationError: String?
    var stateChanged: (String, String?) -> Void
    private let parameters: NSDictionary
    private var prepared = false
    private var configured = false
    private var hadRunning = false
    private var lastReported: String?

    init(packageURL: URL, configuration: NSDictionary, stateChanged: @escaping (String, String?) -> Void) {
        self.packageURL = packageURL
        self.parameters = configuration
        self.stateChanged = stateChanged
        var config = VMConfiguration(name: configuration["name"] as? String ?? "Windows 11 ARM64")
        config.memoryMB = (configuration["memoryMiB"] as? NSNumber)?.uint64Value ?? 4096
        config.cpuCount = (configuration["cpuCount"] as? NSNumber)?.intValue ?? 4
        config.diskSizeGiB = (configuration["diskSizeGiB"] as? NSNumber)?.intValue ?? 64
        config.networkEnabled = (configuration["networkEnabled"] as? NSNumber)?.boolValue ?? true
        config.audioEnabled = (configuration["audioEnabled"] as? NSNumber)?.boolValue ?? true
        self.configuration = config
        let previous = WinIOSBridge.shared.onStateChanged
        WinIOSBridge.shared.onStateChanged = { [weak self] in
            previous?()
            Task { @MainActor in self?.reportState() }
        }
    }

    func start() async {
        guard !prepared else { return }
        prepared = true
        stateChanged("starting", nil)
        do {
            let config = try configuration.validated()
            guard config.memoryMB <= WinIOSBridge.shared.maxGuestMemoryMB else {
                throw VMLibraryError.invalidMedia("Requested \(config.memoryMB) MiB exceeds this device's \(WinIOSBridge.shared.maxGuestMemoryMB) MiB guest setting.")
            }
            let package = packageURL
            let installationPath = parameters["installationMediaPath"] as? String
            let data = try await Task.detached(priority: .utility) {
                try WindowsPackageFiles.prepare(package: package, configuration: config, installationPath: installationPath)
            }.value
            let bridge = WinIOSBridge.shared
            guard bridge.configureUTMPackageDirectory(data.path, memoryMB: config.memoryMB, cpuCount: config.cpuCount,
                    networkEnabled: config.networkEnabled, audioEnabled: config.audioEnabled) else {
                throw VMLibraryError.invalidMedia(bridge.vmStatusText)
            }
            guard bridge.configureRuntimeOptions(config.runtimeOptions) else {
                throw VMLibraryError.invalidMedia(bridge.vmStatusText)
            }
            let width = (parameters["displayWidth"] as? NSNumber)?.intValue ?? 1920
            let height = (parameters["displayHeight"] as? NSNumber)?.intValue ?? 1080
            guard bridge.configureDisplayResolutionMode(0, width: width, height: height, dynamicResolution: false) else {
                throw VMLibraryError.invalidMedia("Choose a supported Windows display size between 640×480 and 4095×4095.")
            }
            configured = true
            vm.startOrRetry()
            reportState()
        } catch {
            preparationError = error.localizedDescription
            stateChanged("error", error.localizedDescription)
        }
    }

    func reportState() {
        let bridge = WinIOSBridge.shared
        let state: String
        var detail: String?
        if bridge.isVMRunning { hadRunning = true; state = "started" }
        else if hadRunning { state = "stopped" }
        else if configured && bridge.isJITLive && !bridge.isUnpacking &&
                    !bridge.vmStatusText.hasPrefix("Ready") && !bridge.vmStatusText.hasPrefix("JIT setup") &&
                    bridge.vmStatusText != "Idle" {
            state = "error"; detail = bridge.vmStatusText
        } else { state = "starting" }
        let signature = state + (detail ?? "")
        guard signature != lastReported else { return }
        lastReported = signature
        stateChanged(state, detail)
    }
}

private struct EmbeddedWindowsSession: View {
    @ObservedObject var session: WindowsPackageSession

    var body: some View {
        Group {
            if let message = session.preparationError {
                ContentUnavailableView("Windows could not start", systemImage: "exclamationmark.triangle", description: Text(message))
            } else {
                IPadSessionView(vm: session.vm, configuration: $session.configuration)
            }
        }
        .task { await session.start() }
        .onChange(of: session.configuration.displayResolution) { _, _ in session.reportState() }
    }
}

private enum WindowsPackageFiles {
    static func prepare(package: URL, configuration: VMConfiguration, installationPath: String?) throws -> URL {
        let manager = FileManager.default
        guard package.pathExtension.lowercased() == "utm" else {
            throw VMLibraryError.invalidMedia("Windows must start from a managed .utm package.")
        }
        let data = package.appendingPathComponent("Data", isDirectory: true)
        try manager.createDirectory(at: data, withIntermediateDirectories: true)
        guard data.resolvingSymlinksInPath() == data else {
            throw VMLibraryError.invalidMedia("The package's Data directory cannot link outside the machine.")
        }
        if let enumerator = manager.enumerator(at: data, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let url as URL in enumerator {
                if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw VMLibraryError.invalidMedia("Machine data cannot contain symbolic links.")
                }
            }
        }
        let iso = data.appendingPathComponent("installer.iso")
        if let installationPath {
            guard URL(fileURLWithPath: installationPath).standardizedFileURL.resolvingSymlinksInPath() == iso else {
                throw VMLibraryError.invalidMedia("Windows installation media must be Data/installer.iso inside this machine.")
            }
        }
        let disk = data.appendingPathComponent("windows11.img")
        let hasDisk = manager.fileExists(atPath: disk.path) || manager.fileExists(atPath: data.appendingPathComponent("windows11.hvsparse").path)
        let variables = data.appendingPathComponent("vars.fd")
        if !manager.fileExists(atPath: variables.path) {
            guard !manager.fileExists(atPath: data.appendingPathComponent("tpm-state-initialized").path) else {
                throw VMLibraryError.invalidMedia("This machine's firmware variables are missing. Restore vars.fd together with its disk and TPM state.")
            }
            guard let template = VMBundledFirmware.variablesURL else { throw VMLibraryError.missingBundledFirmware }
            try manager.copyItem(at: template, to: variables)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: variables.path)
        }
        if !hasDisk {
            guard manager.fileExists(atPath: iso.path) else {
                throw VMLibraryError.invalidMedia("Choose a Windows 11 ARM64 ISO or import a complete prepared Windows machine.")
            }
            let reader = try FileHandle(forReadingFrom: iso)
            defer { try? reader.close() }
            try reader.seek(toOffset: 16 * 2048)
            let descriptors = try reader.read(upToCount: 16 * 2048) ?? Data()
            guard (0..<16).contains(where: { sector in
                let start = sector * 2048 + 1
                guard start + 5 <= descriptors.count else { return false }
                return ["CD001", "BEA01", "NSR02", "NSR03"].contains(String(data: descriptors.subdata(in: start..<(start + 5)), encoding: .ascii) ?? "")
            }) else { throw VMLibraryError.invalidMedia("The selected media does not contain an ISO or UDF optical-disc descriptor.") }
            let free = try data.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
            guard free >= (32 << 30) + (128 << 20) else {
                throw VMLibraryError.insufficientStorage(required: (32 << 30) + (128 << 20), available: free)
            }
            let descriptor = open(disk.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw VMLibraryError.cannotCreateDisk }
            do {
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? file.close() }
                try file.truncate(atOffset: UInt64(configuration.diskSizeGiB) << 30)
                try file.synchronize()
                try WindowsInstallationMedia.prepare(in: data, diskSizeGiB: configuration.diskSizeGiB)
            } catch {
                try? manager.removeItem(at: disk)
                throw error
            }
        }
        return data
    }
}
