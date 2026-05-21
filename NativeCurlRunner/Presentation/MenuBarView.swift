import AppKit
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        Label(coordinator.state.statusTitle, systemImage: coordinator.state.statusIconName)
            .accessibilityIdentifier("menu-bar-status-item")
    }
}

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: coordinator.state.statusIconName)
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 2) {
                    Text(coordinator.state.statusTitle)
                        .font(.headline)
                        .accessibilityIdentifier("menu-bar-status-title")
                    Text(coordinator.state.statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("menu-bar-status-subtitle")
                }
            }

            Divider()

            Button("Rerun Last Request") {
                coordinator.rerunLastRequest()
            }
            .disabled(!coordinator.state.canRerun)
            .accessibilityIdentifier("rerun-last-request-menu-button")

            Button("Open Window") {
                coordinator.requestWindowOpen()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityIdentifier("open-main-window-menu-button")

            Divider()

            Button("Clear Workspace") {
                coordinator.newWorkspace()
            }
            .accessibilityIdentifier("new-workspace-menu-button")

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .accessibilityIdentifier("quit-menu-button")
        }
        .padding(12)
        .frame(width: 320)
        .accessibilityIdentifier("menu-bar-dropdown")
    }

    private var statusColor: Color {
        switch coordinator.state.statusTone {
        case .neutral:
            if coordinator.state.executionState == .running {
                return .orange
            }
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .red
        }
    }
}
