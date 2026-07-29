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
                .background(WorkspaceWindowMarker())
                .onAppear {
                    coordinator.setWindowVisible(true)
#if DEBUG
                    applyUITestURLBarInputIfNeeded()
#endif
                }
                .onDisappear {
                    coordinator.setWindowVisible(false)
                }
                .onChange(of: coordinator.state.isLibraryCollapsed) { _, isCollapsed in
                    SidebarVisibilityPreferences.save(isCollapsed, arguments: ProcessInfo.processInfo.arguments)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            WorkspaceCommands(coordinator: coordinator)
            HelpCommands()
        }

        WindowGroup(id: "help") {
            HelpView()
        }
        .windowResizability(.contentSize)

        Settings {
            TLSVerificationSettingsView()
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

private struct TLSVerificationSettingsView: View {
    @AppStorage(TLSVerificationPreferences.allowInsecureLoopbackHostsKey)
    private var allowsInsecureLoopbackTLS = false

    var body: some View {
        Form {
            Section("Security") {
                Toggle(
                    "Skip TLS certificate verification for loopback hosts",
                    isOn: $allowsInsecureLoopbackTLS
                )
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("allow-insecure-loopback-tls-checkbox")

                Text("Applies to localhost, *.localhost, 127.0.0.0/8, and ::1. Other hosts continue using normal certificate verification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 180)
    }
}

final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    enum RequestNavigationKeyEventAction: Equatable {
        case passThrough
        case navigate
        case suppressRepeat
    }

    var coordinatorProvider: (() -> SessionCoordinator?)?
    private var requestNavigationEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestNavigationEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let canNavigate = MainActor.assumeIsolated {
                self.coordinatorProvider?()?.canUseLastVisitedRequestShortcut == true
            }
            let action = Self.requestNavigationAction(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                isRepeat: event.isARepeat,
                isWorkspaceWindow: event.window?.containsWorkspaceWindowMarker == true,
                canNavigate: canNavigate
            )

            switch action {
            case .passThrough:
                return event
            case .suppressRepeat:
                return nil
            case .navigate:
                MainActor.assumeIsolated {
                    self.coordinatorProvider?()?.selectLastVisitedRequest()
                }
                return nil
            }
        }
    }

    static func requestNavigationAction(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isRepeat: Bool,
        isWorkspaceWindow: Bool,
        canNavigate: Bool
    ) -> RequestNavigationKeyEventAction {
        let modifiers = modifierFlags.intersection([.command, .control, .option, .shift])
        guard keyCode == 48,
              modifiers == .control,
              isWorkspaceWindow,
              canNavigate else {
            return .passThrough
        }
        return isRepeat ? .suppressRepeat : .navigate
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator = coordinatorProvider?() else {
            return .terminateNow
        }

        Task {
            await coordinator.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let requestNavigationEventMonitor {
            NSEvent.removeMonitor(requestNavigationEventMonitor)
        }
        requestNavigationEventMonitor = nil
    }
}

private struct WorkspaceWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> WorkspaceWindowMarkerView {
        WorkspaceWindowMarkerView()
    }

    func updateNSView(_ nsView: WorkspaceWindowMarkerView, context: Context) {}
}

private final class WorkspaceWindowMarkerView: NSView {}

private extension NSWindow {
    var containsWorkspaceWindowMarker: Bool {
        contentView?.containsWorkspaceWindowMarker == true
    }
}

private extension NSView {
    var containsWorkspaceWindowMarker: Bool {
        if self is WorkspaceWindowMarkerView {
            return true
        }
        return subviews.contains { $0.containsWorkspaceWindowMarker }
    }
}

private extension CurlyApp {
    static func makeCoordinator() -> SessionCoordinator {
        let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
        if arguments.contains("--ui-test-mode") {
            UserDefaults.standard.removeObject(
                forKey: TLSVerificationPreferences.allowInsecureLoopbackHostsKey
            )
        }
#endif
        var initialState = SessionState.initial
        if let isCollapsed = SidebarVisibilityPreferences.load(arguments: arguments) {
            initialState.isLibraryCollapsed = isCollapsed
        }
        let coordinator: SessionCoordinator
#if DEBUG
        if arguments.contains("--ui-test-stub-executor") {
            coordinator = SessionCoordinator(
                initialState: initialState,
                requestExecutor: UITestEchoRequestExecutor(),
                requestLibrary: makeRequestLibraryDependencies(arguments: arguments)
            )
        } else {
            coordinator = SessionCoordinator(
                initialState: initialState,
                requestLibrary: makeRequestLibraryDependencies(arguments: arguments)
            )
        }

        return coordinator
#else
        coordinator = SessionCoordinator(
            initialState: initialState,
            requestLibrary: makeRequestLibraryDependencies(arguments: arguments)
        )
        return coordinator
#endif
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
            if let index = arguments.firstIndex(of: "--ui-test-library-id"),
               arguments.indices.contains(index + 1) {
                let appSupport = try FileManager.default.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                fileURL = appSupport
                    .appendingPathComponent("Curly/UITests", isDirectory: true)
                    .appendingPathComponent("\(arguments[index + 1]).json")
            } else if let index = arguments.firstIndex(of: "--ui-test-library-file"),
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
                workspaceFacade: repositories,
                variables: repositories
            )
        } catch {
#if DEBUG
            print("Curly persistence init failed: \(error.localizedDescription)")
#endif
            return nil
        }
    }
}

