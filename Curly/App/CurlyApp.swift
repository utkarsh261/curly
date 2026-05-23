import AppKit
import SwiftUI

@main
struct CurlyApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleDelegate.self) private var appDelegate
    @StateObject private var coordinator: SessionCoordinator
#if DEBUG
    @State private var didApplyUITestURLBarInput = false
#endif

    init() {
        let createdCoordinator = Self.makeCoordinator()
        _coordinator = StateObject(wrappedValue: createdCoordinator)
        appDelegate.coordinatorProvider = { createdCoordinator }
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
        coordinator.handleURLBarPaste(arguments[index + 1])
    }
#endif
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    var coordinatorProvider: (() -> SessionCoordinator?)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = coordinatorProvider?() else {
            return .terminateNow
        }

        Task {
            await coordinator.waitForPendingPersistence()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private extension CurlyApp {
    static func makeCoordinator() -> SessionCoordinator {
        let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
        if arguments.contains("--ui-test-stub-executor") {
            return SessionCoordinator(
                requestExecutor: UITestEchoRequestExecutor(),
                requestLibrary: makeRequestLibraryDependencies(arguments: arguments)
            )
        }
#endif
        return SessionCoordinator(requestLibrary: makeRequestLibraryDependencies(arguments: arguments))
    }

    static func makeRequestLibraryDependencies(arguments: [String]) -> RequestLibraryDependencies? {
#if DEBUG
        if arguments.contains("--ui-test-mode"), !arguments.contains("--ui-test-enable-persistence") {
            return nil
        }
#endif
        do {
            let fileURL: URL
#if DEBUG
            if let index = arguments.firstIndex(of: "--ui-test-library-file"),
               arguments.indices.contains(index + 1) {
                fileURL = URL(fileURLWithPath: arguments[index + 1])
            } else {
                fileURL = try FileRequestLibraryRepositories.defaultFileURL()
            }
#else
            fileURL = try FileRequestLibraryRepositories.defaultFileURL()
#endif
            let repositories = try FileRequestLibraryRepositories(fileURL: fileURL)
            return RequestLibraryDependencies(
                savedRequests: repositories,
                drafts: repositories,
                hiddenDraft: repositories,
                summaries: repositories,
                selection: repositories,
                workspaceFacade: repositories
            )
        } catch {
#if DEBUG
            print("Curly persistence init failed: \(error.localizedDescription)")
#endif
            return nil
        }
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
                coordinator.createOrFocusHiddenNewDraft()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Save Request") {
                coordinator.saveCurrentRequest()
            }
            .keyboardShortcut("s", modifiers: [.command])

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
