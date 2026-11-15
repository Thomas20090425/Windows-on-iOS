// SPDX-License-Identifier: GPL-2.0-or-later
import Combine
import SwiftUI
import UniformTypeIdentifiers
import UIKit

@MainActor
final class VMLibraryStore: ObservableObject {
    @Published var machines: [VMMachine] = []
    @Published var errorMessage: String?
    @Published var isImporting = false
    let files: VMLibraryFiles

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        files = VMLibraryFiles(root: documents.appendingPathComponent("Machines", isDirectory: true))
    }

    func refresh() {
        do { machines = try files.machines() }
        catch { errorMessage = error.localizedDescription }
    }

    func create(name: String) -> VMMachine? {
        do {
            let machine = try files.create(name: name)
            refresh()
            return machine
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func save(_ configuration: VMConfiguration, machine: VMMachine) {
        do { try files.save(configuration, in: machine.directory); refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func importMedia(url: URL, kind: VMMediaKind, machine: VMMachine) {
        guard !isImporting else { return }
        isImporting = true
        let files = self.files
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do { try files.importMedia(from: url, kind: kind, into: machine.directory); return nil }
                catch { return error.localizedDescription }
            }.value
            isImporting = false
            if let failure { errorMessage = failure }
            refresh()
        }
    }
}

struct VMLibraryView: View {
    @ObservedObject var vm: VMViewModel
    @StateObject private var library = VMLibraryStore()
    @State private var selectedID: String?
    @State private var newMachineName = "Windows 11 ARM64"
    @State private var creatingMachine = false
    @State private var importKind = VMMediaKind.disk
    @State private var importing = false
    @State private var showSession = false
    @State private var activeMachineID: String?

    private var selected: VMMachine? { library.machines.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(library.machines) { machine in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(machine.configuration.name)
                            Text(machine.isReady ? "Media imported" : "Media required")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "desktopcomputer") }
                    .tag(machine.id)
                }
            }
            .navigationTitle("Virtual Machines")
            .overlay {
                if library.machines.isEmpty {
                    ContentUnavailableView("Your Windows machines", systemImage: "desktopcomputer", description: Text("Create a machine, then import prepared Windows 11 ARM64 media and EDK2 firmware."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Machine", systemImage: "plus") { creatingMachine = true }
                        .disabled(library.isImporting || vm.isVMRunning || vm.isUnpacking)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                }
            }
        } detail: {
            if let selected {
                machineDetail(selected)
            } else {
                ContentUnavailableView("Select a virtual machine", systemImage: "desktopcomputer", description: Text("Windows runs locally using the existing ARM64 translation engine. A debugger-assisted JIT launch is required."))
            }
        }
        .task { library.refresh(); selectedID = library.machines.first?.id }
        .alert("New virtual machine", isPresented: $creatingMachine) {
            TextField("Name", text: $newMachineName)
            Button("Create") { selectedID = library.create(name: newMachineName)?.id }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This creates an empty configuration. Supply your own licensed Windows installation and firmware.")
        }
        .alert("Virtual machine", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            guard let selected else { return }
            switch result {
            case .success(let urls): if let url = urls.first { library.importMedia(url: url, kind: importKind, machine: selected) }
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $showSession, onDismiss: { library.refresh() }) {
            if let machine = library.machines.first(where: { $0.id == activeMachineID }) {
                IPadSessionView(vm: vm, configuration: Binding(get: {
                    library.machines.first(where: { $0.id == machine.id })?.configuration ?? machine.configuration
                }, set: { library.save($0, machine: machine) }))
            }
        }
    }

    private func machineDetail(_ machine: VMMachine) -> some View {
        Form {
            Section {
                Label(machine.configuration.name, systemImage: "desktopcomputer")
                    .font(.title2)
                LabeledContent("Secondary disk", value: machine.hasSecondaryDisk ? "Imported (read-only)" : "None")
                LabeledContent("Stored on device", value: ByteCountFormatter.string(fromByteCount: machine.storedBytes, countStyle: .file))
                Text(machine.directory.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if !machine.isReady {
                    Text("Required: \(machine.missingFiles.joined(separator: ", "))")
                        .foregroundStyle(.orange)
                }
                if library.isImporting { ProgressView("Copying media… Keep WindowsiOS open.") }
            }
            Section("Windows session") {
                Button(vm.isVMRunning ? "Return to Windows" : "Start Windows", systemImage: "play.fill") { launch(machine) }
                    .disabled(!machine.isReady || library.isImporting || vm.isUnpacking || (vm.isVMRunning && activeMachineID != machine.id))
                if vm.isVMRunning && activeMachineID != machine.id {
                    Text("Another machine is running. Select that machine to return to its session.").font(.caption).foregroundStyle(.secondary)
                }
                Text(vm.vmStatusText).foregroundStyle(.secondary)
                Text(vm.jitStatusText).font(.caption).foregroundStyle(.secondary)
                Text(WinIOSBridge.shared.runtimeCapabilityText).font(.caption).foregroundStyle(.secondary)
                if !vm.isJITLive {
                    Text("Launch with the supplied Mac debugger script. No iPad model has been verified by this build alone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Import media") {
                ForEach(VMMediaKind.allCases) { kind in
                    Button(kind.title, systemImage: "square.and.arrow.down") { importKind = kind; importing = true }
                        .disabled(vm.isVMRunning || vm.isUnpacking || library.isImporting)
                }
                Text("Files are copied into this machine. Existing firmware, NVRAM and disks are never replaced. Import a prepared raw Windows disk or an HVSPARSE archive, not an installer ISO.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("To manage or export files, open Files → On My iPad → WindowsiOS → Machines. Use a separate machine when importing replacement media.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VMConfigurationFields(configuration: Binding(get: {
                library.machines.first(where: { $0.id == machine.id })?.configuration ?? machine.configuration
            }, set: { library.save($0, machine: machine) }))
            .id(machine.id)
            .disabled(vm.isVMRunning || vm.isUnpacking || library.isImporting)
            Section("Storage and setup") {
                Text("Finder file sharing also supports Documents/Machines/Win11 with code.fd, vars.fd and windows11.img or windows11.hvsparse. Use the IPAD_INSTALLATION.md instructions to prepare media on a Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Close Windows normally before managing its files. Returning to the library leaves the current session running. After Windows stops, close and relaunch WindowsiOS before starting another session or switching machines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Machine")
    }

    private func launch(_ machine: VMMachine) {
        if vm.isVMRunning {
            guard activeMachineID == machine.id else { return }
            showSession = true
            return
        }
        let config = machine.configuration
        guard WinIOSBridge.shared.configureMachineDirectory(machine.directory.path, memoryMB: config.memoryMB, cpuCount: config.cpuCount, networkEnabled: config.networkEnabled, audioEnabled: config.audioEnabled) else {
            library.errorMessage = WinIOSBridge.shared.vmStatusText
            return
        }
        guard WinIOSBridge.shared.configureRuntimeOptions(config.runtimeOptions) else {
            library.errorMessage = WinIOSBridge.shared.vmStatusText
            return
        }
        UserDefaults.standard.set(config.commandToControl, forKey: "mapCommandToControl")
        UserDefaults.standard.set(config.pointerSensitivity, forKey: "pointerSensitivity")
        vm.trackpadMode = config.touchTrackpad
        activeMachineID = machine.id
        vm.startOrRetry()
        showSession = true
    }
}

struct VMConfigurationFields: View {
    @Binding var configuration: VMConfiguration
    @State private var hostPort = "0"
    @State private var guestPort = "0"
    @State private var portError: String?

    var body: some View {
        Group {
            Section("System") {
                Picker("Virtual CPUs", selection: $configuration.cpuCount) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Guest memory", selection: $configuration.memoryMB) {
                    Text("4 GiB").tag(UInt64(4096))
                    Text("4.25 GiB").tag(UInt64(4352))
                    Text("4.5 GiB").tag(UInt64(4608))
                }
                LabeledContent("Current device RAM limit", value: "\(WinIOSBridge.shared.maxGuestMemoryMB) MiB")
                Text("The runtime checks device memory and debugger allocation before launch. Requests require at least 4 GiB guest RAM plus host headroom and may be rejected. Configure memory before attaching the debugger.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage and sharing") {
                Toggle("Primary disk read-only", isOn: $configuration.primaryDiskReadOnly)
                Toggle("Share Documents/Shared with Windows", isOn: $configuration.sharedFolderEnabled)
                Text("Windows normally needs a writable primary disk. The optional secondary disk is always read-only. Shared files use the existing WebDAV server at http://10.0.2.4/; NAT networking must be enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Network") {
                Toggle("NAT networking", isOn: $configuration.networkEnabled)
                TextField("TCP host port", text: $hostPort).keyboardType(.numberPad)
                TextField("TCP Windows port", text: $guestPort).keyboardType(.numberPad)
                Button("Save TCP Forward") { saveForward() }
                Text("A single TCP forward listens on the iPad's loopback interface. Enter a host port from 1024 to 65535 and a guest port from 1 to 65535, or 0 for both to disable. Saved: \(configuration.tcpForwardHostPort) → \(configuration.tcpForwardGuestPort).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Display and audio") {
                Picker("Presentation frame rate", selection: $configuration.displayRefreshRate) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) Hz").tag($0) }
                }
                Text("The frame rate is a host presentation limit; it does not change the Windows resolution or promise the selected refresh rate on every display.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Guest audio", isOn: $configuration.audioEnabled)
                Toggle("Guest microphone", isOn: $configuration.microphoneEnabled)
                    .disabled(!configuration.audioEnabled)
                Text("Microphone access also requires iPadOS permission.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Input") {
                Toggle("Touch acts as a trackpad", isOn: $configuration.touchTrackpad)
                Toggle("Map Command to Control", isOn: $configuration.commandToControl)
                Text("When disabled, Command maps to the Windows key.").font(.caption).foregroundStyle(.secondary)
                Slider(value: $configuration.pointerSensitivity, in: 0.25...3, step: 0.25) {
                    Text("Trackpad sensitivity")
                } minimumValueLabel: { Text("Slow") } maximumValueLabel: { Text("Fast") }
            }
            Section("Diagnostics") {
                Toggle("Verbose engine logging", isOn: $configuration.diagnosticLogging)
                Text("Runtime changes apply on the next launch. Input preferences are stored per machine and can also be changed during a session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            hostPort = String(configuration.tcpForwardHostPort)
            guestPort = String(configuration.tcpForwardGuestPort)
        }
        .alert("TCP forward", isPresented: Binding(get: { portError != nil }, set: { if !$0 { portError = nil } })) {
            Button("OK") { portError = nil }
        } message: { Text(portError ?? "") }
    }

    private func saveForward() {
        guard let host = Int(hostPort), let guest = Int(guestPort) else {
            portError = "Enter a numeric host port from 1024 to 65535 and guest port from 1 to 65535, or 0 for both to disable."
            return
        }
        var updated = configuration
        updated.tcpForwardHostPort = host
        updated.tcpForwardGuestPort = guest
        do { configuration = try updated.validated() }
        catch { portError = error.localizedDescription }
    }
}
