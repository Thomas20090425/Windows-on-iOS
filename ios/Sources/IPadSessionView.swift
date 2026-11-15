// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// A resizable iPad viewport over the same native Metal/USB path used by Duo.
struct IPadSessionView: View {
    @ObservedObject var vm: VMViewModel
    @Binding var configuration: VMConfiguration
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var controlsVisible = true
    @State private var settingsVisible = false
    @State private var confirmStop = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            MetalDisplayView(
                trackpadMode: $vm.trackpadMode,
                rightClickArmed: $vm.rightClickArmed,
                keyboardVisible: $vm.systemKeyboardVisible,
                onThreeFingerTap: { withAnimation { controlsVisible.toggle() } },
                inputEnabled: vm.isVMRunning && !settingsVisible && !confirmStop && vm.activeSafariURL == nil && scenePhase == .active
            )
            .accessibilityLabel("Windows guest display")

            if !vm.isVMRunning { startupStatus.padding(24).frame(maxWidth: 480).frame(maxHeight: .infinity) }
            VStack {
                if controlsVisible {
                    controls.padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 12).padding(.top, 8)
                } else {
                    HStack {
                        Spacer()
                        Button("Show controls", systemImage: "ellipsis") { withAnimation { controlsVisible = true } }
                            .labelStyle(.iconOnly).padding(12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(12)
                    }
                }
                Spacer()
            }
        }
        .task(id: controlsVisible && vm.isVMRunning) {
            guard controlsVisible && vm.isVMRunning else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !settingsVisible, !confirmStop else { return }
            withAnimation { controlsVisible = false }
        }
        .sheet(isPresented: $settingsVisible) {
            NavigationStack {
                Form {
                    Section("Input") {
                        Toggle("Touch acts as a trackpad", isOn: $configuration.touchTrackpad)
                        Toggle("Map Command to Control", isOn: $configuration.commandToControl)
                        Text("When disabled, Command maps to the Windows key.").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $configuration.pointerSensitivity, in: 0.25...3, step: 0.25) {
                            Text("Trackpad sensitivity")
                        } minimumValueLabel: { Text("Slow") } maximumValueLabel: { Text("Fast") }
                        .accessibilityLabel("Trackpad sensitivity")
                        Text("Direct touch taps and drags the Windows pointer. Trackpad mode moves it relative to your finger. Two-finger tap sends a right-click; two-finger movement scrolls. Pinch to zoom the host viewport, then use two fingers to pan while zoomed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("External keyboards send physical keys to Windows. iPadOS reserves some system shortcuts. Open this sheet or return to the library to release guest input focus.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Session diagnostics") {
                        LabeledContent("Network", value: WinIOSBridge.shared.networkStatusText)
                        LabeledContent("JIT", value: vm.isJITLive ? "Ready" : "Unavailable")
                        LabeledContent("Guest framebuffer", value: "\(vm.fbWidth) × \(vm.fbHeight)")
                        LabeledContent("Presented frames", value: "\(vm.presentedFrames)")
                        LabeledContent("Available process memory", value: "\(vm.availableMemoryMB) MiB")
                        LabeledContent("USB keyboard", value: vm.usbKeyboardReady ? "Configured" : "Waiting for guest")
                        LabeledContent("USB tablet", value: vm.usbTabletReady ? "Configured" : "Waiting for guest")
                        LabeledContent("USB events delivered", value: "\(vm.usbEventsDelivered)")
                        Text("After Windows stops, close and relaunch WindowsiOS before starting another session or switching machines.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(vm.vmStatusText).font(.caption)
                        Text(vm.jitStatusText).font(.caption)
                    }
                    Section("Display") {
                        Text("The guest framebuffer keeps its aspect ratio as the iPad window changes size. Change Windows display settings inside the guest.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Session settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settingsVisible = false } } }
            }
            .presentationDetents([.large])
        }
        .alert("Force stop Windows?", isPresented: $confirmStop) {
            Button("Force Stop", role: .destructive) { WinIOSBridge.shared.stopVM(); vm.syncFromBridge() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved work may be lost. Use Shut Down in Windows or Request Shutdown first.")
        }
        .sheet(item: $vm.activeSafariURL) { item in SafariSheet(url: item.url) }
        .onChange(of: configuration.touchTrackpad) { _, value in vm.trackpadMode = value }
        .onChange(of: configuration.commandToControl) { _, value in UserDefaults.standard.set(value, forKey: "mapCommandToControl") }
        .onChange(of: configuration.pointerSensitivity) { _, value in UserDefaults.standard.set(value, forKey: "pointerSensitivity") }
        .onDisappear { vm.systemKeyboardVisible = false }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                libraryButton
                Divider().frame(height: 24)
                Button("Keyboard", systemImage: "keyboard") { vm.systemKeyboardVisible.toggle() }
                shortcutMenu
                powerMenu
                Spacer(minLength: 0)
                Button("Settings", systemImage: "gearshape") { settingsVisible = true }
                hideButton
            }
            HStack(spacing: 12) {
                libraryButton.labelStyle(.iconOnly)
                Button("Keyboard", systemImage: "keyboard") { vm.systemKeyboardVisible.toggle() }.labelStyle(.iconOnly)
                shortcutMenu.labelStyle(.iconOnly)
                powerMenu.labelStyle(.iconOnly)
                Spacer(minLength: 0)
                Button("Settings", systemImage: "gearshape") { settingsVisible = true }.labelStyle(.iconOnly)
                hideButton.labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    private var libraryButton: some View {
        Button("Library", systemImage: "square.grid.2x2") {
            vm.systemKeyboardVisible = false
            dismiss()
        }
    }

    private var hideButton: some View {
        Button("Hide controls", systemImage: "chevron.up") { withAnimation { controlsVisible = false } }
    }

    private var shortcutMenu: some View {
        Menu("Shortcuts", systemImage: "command") {
            Button("Windows key") { WinIOSBridge.shared.sendWindowsKey() }
            Button("Ctrl+Alt+Delete") { WinIOSBridge.shared.sendCtrlAltDel() }
            Button("Alt+Tab") { WinIOSBridge.shared.sendAltTab() }
            Button("Escape") { WinIOSBridge.shared.sendEscape() }
            Button("Right click next tap") { vm.rightClickArmed = true }
        }.disabled(!vm.isVMRunning)
    }

    private var powerMenu: some View {
        Menu("Power", systemImage: "power") {
            Button("Request Shutdown") { WinIOSBridge.shared.pressPowerButton() }
            Button("Flush disk writes") { WinIOSBridge.shared.flushDisks() }
            Button("Force Stop…", role: .destructive) { confirmStop = true }
        }.disabled(!vm.isVMRunning)
    }

    private var startupStatus: some View {
        VStack(spacing: 16) {
            Image(systemName: "desktopcomputer").font(.largeTitle)
            Text("Windows 11 ARM64").font(.title2.bold())
            Text(vm.vmStatusText).multilineTextAlignment(.center)
            Text(vm.jitStatusText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if vm.isUnpacking { ProgressView(value: vm.unpackProgress) }
            if !vm.isUnpacking {
                if !vm.isJITLive {
                    Button("Enable JIT on Device", systemImage: "bolt.fill") { vm.requestStikDebugJIT() }
                        .buttonStyle(.bordered)
                }
                Button("Retry Start", systemImage: "play.fill") { vm.startOrRetry() }
                    .buttonStyle(.borderedProminent)
                Text("Use StikDebug or the Mac JIT launch helper before starting Windows. Xcode Run alone cannot initialize JIT.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
