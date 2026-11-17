// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

enum VMSettingsCategory: String, CaseIterable, Identifiable {
    case information = "Information", system = "System", drives = "Drives"
    case display = "Display", input = "Input", network = "Network"
    case sharing = "Sharing", audio = "Audio", diagnostics = "Diagnostics"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .information: return "info.circle"
        case .system: return "cpu"
        case .drives: return "externaldrive"
        case .display: return "display"
        case .input: return "keyboard"
        case .network: return "network"
        case .sharing: return "folder.badge.person.crop"
        case .audio: return "speaker.wave.2"
        case .diagnostics: return "waveform.path.ecg"
        }
    }

    func summary(_ config: VMConfiguration, machine: VMMachine) -> String {
        switch self {
        case .information: return config.notes.isEmpty ? config.name : "Name and notes"
        case .system: return "\(config.cpuCount) CPUs · \(config.memoryMB) MiB"
        case .drives: return machine.hasSecondaryDisk ? "Primary and read-only secondary disk" : "Primary disk and installation media"
        case .display: return "\(config.displayResolution.title) · \(config.displayRefreshRate) Hz"
        case .input: return config.touchTrackpad ? "Touch trackpad" : "Direct touch"
        case .network:
            return config.networkEnabled ? (config.tcpForwardHostPort == 0 ? "NAT enabled" : "NAT and TCP forward") : "Disabled"
        case .sharing: return config.sharedFolderEnabled ? "Documents/Shared" : "Disabled"
        case .audio: return config.audioEnabled ? (config.microphoneEnabled ? "Speakers and microphone" : "Speakers") : "Disabled"
        case .diagnostics: return config.diagnosticLogging ? "Verbose logging enabled" : "Memory and runtime details"
        }
    }
}

struct VMSettingsOverview: View {
    let configuration: VMConfiguration
    let machine: VMMachine
    let onSave: (VMConfiguration) throws -> Void

    var body: some View {
        Section("Settings") {
            ForEach(VMSettingsCategory.allCases) { category in
                NavigationLink {
                    VMSettingsView(category: category, configuration: configuration, machine: machine, onSave: onSave)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.rawValue)
                            Text(category.summary(configuration, machine: machine))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: category.symbol) }
                }
                .accessibilityIdentifier("vm.settings.\(category.id.lowercased())")
            }
        }
    }
}

/// Each page owns a draft; validation and persistence finish before dismissal.
struct VMSettingsView: View {
    let category: VMSettingsCategory
    let machine: VMMachine
    let onSave: (VMConfiguration) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: VMConfiguration
    @State private var memoryText: String
    @State private var memoryError: String?
    @State private var hostPort: String
    @State private var guestPort: String
    @State private var saveError: String?

    init(category: VMSettingsCategory, configuration: VMConfiguration, machine: VMMachine,
         onSave: @escaping (VMConfiguration) throws -> Void) {
        self.category = category
        self.machine = machine
        self.onSave = onSave
        _draft = State(initialValue: configuration)
        _memoryText = State(initialValue: String(configuration.memoryMB))
        _hostPort = State(initialValue: String(configuration.tcpForwardHostPort))
        _guestPort = State(initialValue: String(configuration.tcpForwardGuestPort))
    }

