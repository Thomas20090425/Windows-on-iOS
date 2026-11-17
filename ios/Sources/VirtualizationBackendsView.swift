// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// A launch hub for independently installed virtualization apps.
struct VirtualizationBackendsView: View {
    let canOpenCompanions: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var availableBackends = Set<CompanionBackend>()
    @State private var launchError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("WindowsiOS") {
                    Label("Windows 11 ARM64", systemImage: "desktopcomputer")
                        .font(.headline)
                    Text("The current library uses WindowsiOS's ARM64 engine. Configure its machines from the settings pages in this app.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Section("Companion apps") {
                    ForEach(CompanionBackend.allCases) { backend in
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent {
                                Text(availableBackends.contains(backend) ? "Available" : "Not installed")
                                    .font(.caption).foregroundStyle(.secondary)
                            } label: {
                                Label(backend.title, systemImage: backend.symbol).font(.headline)
                            }
                            Text(backend.description).font(.callout).foregroundStyle(.secondary)
                            Button("Open \(backend.title)", systemImage: "arrow.up.forward.app") {
                                open(backend)
                            }
                            .disabled(!canOpenCompanions || !availableBackends.contains(backend))
                            .accessibilityIdentifier("engines.open.\(backend.rawValue)")
                        }
                        .padding(.vertical, 6)
                    }
                }
                Section {
                    Text("Each companion app has its own virtual machines, files and settings. Open .utm bundles in UTM. The companion engines run in their respective apps.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !canOpenCompanions {
                        Label("Shut down Windows and finish any file operation before opening another engine.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Engines")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { refreshAvailability() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshAvailability() }
            }
            .alert("Could not open companion app", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
                Button("OK") { launchError = nil }
            } message: { Text(launchError ?? "") }
        }
    }

    private func refreshAvailability() {
        availableBackends = Set(CompanionBackend.allCases.filter { UIApplication.shared.canOpenURL($0.url) })
    }

    private func open(_ backend: CompanionBackend) {
        guard canOpenCompanions else { return }
        guard UIApplication.shared.canOpenURL(backend.url) else {
            refreshAvailability()
            launchError = "\(backend.title) is not installed or cannot handle its launch link."
            return
        }
        UIApplication.shared.open(backend.url, options: [:]) { opened in
            if !opened { launchError = "\(backend.title) could not be opened. Check that the companion app is installed." }
        }
    }
}

private enum CompanionBackend: String, CaseIterable, Identifiable {
    case utm, henge
    var id: String { rawValue }
    var url: URL { URL(string: "\(rawValue)://")! }
    var title: String { self == .utm ? "UTM" : "Henge" }
    var symbol: String { self == .utm ? "square.stack.3d.up" : "macwindow" }
    var description: String {
        switch self {
        case .utm:
            return "Open UTM's machine library, configuration pages and supported virtual machines, including .utm bundles."
        case .henge:
            return "Restore and run a virtual Mac with Henge's macOS engine and Metal graphics support. macOS setup and its disk are managed inside Henge."
        }
    }
}