private enum SidebarVisibilityPreferences {
    private static let collapsedKey = "workspace.sidebar.isCollapsed"

    static func load(arguments: [String]) -> Bool? {
        guard let defaults = defaults(arguments: arguments) else {
            return nil
        }
        guard defaults.object(forKey: collapsedKey) != nil else {
            return nil
        }
        return defaults.bool(forKey: collapsedKey)
    }

    static func save(_ isCollapsed: Bool, arguments: [String]) {
        defaults(arguments: arguments)?.set(isCollapsed, forKey: collapsedKey)
    }

    private static func defaults(arguments: [String]) -> UserDefaults? {
#if DEBUG
        if arguments.contains("--ui-test-mode") {
            guard arguments.contains("--ui-test-enable-persistence"),
                  let index = arguments.firstIndex(of: "--ui-test-library-id"),
                  arguments.indices.contains(index + 1) else {
                return nil
            }
            return UserDefaults(suiteName: "com.example.Curly.UITests.\(arguments[index + 1])")
        }
#endif
        return .standard
    }
}

#if DEBUG
private struct UITestEchoRequestExecutor: RequestExecuting {
    func execute(_ preparedRequest: PreparedHTTPRequest) async throws -> ExecutedResponse {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-stub-failure") {
            throw ExecutionError.transport("UI test transport failure")
        }

        let request = preparedRequest.sourceRequest
        let headerLines = request.headers
            .filter(\.isEnabled)
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "\n")
        let requestBody = request.body.textValue
        let bodyText = [
            "method=\(request.method.rawValue)",
            "url=\(request.urlString)",
            headerLines,
            requestBody.isEmpty ? "" : "body=\(requestBody)"
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

struct HelpView: View {
    var body: some View {
        TabView {
            aboutTab
                .tabItem { Label("About Curly", systemImage: "curlybraces") }

            supportTab
                .tabItem { Label("Support", systemImage: "questionmark.circle") }
        }
        .frame(width: 520, height: 400)
    }

    private var aboutTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "curlybraces")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Curly")
                .font(.title)
                .fontWeight(.semibold)

            Text("A lightweight cURL runner for macOS")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("Paste cURL commands directly into the URL bar", systemImage: "arrow.right.doc.on.clipboard")
                Label("Execute HTTP requests and inspect responses", systemImage: "play.fill")
                Label("Save and organize requests in workspaces", systemImage: "folder")
                Label("Quick access from the menu bar", systemImage: "menubar.rectangle")
            }
            .font(.body)

            Text("© Utkarsh Pandey")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding()
    }

    private var supportTab: some View {
        VStack(spacing: 16) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text("Need help?")
                .font(.headline)

            Text("Visit the GitHub repository for documentation, feature requests, and bug reports.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Open GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/utkarsh261/gurl")!)
            }
        }
        .padding()
    }
}

struct HelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Curly Help") {
                openWindow(id: "help")
            }
        }
    }
}

struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var coordinator: SessionCoordinator

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(coordinator.state.isLibraryCollapsed ? "Show Sidebar" : "Hide Sidebar") {
                coordinator.toggleLibraryCollapsed()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .accessibilityIdentifier("toggle-sidebar-command")
        }

        CommandGroup(after: .textEditing) {
            Button("Manage Variables…") {
                coordinator.presentVariablesModal()
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
            .accessibilityIdentifier("manage-variables-command")
        }

        CommandMenu("Workspace") {
            Button("New Workspace") {
                coordinator.createOrFocusHiddenNewDraft()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(coordinator.state.curlPreviewState != nil)

            Button("Save Request") {
                coordinator.saveCurrentRequest()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(coordinator.state.curlPreviewState != nil)

            Divider()

            Button(lastVisitedRequestTitle) {
                coordinator.selectLastVisitedRequest()
            }
            .keyboardShortcut(.tab, modifiers: [.control])
            .disabled(!coordinator.canUseLastVisitedRequestShortcut)
            .accessibilityIdentifier("last-visited-request-command")

            ForEach(Array(coordinator.state.requestListItems.prefix(9).enumerated()), id: \.element.id) { index, item in
                Button("\(index + 1) — \(item.name)") {
                    coordinator.selectVisibleRequest(at: index)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character("\(index + 1)")),
                    modifiers: [.control]
                )
                .disabled(!coordinator.canUseRequestNavigationShortcuts)
                .accessibilityIdentifier("select-request-\(index + 1)-command")
            }

            Divider()

            Button("Open Main Window") {
                coordinator.requestWindowOpen()
                if let lastID = coordinator.globalLastExecutedRequestID {
                    coordinator.selectSavedRequest(id: lastID)
                }
                if let existingWindow = NSApp.windows.first(where: { $0.styleMask.contains(.titled) }) {
                    existingWindow.makeKeyAndOrderFront(nil)
                } else {
                    openWindow(id: "main")
                }
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("0", modifiers: [.command])
            .disabled(coordinator.state.curlPreviewState != nil)
        }
    }

    private var lastVisitedRequestTitle: String {
        guard let request = coordinator.lastVisitedRequest else {
            return "Last Visited Request"
        }
        return "Last Visited — \(request.name)"
    }
}
