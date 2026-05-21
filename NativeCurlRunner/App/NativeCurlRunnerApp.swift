import AppKit
import SwiftUI

@main
struct NativeCurlRunnerApp: App {
    @StateObject private var coordinator: SessionCoordinator
#if DEBUG
    @State private var didApplyUITestURLBarInput = false
#endif

    init() {
        _coordinator = StateObject(wrappedValue: Self.makeCoordinator())
    }

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

private extension NativeCurlRunnerApp {
    static func makeCoordinator() -> SessionCoordinator {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-stub-executor") {
            return SessionCoordinator(requestExecutor: UITestEchoRequestExecutor())
        }
#endif
        return SessionCoordinator()
    }
}

#if DEBUG
private struct UITestEchoRequestExecutor: RequestExecuting {
    func execute(_ request: Request) async throws -> ExecutedResponse {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-stub-failure") {
            throw ExecutionError.transport("UI test transport failure")
        }

        let headerLines = request.headers
            .filter(\.isEnabled)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "\n")
        let bodyText = [
            "method=\(request.method.rawValue)",
            "url=\(request.urlString)",
            headerLines
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        return ExecutedResponse(
            request: request,
            statusCode: 200,
            headers: [ResponseHeader(name: "Content-Type", value: "text/plain")],
            bodyData: Data(bodyText.utf8),
            mimeType: "text/plain",
            duration: 0.001,
            timestamp: Date(timeIntervalSince1970: 100)
        )
    }
}
#endif

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
