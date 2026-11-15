// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

@main
struct WindowsiOSApp: App {
    @StateObject private var viewModel = VMViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    VMLibraryView(vm: viewModel)
                } else {
                    SessionView(vm: viewModel)
                }
            }
                .preferredColorScheme(.dark)
                .onAppear {
                    viewModel.onAppBecameActive()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        viewModel.onAppBecameActive()
                    } else if newPhase == .background {
                        WinIOSBridge.shared.flushDisks()
                    }
                }
        }
    }
}
