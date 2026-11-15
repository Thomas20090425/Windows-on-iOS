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
    @Published var isDeleting = false
    @Published var importStatus = "Copying media… Keep WindowsiOS open."
    let files: VMLibraryFiles
    var isBusy: Bool { isImporting || isDeleting }

    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        files = VMLibraryFiles(root: documents.appendingPathComponent("Machines", isDirectory: true))
    }

    func refresh() {
        do { machines = try files.machines() }
        catch { errorMessage = error.localizedDescription }
    }

    func create(name: String) -> VMMachine? {
        guard !isBusy else { return nil }
        do {
            let machine = try files.create(name: name)
            refresh()
            return machine
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func createFromISO(name: String, diskSizeGiB: Int, iso: URL, completion: @escaping (String?) -> Void) {
        guard !isBusy else { return }
        isImporting = true
        importStatus = "Importing the Windows ISO and creating your virtual disk… Keep WindowsiOS open."
        let files = self.files
        Task {
            let result = await Task.detached(priority: .utility) { () -> (String?, String?) in
                let scoped = iso.startAccessingSecurityScopedResource()
                defer { if scoped { iso.stopAccessingSecurityScopedResource() } }
                do {
                    let machine = try files.createFromISO(name: name, diskSizeGiB: diskSizeGiB, iso: iso)
                    return (machine.id, nil)
                } catch { return (nil, error.localizedDescription) }
            }.value
            isImporting = false
            if let error = result.1 { errorMessage = error }
            refresh()
            completion(result.0)
        }
    }

    func save(_ configuration: VMConfiguration, machine: VMMachine) {
        guard !isBusy else { return }
        do { try files.save(configuration, in: machine.directory); refresh() }
        catch { errorMessage = error.localizedDescription }
    }

    func importMedia(url: URL, kind: VMMediaKind, machine: VMMachine) {
        guard !isBusy else { return }
        isImporting = true
        importStatus = "Copying media… Keep WindowsiOS open."
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

    func delete(_ machine: VMMachine, completion: @escaping (Bool) -> Void) {
        guard !isBusy else { completion(false); return }
        // Recheck native ownership after confirmation, including stopped VMs
        // whose engine still owns disk handles until the app is relaunched.
        guard WinIOSBridge.shared.beginDeletingMachineDirectory(machine.directory.path) else {
            errorMessage = VMLibraryError.machineInUse.localizedDescription
            completion(false)
            return
        }
        isDeleting = true
        let files = self.files
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do { try files.deleteMachine(at: machine.directory); return nil }
                catch { return error.localizedDescription }
            }.value
            WinIOSBridge.shared.finishDeletingMachineDirectory(machine.directory.path)
            isDeleting = false
            if let failure { errorMessage = failure }
            refresh()
            completion(failure == nil)
        }
    }
}

struct VMLibraryView: View {
    @ObservedObject var vm: VMViewModel
    @StateObject private var library = VMLibraryStore()
    @State private var selectedID: String?
    @State private var creatingMachine = false
    @State private var importKind = VMMediaKind.disk
    @State private var importing = false
    @State private var showSession = false
    @State private var activeMachineID: String?
    @State private var machineToDelete: VMMachine?

