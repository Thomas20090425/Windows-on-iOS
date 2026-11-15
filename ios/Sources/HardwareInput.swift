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
        .buttonStyle(.plain)
        .background(.ultraThinMaterial)
        .disabled(!enabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Windows function keys")
    }
}
