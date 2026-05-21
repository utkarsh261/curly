import AppKit
import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator

    var body: some View {
        Label(coordinator.state.statusTitle, systemImage: coordinator.state.statusIconName)
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
                    Text(coordinator.state.statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            Button("Rerun Last Request") {
                coordinator.rerunLastRequest()
            }
            .disabled(!coordinator.state.canRerun)

            Button("Open Main Window") {
                coordinator.requestWindowOpen()
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 320)
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