    private var selected: VMMachine? { library.machines.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(library.machines) { machine in
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(machine.configuration.name)
                            Text(machine.isReady ? (machine.hasInstallerISO ? "Windows ISO attached" : "Ready") : "Setup incomplete")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "desktopcomputer") }
                    .tag(machine.id)
                    .contextMenu {
                        Button("Delete Virtual Machine…", systemImage: "trash", role: .destructive) { machineToDelete = machine }
                            .disabled(!canDelete(machine))
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { machineToDelete = machine }
                            .disabled(!canDelete(machine))
                    }
                }
            }
            .navigationTitle("Virtual Machines")
            .overlay {
                if library.machines.isEmpty {
                    ContentUnavailableView("Your Windows machines", systemImage: "desktopcomputer", description: Text("Import a Windows 11 ARM64 ISO. WindowsiOS includes the firmware and creates the Windows disk on your iPad."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Machine", systemImage: "plus") { creatingMachine = true }
                        .disabled(library.isBusy || vm.isVMRunning || vm.isUnpacking)
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
        .overlay {
            if library.isImporting {
                ProgressView(library.importStatus)
                    .padding(24).frame(maxWidth: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding()
            } else if library.isDeleting {
                ProgressView("Deleting virtual machine…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task { library.refresh(); selectedID = library.machines.first?.id }
        .sheet(isPresented: $creatingMachine) {
            NewWindowsMachineView { name, diskSizeGiB, iso in
                library.createFromISO(name: name, diskSizeGiB: diskSizeGiB, iso: iso) { identifier in
                    if let identifier { selectedID = identifier }
                }
            }
        }
        .alert("Virtual machine", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK") { library.errorMessage = nil }
        } message: { Text(library.errorMessage ?? "") }
        .alert("Delete virtual machine?", isPresented: Binding(get: { machineToDelete != nil }, set: { if !$0 { machineToDelete = nil } }), presenting: machineToDelete) { machine in
            Button("Delete", role: .destructive) { deleteConfirmed(machine) }
            Button("Cancel", role: .cancel) { machineToDelete = nil }
        } message: { machine in
            Text("Delete “\(machine.configuration.name)” permanently? Its virtual disks, imported ISO copy, firmware variables, TPM state and configuration will be removed. Your original ISO and other machines are kept.")
        }
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
                LabeledContent("Windows installation ISO", value: machine.hasInstallerISO ? "Imported" : "Not attached")
                LabeledContent("Firmware", value: FileManager.default.fileExists(atPath: machine.directory.appendingPathComponent("code.fd").path) ? "Machine firmware" : "Included with WindowsiOS")
                if machine.configuration.installationISO != nil {
                    LabeledContent("Virtual disk capacity", value: "\(machine.configuration.diskSizeGiB) GiB")
                }
                LabeledContent("Secondary disk", value: machine.hasSecondaryDisk ? "Imported (read-only)" : "None")
                LabeledContent("Stored on device", value: ByteCountFormatter.string(fromByteCount: machine.storedBytes, countStyle: .file))
                Text(machine.directory.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if !machine.isReady {
                    Text("Required: \(machine.missingFiles.joined(separator: ", "))")
                        .foregroundStyle(.orange)
                }
                if library.isImporting { ProgressView(library.importStatus) }
            }
            Section("Windows session") {
                Button(vm.isVMRunning ? "Return to Windows" : "Start Windows", systemImage: "play.fill") { launch(machine) }
                    .disabled(!machine.isReady || library.isBusy || vm.isUnpacking || (vm.isVMRunning && activeMachineID != machine.id))
                if vm.isVMRunning && activeMachineID != machine.id {
                    Text("Another machine is running. Select that machine to return to its session.").font(.caption).foregroundStyle(.secondary)
                }
                Text(vm.vmStatusText).foregroundStyle(.secondary)
                Text(vm.jitStatusText).font(.caption).foregroundStyle(.secondary)
                Text(WinIOSBridge.shared.runtimeCapabilityText).font(.caption).foregroundStyle(.secondary)
                if !vm.isJITLive {
                    Button("Enable JIT on Device", systemImage: "bolt.fill") { vm.requestStikDebugJIT() }
                        .disabled(library.isBusy || vm.isUnpacking)
                    Text("Use StikDebug or the supplied Mac JIT helper. Xcode Run alone cannot initialize JIT. No iPad model has been verified by this build alone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Windows setup") {
                Text("For a new installation, supply only your Windows 11 ARM64 ISO. The app supplies UEFI firmware, creates a private variable store and creates the writable Windows disk on your iPad.")
                    .font(.caption).foregroundStyle(.secondary)
                if machine.hasInstallerISO {
                    Text("Windows setup installs the first Windows edition included in the ISO onto this machine's new disk. Windows may ask for license, region or account details inside the guest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Advanced disk import") {
                    ForEach(machine.hasInstallerISO ? [] : VMMediaKind.allCases) { kind in
                        Button(kind.title, systemImage: "square.and.arrow.down") { importKind = kind; importing = true }
                            .disabled(vm.isVMRunning || vm.isUnpacking || library.isBusy)
                    }
                    Text(machine.hasInstallerISO ? "Automatic setup manages this machine's disks. Create a separate machine to install from another ISO." : "For existing installations only. Existing disks are never replaced; create a separate machine to install from another ISO.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VMConfigurationFields(configuration: Binding(get: {
                library.machines.first(where: { $0.id == machine.id })?.configuration ?? machine.configuration
            }, set: { library.save($0, machine: machine) }))
            .id(machine.id)
            .disabled(vm.isVMRunning || vm.isUnpacking || library.isBusy)
            Section("Storage and setup") {
                Text("The virtual disk grows as Windows writes data, up to its selected capacity. Keep sufficient free iPad storage for installation and updates. Manage or export machines through Files → On My iPad → WindowsiOS → Machines after shutting down Windows.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Close Windows normally before managing its files. Returning to the library leaves the current session running. After Windows stops, close and relaunch WindowsiOS before starting another session or switching machines.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Delete Virtual Machine…", systemImage: "trash", role: .destructive) { machineToDelete = machine }
                    .disabled(!canDelete(machine))
                if !WinIOSBridge.shared.canDeleteMachineDirectory(machine.directory.path) {
                    Text("This machine is still in use. Stop Windows and relaunch WindowsiOS to release its files before deleting it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Machine")
    }

    private func launch(_ machine: VMMachine) {
        guard !library.isBusy, !vm.isUnpacking else { return }
        guard !library.isBusy else { return }
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

    private func canDelete(_ machine: VMMachine) -> Bool {
        !library.isBusy && !vm.isUnpacking && !(vm.isVMRunning && activeMachineID == machine.id) &&
            WinIOSBridge.shared.canDeleteMachineDirectory(machine.directory.path)
    }

    private func deleteConfirmed(_ machine: VMMachine) {
        machineToDelete = nil
        guard canDelete(machine) else { return }
        library.delete(machine) { deleted in
            guard deleted else { return }
            if activeMachineID == machine.id { activeMachineID = nil }
            if selectedID == machine.id { selectedID = library.machines.first?.id }
        }
    }
}

struct VMConfigurationFields: View {
    @Binding var configuration: VMConfiguration
    @State private var memoryText = "4096"
    @State private var memoryError: String?
    @State private var hostPort = "0"
    @State private var guestPort = "0"
    @State private var portError: String?

    var body: some View {
        Group {
            Section("System") {
                Picker("Virtual CPUs", selection: $configuration.cpuCount) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                TextField("Guest memory (MiB)", text: $memoryText)
                    .keyboardType(.numberPad)
                    .onSubmit { saveMemory() }
                    .accessibilityLabel("Guest memory in mebibytes")
                Button("Apply RAM allowance") { saveMemory() }
                LabeledContent("Saved guest memory", value: "\(configuration.memoryMB) MiB")
                if let memoryError { Text(memoryError).foregroundStyle(.red).font(.caption) }
                LabeledContent("Current device RAM limit", value: "\(WinIOSBridge.shared.maxGuestMemoryMB) MiB")
                LabeledContent("TPM 2.0", value: "Enabled, with per-VM state")
                Text("Enter any whole number of MiB, such as 6144 for 6 GiB. Windows 11 requires at least 4096 MiB. The device limit leaves 3 GiB for iPadOS and the app. Apply memory changes before starting JIT; changing an existing reservation requires relaunching the app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Storage and sharing") {
                Toggle("Primary disk read-only", isOn: $configuration.primaryDiskReadOnly)
                    .disabled(configuration.installationISO != nil)
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
            memoryText = String(configuration.memoryMB)
            hostPort = String(configuration.tcpForwardHostPort)
            guestPort = String(configuration.tcpForwardGuestPort)
        }
        .alert("TCP forward", isPresented: Binding(get: { portError != nil }, set: { if !$0 { portError = nil } })) {
            Button("OK") { portError = nil }
        } message: { Text(portError ?? "") }
    }

    private func saveMemory() {
        let text = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = WinIOSBridge.shared.maxGuestMemoryMB
        guard let memory = UInt64(text), memory >= 4096, memory <= limit else {
            memoryError = "Enter a whole number from 4096 to \(limit) MiB within this device's RAM limit."
            return
        }
        var updated = configuration
        updated.memoryMB = memory
        do {
            configuration = try updated.validated()
            memoryText = String(memory)
            memoryError = nil
        } catch { memoryError = error.localizedDescription }
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
