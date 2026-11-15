// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

struct NewWindowsMachineView: View {
    let onSelectISO: (String, Int, URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Windows 11 ARM64"
    @State private var diskSizeGiB = 64
    @State private var selectingISO = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Virtual machine") {
                    TextField("Name", text: $name)
                    Picker("Windows disk capacity", selection: $diskSizeGiB) {
                        ForEach([64, 96, 128, 256, 512], id: \.self) { Text("\($0) GiB").tag($0) }
                    }
                    Text("WindowsiOS creates a writable disk using this iPad's storage. The disk grows as Windows writes data, up to the selected capacity. At least 32 GiB of free installation headroom is required in addition to the imported ISO.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Windows installation media") {
                    Button("Import Windows ISO and Create", systemImage: "opticaldisc") { selectingISO = true }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 100)
                    Text("Choose your Windows 11 ARM64 installation ISO. UEFI firmware is included with the app, and each machine gets its own automatic firmware variable store. You do not need to find or import either file.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Installation") {
                    Text("After you start the machine with JIT available, setup installs the first Windows edition included in the ISO onto the new disk. Windows may request license, region or account details inside the guest.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Install Windows")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fileImporter(isPresented: $selectingISO, allowedContentTypes: [UTType(filenameExtension: "iso") ?? .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let iso = urls.first else { return }
                    let requestedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    dismiss()
                    onSelectISO(requestedName, diskSizeGiB, iso)
                case .failure(let error): importError = error.localizedDescription
                }
            }
            .alert("Windows ISO", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
        }
    }
}
