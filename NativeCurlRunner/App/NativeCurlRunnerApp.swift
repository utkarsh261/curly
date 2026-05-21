import AppKit
import SwiftUI

@main
struct NativeCurlRunnerApp: App {
    @StateObject private var coordinator = SessionCoordinator()
#if DEBUG
    @State private var didApplyUITestURLBarInput = false
#endif

    var body: some Scene {
        WindowGroup(id: "main") {
            WorkspaceRootView()
                .environmentObject(coordinator)
                .onAppear {
                    coordinator.setWindowVisible(true)
#if DEBUG
                    applyUITestURLBarInputIfNeeded()
#endif
                }
                .onDisappear {
                    coordinator.setWindowVisible(false)
                }
        }
        .commands {
            WorkspaceCommands(coordinator: coordinator)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(coordinator)
        } label: {
            MenuBarLabelView()
                .environmentObject(coordinator)
        }
        .menuBarExtraStyle(.menu)
    }

#if DEBUG
    private func applyUITestURLBarInputIfNeeded() {
        guard !didApplyUITestURLBarInput else {
            return
        }

        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--ui-test-url-bar-input"),
              arguments.indices.contains(index + 1) else {
            return
        }

        didApplyUITestURLBarInput = true
        coordinator.handleURLBarTextChange(arguments[index + 1])
    }
#endif
}

struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: SessionCoordinator

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("New Workspace") {
                coordinator.newWorkspace()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open Main Window") {
                coordinator.requestWindowOpen()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }
}