    var body: some View {
        Form {
            switch category {
            case .information: information
            case .system: system
            case .drives: drives
            case .display: display
            case .input: input
            case .network: network
            case .sharing: sharing
            case .audio: audio
            case .diagnostics: diagnostics
            }
            Section {
                Text("Changes are saved when you tap Save and apply the next time this machine starts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(category.rawValue)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.bold() }
        }
        .alert("Settings could not be saved", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK") { saveError = nil }
        } message: { Text(saveError ?? "") }
    }

    private var information: some View {
        Group {
            Section("Virtual machine") {
                TextField("Name", text: $draft.name)
                    .accessibilityIdentifier("vm.settings.name")
                Text("Choose a name between 1 and 100 characters.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Notes") {
                TextEditor(text: $draft.notes).frame(minHeight: 160)
                    .accessibilityLabel("Machine notes")
                Text("\(draft.notes.count) of 20,000 characters")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Identity") {
                LabeledContent("Guest system", value: "Windows 11 ARM64")
                Text(machine.directory.lastPathComponent).font(.caption.monospaced()).textSelection(.enabled)
                Text("Renaming keeps this machine's disks and identity together.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var system: some View {
        Group {
            Section("Processor") {
                LabeledContent("Virtual CPU model", value: WinIOSBridge.shared.cpuModelName)
                Picker("Virtual CPUs", selection: $draft.cpuCount) {
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("TPM 2.0", value: "Enabled, with per-machine state")
            }
            Section("Memory") {
                TextField("Guest memory (MiB)", text: $memoryText)
                    .keyboardType(.numberPad).onSubmit { applyMemory() }
                    .accessibilityLabel("Guest memory in mebibytes")
                Button("Apply RAM allowance") { applyMemory() }
                LabeledContent("Selected guest memory", value: "\(draft.memoryMB) MiB")
                if let memoryError { Text(memoryError).font(.caption).foregroundStyle(.red) }
                LabeledContent("Physical device RAM", value: "\(WinIOSBridge.shared.physicalMemoryMB) MiB")
                LabeledContent("Maximum guest setting", value: "\(WinIOSBridge.shared.maxGuestMemoryMB) MiB")
                LabeledContent("App memory available now", value: "\(WinIOSBridge.shared.availableMemoryMB) MiB")
                Text("6144 MiB is 6 GiB; 8192 MiB is 8 GiB. The maximum setting leaves 3 GiB for iPadOS and the app. App memory available is the remaining allowance for this app, not free RAM across the iPad.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If the special memory reservation is unavailable, Windows uses a temporary file-backed mapping and needs the selected amount of free storage. iPadOS still controls memory pressure. You can adjust RAM after a reservation failure; after a VM has been created, close and reopen the app before changing it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var drives: some View {
        Group {
            Section("Primary disk") {
                LabeledContent("Interface", value: "NVMe")
                if draft.installationISO != nil {
                    LabeledContent("Virtual capacity", value: "\(draft.diskSizeGiB) GiB")
                }
                Toggle("Primary disk read-only", isOn: $draft.primaryDiskReadOnly)
                    .disabled(draft.installationISO != nil)
                Text("Windows normally needs a writable primary disk. Automatic installation requires writes to remain enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Attached media") {
                LabeledContent("Windows installation ISO", value: machine.hasInstallerISO ? "Attached" : "Not attached")
                LabeledContent("Secondary NVMe disk", value: machine.hasSecondaryDisk ? "Attached, read-only" : "Not attached")
                LabeledContent("Windows driver drive", value: "Included with the app")
                LabeledContent("Firmware", value: FileManager.default.fileExists(atPath: machine.directory.appendingPathComponent("code.fd").path) ? "Machine firmware" : "Included with WindowsiOS")
            }
            Section("Storage") {
                LabeledContent("Stored on device", value: ByteCountFormatter.string(fromByteCount: machine.storedBytes, countStyle: .file))
                Text("The virtual disk grows as Windows writes data. Shut down Windows before copying or exporting its machine folder, and keep the disk, firmware variables and TPM state together.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("UTM .utm bundles use a different runtime and cannot be imported directly. Advanced disk import accepts the prepared image formats listed on the machine page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var display: some View {
        Group {
            Section("Resolution") {
                Picker("Windows resolution", selection: $draft.displayResolution) {
                    ForEach(VMDisplayResolution.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Follow screen or window changes", isOn: $draft.dynamicResolution)
                Text("The bundled Windows display driver enables these modes. Native screen uses physical display pixels; Fit app window follows the viewport. Windows controls the active mode and can also change it in Display settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Presentation") {
                Picker("Frame rate", selection: $draft.displayRefreshRate) {
                    ForEach([30, 60, 120], id: \.self) { Text("\($0) Hz").tag($0) }
                }
                Text("This limits how often the app presents a frame. It does not promise that Windows or the display will reach that rate. 3D hardware acceleration is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var input: some View {
        Group {
            Section("Pointer") {
                Toggle("Touch acts as a trackpad", isOn: $draft.touchTrackpad)
                Slider(value: $draft.pointerSensitivity, in: 0.25...3, step: 0.25) {
                    Text("Trackpad sensitivity")
                } minimumValueLabel: { Text("Slow") } maximumValueLabel: { Text("Fast") }
                .accessibilityLabel("Trackpad sensitivity")
                Text("Direct touch taps the Windows pointer at that position. Trackpad mode moves the pointer relative to your finger.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Toggle("Map Command to Control", isOn: $draft.commandToControl)
                Text("When disabled, Command maps to the Windows key. In a session, the F keys button opens a row over Windows and hides it again without resizing the display. Typing keyboard opens the software keyboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var network: some View {
        Group {
            Section("Connection") {
                Toggle("NAT networking", isOn: $draft.networkEnabled)
                Text("Windows shares this iPad's internet connection. For an existing Windows installation, run InstallDrivers.cmd from the WindowsiOS driver drive as administrator once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("TCP port forward") {
                TextField("Host port", text: $hostPort).keyboardType(.numberPad)
                    .accessibilityLabel("TCP host port")
                TextField("Windows port", text: $guestPort).keyboardType(.numberPad)
                    .accessibilityLabel("TCP Windows port")
                Button("Apply TCP forward") {
                    do { try applyForward() } catch { saveError = error.localizedDescription }
                }
                LabeledContent("Selected forward", value: draft.tcpForwardHostPort == 0 ? "Disabled" : "\(draft.tcpForwardHostPort) → \(draft.tcpForwardGuestPort)")
                Text("One TCP forward listens on the iPad's loopback interface while NAT is enabled. Use host port 1024–65535 and Windows port 1–65535. Set both to 0 to disable forwarding.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sharing: some View {
        Section("Shared folder") {
            Toggle("Share Documents/Shared with Windows", isOn: $draft.sharedFolderEnabled)
            LabeledContent("Windows address", value: "http://10.0.2.4/")
            Text("Shared files live in Files → On My iPad → WindowsiOS → Shared. NAT networking must also be enabled for Windows to reach this folder.")
                .font(.caption).foregroundStyle(.secondary)
            if !draft.networkEnabled {
                Label("Enable NAT on the Network page to use sharing.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var audio: some View {
        Section("Sound") {
            Toggle("Guest audio", isOn: $draft.audioEnabled)
            Toggle("Guest microphone", isOn: $draft.microphoneEnabled).disabled(!draft.audioEnabled)
            Text("Microphone access also requires iPadOS permission. Disabling guest audio also disables microphone capture during the session.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var diagnostics: some View {
        Group {
            Section("Logging") {
                Toggle("Verbose engine logging", isOn: $draft.diagnosticLogging)
                Text("Detailed logs help investigate startup or guest failures and may affect performance.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Current app memory") {
                LabeledContent("Physical device RAM", value: "\(WinIOSBridge.shared.physicalMemoryMB) MiB")
                LabeledContent("App memory available now", value: "\(WinIOSBridge.shared.availableMemoryMB) MiB")
                LabeledContent("Reserved guest mapping", value: "\(WinIOSBridge.shared.guestReservedMemoryMB) MiB")
                Text(WinIOSBridge.shared.memoryStatusText).font(.caption).foregroundStyle(.secondary)
            }
            Section("Runtime") {
                Text(WinIOSBridge.shared.runtimeCapabilityText)
                Text(WinIOSBridge.shared.jitStatusText).font(.caption).foregroundStyle(.secondary)
                Text(WinIOSBridge.shared.vmStatusText).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func applyMemory() {
        do { try updateMemory() }
        catch { memoryError = error.localizedDescription }
    }

    private func updateMemory() throws {
        let text = memoryText.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = WinIOSBridge.shared.maxGuestMemoryMB
        guard let memory = UInt64(text), memory >= 4096, memory <= limit else {
            throw VMLibraryError.invalidMedia("Enter a whole number from 4096 to \(limit) MiB within this device's RAM limit.")
        }
        var updated = draft
        updated.memoryMB = memory
        draft = try updated.validated()
        memoryText = String(memory)
        memoryError = nil
    }

    private func applyForward() throws {
        guard let host = Int(hostPort.trimmingCharacters(in: .whitespacesAndNewlines)),
              let guest = Int(guestPort.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw VMLibraryError.invalidMedia("Enter numeric host and Windows ports, or 0 for both to disable forwarding.")
        }
        var updated = draft
        updated.tcpForwardHostPort = host
        updated.tcpForwardGuestPort = guest
        draft = try updated.validated()
        hostPort = String(host)
        guestPort = String(guest)
    }

    private func save() {
        do {
            if category == .system { try updateMemory() }
            if category == .network { try applyForward() }
            draft.name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let validated = try draft.validated()
            try onSave(validated)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }
}
