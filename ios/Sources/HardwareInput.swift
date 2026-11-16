// SPDX-License-Identifier: GPL-2.0-or-later
import GameController
import SwiftUI

@MainActor
final class HardwareKeyboardState: NSObject, ObservableObject {
    static let shared = HardwareKeyboardState()
    @Published private(set) var isConnected = GCKeyboard.coalesced != nil

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged), name: .GCKeyboardDidDisconnect, object: nil)
    }

    @objc private func keyboardChanged() { isConnected = GCKeyboard.coalesced != nil }
    deinit { NotificationCenter.default.removeObserver(self) }
}

/// Actual guest F keys, also usable with modifiers held on a physical keyboard.
struct GuestFunctionKeyRow: View {
    var enabled = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(1...12, id: \.self) { number in
                    Button("F\(number)") { WinIOSBridge.shared.tapKeyHid(UInt8(0x39 + number)) }
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                        .frame(minWidth: 38, minHeight: 36)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Function key \(number)")
                }
            }.padding(8)
        }
        .frame(height: 52)
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Windows function keys")
    }
}

/// Attach with `overlay`, so opening the keys never changes the guest viewport.
struct GuestFunctionKeyOverlay: View {
    var enabled = true
    @State private var isExpanded = false

    var body: some View {
        HStack {
            if isExpanded {
                HStack(spacing: 0) {
                    GuestFunctionKeyRow(enabled: enabled)
                    Button("Hide function keys", systemImage: "chevron.down") {
                        withAnimation { isExpanded = false }
                    }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .accessibilityHint("Keep Windows at full size and hide the key overlay.")
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(maxWidth: 780)
            } else {
                Spacer(minLength: 0)
                Button("F keys", systemImage: "keyboard") {
                    withAnimation { isExpanded = true }
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel("Show function keys")
                .accessibilityHint("Show F1 through F12 over the Windows display.")
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
    }
}
