import AppKit
import SwiftUI

private enum WorkspaceLayout {
    static let sidebarWidth: CGFloat = 220
    static let panePadding: CGFloat = 20
    static let paneTopPadding: CGFloat = 16
}

struct WorkspaceRootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @FocusState private var isURLFieldFocused: Bool
    @FocusState private var isRequestNameFocused: Bool
    @State private var responseFoldedRanges: [NSRange] = []
    @State private var pendingDeleteRequest: RequestListItem?

    var body: some View {
        ZStack(alignment: .topLeading) {
            HSplitView {
                if !coordinator.state.isLibraryCollapsed {
                    libraryPane
                        .frame(width: WorkspaceLayout.sidebarWidth)
                }

                requestPane
                    .frame(minWidth: 360, idealWidth: 420)

                responsePane
                    .frame(minWidth: 420, idealWidth: 680)
            }

            if coordinator.state.isVariablesModalPresented {
                variablesModalOverlay
            }

        }
        .frame(minWidth: 1_000, minHeight: 620)
        .background(WorkspaceBackdrop())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        coordinator.toggleLibraryCollapsed()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(coordinator.state.isLibraryCollapsed ? "Show Sidebar" : "Hide Sidebar")
                .accessibilityLabel(coordinator.state.isLibraryCollapsed ? "Show Sidebar" : "Hide Sidebar")
                .accessibilityIdentifier("toggle-library-button")
            }
        }
        .confirmationDialog(
            "Replace the current workspace?",
            isPresented: replacementDialogIsPresented,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                coordinator.confirmWorkspaceReplacement()
            }

            Button("Cancel", role: .cancel) {
                coordinator.cancelWorkspaceReplacement()
            }
        } message: {
            Text(replacementDialogMessage)
        }
        .confirmationDialog(
            "Delete Request?",
            isPresented: Binding(
                get: { pendingDeleteRequest != nil },
                set: { isPresented in if !isPresented { pendingDeleteRequest = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let pendingDeleteRequest else { return }
                coordinator.deleteSavedRequest(id: pendingDeleteRequest.id)
                self.pendingDeleteRequest = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteRequest = nil
            }
        } message: {
            Text(pendingDeleteRequest?.name ?? "")
        }
        .onAppear {
            if coordinator.state.workspaceRequest.urlString.isEmpty {
                DispatchQueue.main.async {
                    isURLFieldFocused = true
                }
            }
        }
    }

    private var workspaceNameBinding: Binding<String> {
        Binding(
            get: { coordinator.state.workspaceName },
            set: { coordinator.updateWorkspaceName($0) }
        )
    }

    private var methodBinding: Binding<HTTPMethod> {
        Binding(
            get: { coordinator.state.workspaceRequest.method },
            set: { coordinator.setMethod($0) }
        )
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { coordinator.state.workspaceRequest.urlString },
            set: { newValue in
                processURLFieldInput(newValue)
            }
        )
    }

    private var replacementDialogIsPresented: Binding<Bool> {
        Binding(
            get: { coordinator.state.replaceConfirmationState != nil },
            set: { isPresented in
                if !isPresented {
                    coordinator.cancelWorkspaceReplacement()
                }
            }
        )
    }

    private var replacementDialogMessage: String {
        let base = "Pasting a full cURL command into a non-empty workspace will replace the current request."
        guard let warnings = coordinator.state.replaceConfirmationState?.candidateWarnings, !warnings.isEmpty else {
            return base
        }
        return base + "\n\nImport warning:\n" + warnings.joined(separator: "\n")
    }

    private var requestPane: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    requestHeader

                    paneTitle(
                        title: "Request",
                        icon: "square.and.pencil",
                        subtitle: "Compose a REST request from a URL or pasted cURL command."
                    )

                    RequestComposerView(
                        method: methodBinding,
                        url: urlBinding,
                        variables: coordinator.listVariablesForCurrentContext(),
                        isURLFieldFocused: $isURLFieldFocused,
                        canRun: coordinator.state.canRun,
                        onPaste: handleURLBarPaste,
                        onRun: coordinator.runCurrentRequest
                    )

                    if let requestIssueMessage = coordinator.currentRequestIssueMessage {
                        InlineMessageCard(
                            title: coordinator.currentRequestIssueSeverity == .warning ? "Request Warning" : "Request Issue",
                            message: requestIssueMessage,
                            severity: coordinator.currentRequestIssueSeverity
                        )
                    }

                    RequestEditorAccordion(
                        expansion: coordinator.state.requestEditorExpansion,
                        headers: coordinator.state.workspaceRequest.headers,
                        bodyText: bodyBinding,
                        isJSONBody: requestBodyIsJSON,
                        onToggle: coordinator.toggleRequestEditorSection,
                        onAddHeader: coordinator.addHeader
                    )
                    .environmentObject(coordinator)
                }
                .padding(.horizontal, WorkspaceLayout.panePadding)
                .padding(.top, WorkspaceLayout.paneTopPadding)
                .padding(.bottom, WorkspaceLayout.panePadding)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
            .accessibilityIdentifier("request-pane-scroll-view")
        }
        .background(WorkspaceBackdrop())
        .clipped()
    }

    private var variablesModalOverlay: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.24)
                    .ignoresSafeArea()
                    .accessibilityIdentifier("variables-modal-backdrop")
                    .onTapGesture {
                        dismissVariablesModalSavingEdits()
                    }

                VariablesModalView(maximumHeight: geometry.size.height - 48)
                    .environmentObject(coordinator)
                    .frame(width: 780)
                    .transition(.scale(scale: 0.98).combined(with: .opacity))
            }
        }
        .accessibilityIdentifier("variables-modal-overlay")
    }

    private func dismissVariablesModalSavingEdits() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            coordinator.dismissVariablesModal()
        }
    }

    private var requestHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Untitled request", text: workspaceNameBinding)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .focused($isRequestNameFocused)
                        .onSubmit {
                            saveRequestNameEditIfNeeded()
                        }
                        .accessibilityIdentifier("request-name-field")

                    Rectangle()
                        .fill(isRequestNameFocused ? Color.accent.opacity(0.55) : Color.borderSubtle.opacity(0.0))
                        .frame(height: 1)
                        .animation(.easeInOut(duration: 0.15), value: isRequestNameFocused)
                }
                .padding(.horizontal, 2)

                Button {
                    saveRequestNameEditIfNeeded()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .help("Save Request")
                .disabled(!coordinator.state.canSaveCurrentRequest)
                .accessibilityIdentifier("save-request-button")

                Button {
                    coordinator.revertCurrentRequestDraft()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .help("Revert to Saved")
                .disabled(!coordinator.state.canRevertCurrentRequest)
                .accessibilityIdentifier("revert-request-button")

                Button {
                    coordinator.deleteCurrentRequest()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .help("Delete request")
                .disabled(coordinator.state.selectedSavedRequestID == nil)
                .accessibilityIdentifier("discard-hidden-draft-button")
            }

            if let persistenceWarningMessage = coordinator.state.persistenceWarningMessage {
                InlineMessageCard(
                    title: "Persistence Warning",
                    message: persistenceWarningMessage,
                    severity: .warning
                )
            }
        }
        .onChange(of: isRequestNameFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused {
                saveRequestNameEditIfNeeded()
            }
        }
    }

    private func saveRequestNameEditIfNeeded() {
        guard coordinator.state.canSaveCurrentRequest else {
            return
        }
        coordinator.saveCurrentRequest()
        isRequestNameFocused = false
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            libraryHeader

            Divider()

            List {
                ForEach(coordinator.state.requestListItems) { item in
                    Button {
                        coordinator.selectSavedRequest(id: item.id)
                    } label: {
                        requestListRow(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.name)
                    .accessibilityValue("\(item.method.rawValue), \(item.urlPreview)")
                    .contextMenu {
                        Button("Revert Draft") {
                            coordinator.revertSavedRequestDraft(id: item.id)
                        }
                        .disabled(!item.isDirty)
                        Button("Delete", role: .destructive) {
                            pendingDeleteRequest = item
                        }
                    }
                    .padding(.vertical, 1)
                    .listRowBackground(
                        rowBackground(isSelected: coordinator.state.selectedSavedRequestID == item.id)
                    )
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("saved-requests-list")
            .overlay(alignment: .center) {
                if coordinator.state.requestListItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(Color.textMuted)
                        Text("No saved requests")
                            .font(.subheadline.weight(.semibold))
                        Text("Create one from the current editor.")
                            .font(.caption)
                            .foregroundStyle(Color.textMuted)
                    }
                    .padding(16)
                }
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var libraryHeader: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Requests")
                .font(.headline.weight(.semibold))

            Spacer()

            Button {
                coordinator.createOrFocusHiddenNewDraft()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
            .controlSize(.small)
            .help("New request")
            .accessibilityIdentifier("new-request-button")
        }
        .padding(.horizontal, 12)
        .padding(.top, WorkspaceLayout.paneTopPadding)
        .padding(.bottom, 12)
    }

    private func requestListRow(_ item: RequestListItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.method.rawValue)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(Color.accent)
                Text(item.name)
                    .lineLimit(1)
                if item.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .accessibilityIdentifier("request-dirty-dot-\(item.id.uuidString)")
                }
            }
            Text(item.urlPreview)
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-request-row")
    }


    private func rowBackground(isSelected: Bool) -> some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accent.opacity(0.17))
            } else {
                Color.clear
            }
        }
    }

    private var responsePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneTitle(
                title: "Response",
                icon: "arrow.left.arrow.right",
                subtitle: "Inspect the last response in a formatted JSON or raw body view."
            )

            PanelCard(padding: 12, cornerRadius: 16) {
                HStack(alignment: .center, spacing: 10) {
                    StatusMetric(
                        title: "Status",
                        value: coordinator.state.responseSummaryStatusValue,
                        tone: coordinator.state.responseTone
                    )
                    SummaryMetric(title: "Duration", value: coordinator.state.responseSummaryDurationValue, icon: "clock")
                    SummaryMetric(title: "Size", value: coordinator.state.responseSummarySizeValue, icon: "arrow.down.doc")
                    SummaryMetric(title: "Last Run", value: coordinator.state.responseSummaryTimestampValue, icon: "calendar")
                    Spacer()
                    StaleBadge(isVisible: coordinator.state.responseIsStale)
                }
            }

            PanelCard(padding: 18, cornerRadius: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("", selection: responseModeBinding) {
                            ForEach(ResponseViewMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .disabled(!coordinator.state.hasVisibleResponse)

                        Spacer()

                        Button {
                            coordinator.exportVisibleResponseBody()
                        } label: {
                            Label("Export", systemImage: "square.and.arrow.up")
                        }
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Color.accent)
                        .help("Export response body to a file")
                        .disabled(!coordinator.state.canExportResponseBody)

                        if coordinator.state.responseJSONValue != nil,
                           coordinator.state.currentResponseMode == .tree {
                            Button {
                                responseFoldedRanges = JSONFoldIndex.foldRanges(in: coordinator.state.responseBodyText)
                                    .filter { $0.depth > 0 }
                                    .map(\.fullRange)
                            } label: {
                                Label("Collapse", systemImage: "arrow.down.right.and.arrow.up.left")
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.accent)
                            .help("Collapse JSON containers")
                            .disabled(coordinator.state.responseBodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button {
                                responseFoldedRanges = []
                            } label: {
                                Label("Expand", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(Color.accent)
                            .help("Expand JSON containers")
                            .disabled(responseFoldedRanges.isEmpty)
                        }
                    }

                    responseContent(foldedRanges: $responseFoldedRanges)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.top, WorkspaceLayout.paneTopPadding)
        .padding(.bottom, 20)
        .background(WorkspaceBackdrop())
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { coordinator.state.workspaceRequest.body.textValue },
            set: { coordinator.setBody($0) }
        )
    }

    private var responseModeBinding: Binding<ResponseViewMode> {
        Binding(
            get: { coordinator.state.currentResponseMode },
            set: { coordinator.setResponseMode($0) }
        )
    }

    @ViewBuilder
    private func responseContent(foldedRanges: Binding<[NSRange]>) -> some View {
        if coordinator.state.responseJSONValue != nil, coordinator.state.currentResponseMode == .tree {
            JSONEditorPanel(
                text: .constant(coordinator.state.responseBodyText),
                isEditable: false,
                showsValidation: false,
                minHeight: 360,
                accessibilityIdentifier: "response-json-pretty",
                foldedRanges: foldedRanges,
                showsFoldingControls: false
            )
        } else if coordinator.state.hasVisibleResponse {
            ScrollView {
                if coordinator.state.responseBodyIsPreviewable {
                    Text(coordinator.state.responseHeaderAndBodyText)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("response-body-text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("Binary Body", systemImage: "shippingbox")
                            .font(.headline)
                        Text(coordinator.state.responseBodyText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let mimeType = coordinator.state.responseMimeType {
                            Text("Content type: \(mimeType)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(Color.accent.opacity(0.08))
                        .frame(width: 72, height: 72)
                    Image(systemName: coordinator.state.statusIconName)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Color.accent.opacity(0.75))
                }

                VStack(spacing: 6) {
                    Text(coordinator.state.responsePlaceholderTitle)
                        .font(.title3.weight(.medium))

                    Text(coordinator.state.responsePlaceholderMessage)
                        .font(.subheadline)
                        .foregroundStyle(Color.textMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private func paneTitle(title: String, icon: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentSoft)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
            }
        }
    }

    private func handleURLBarPaste(_ text: String) -> Bool {
        coordinator.handleURLBarPaste(text)
        return true
    }

    private func processURLFieldInput(_ text: String) {
        coordinator.handleURLBarTextChange(text)
    }

    private var requestBodyIsJSON: Bool {
        let bodyText = coordinator.state.workspaceRequest.body.textValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bodyText.isEmpty else {
            return true
        }

        if bodyText.hasPrefix("{") || bodyText.hasPrefix("[") {
            return true
        }

        return coordinator.state.workspaceRequest.headers.contains { header in
            header.isEnabled &&
            header.name.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare("Content-Type") == .orderedSame &&
            header.value.localizedCaseInsensitiveContains("json")
        }
    }
}

private struct WorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color.surfaceGrouped
            LinearGradient(
                colors: [
                    Color.surfaceRaised.opacity(colorScheme == .dark ? 0.05 : 0.55),
                    Color.accent.opacity(colorScheme == .dark ? 0.05 : 0.035),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct PanelCard<Content: View>: View {
    let padding: CGFloat
    let cornerRadius: CGFloat
    let showsShadow: Bool
    let content: Content

    init(
        padding: CGFloat = 16,
        cornerRadius: CGFloat = 14,
        showsShadow: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.showsShadow = showsShadow
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(PanelCardBackground(cornerRadius: cornerRadius, showsShadow: showsShadow))
    }
}

private struct PanelCardBackground: View {
    let cornerRadius: CGFloat
    let showsShadow: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.surfaceRaised)
            .shadow(color: .black.opacity(showsShadow ? 0.06 : 0), radius: 14, y: 5)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.borderSubtle.opacity(0.82), lineWidth: 1)
            )
    }
}

private struct RequestComposerView: View {
    @Binding var method: HTTPMethod
    @Binding var url: String
    let variables: [Variable]
    var isURLFieldFocused: FocusState<Bool>.Binding
    let canRun: Bool
    let onPaste: (String) -> Bool
    let onRun: () -> Void
    @State private var urlFocusRequest = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Method", selection: $method) {
                    ForEach(HTTPMethod.allCases) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 96)

                Divider()
                    .frame(height: 24)

                Image(systemName: "link")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.textMuted)

                URLInputField(
                    text: $url,
                    variables: variables,
                    placeholder: "Paste a URL or cURL command",
                    isFocused: Binding(
                        get: { isURLFieldFocused.wrappedValue },
                        set: { isURLFieldFocused.wrappedValue = $0 }
                    ),
                    focusRequest: urlFocusRequest,
                    onPaste: onPaste
                )
                .frame(minHeight: 24)
                .contentShape(Rectangle())
                .onTapGesture {
                    urlFocusRequest += 1
                    isURLFieldFocused.wrappedValue = true
                }

                Button {
                    onRun()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .tint(Color.accent)
                .controlSize(.regular)
                .accessibilityIdentifier("run-button")
                .disabled(!canRun)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.surfaceRaised)
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accent.opacity(isURLFieldFocused.wrappedValue ? 0.12 : 0.045),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: .black.opacity(isURLFieldFocused.wrappedValue ? 0.10 : 0.06), radius: isURLFieldFocused.wrappedValue ? 16 : 10, y: 4)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isURLFieldFocused.wrappedValue ? 1.5 : 1)
            }
            .animation(.easeInOut(duration: 0.16), value: isURLFieldFocused.wrappedValue)

            Text("Paste cURL directly. The request below updates automatically.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal, 2)
        }
    }

    private var borderColor: Color {
        isURLFieldFocused.wrappedValue ? Color.accent : Color.borderSubtle
    }

}

private struct HeaderRowView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    let header: Header
    @FocusState private var isValueFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button {
                coordinator.updateHeader(id: header.id, isEnabled: !header.isEnabled)
            } label: {
                Image(systemName: header.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(header.isEnabled ? Color.accent : Color.textMuted)
            }
            .buttonStyle(.plain)

            TextField(
                "Header",
                text: Binding(
                    get: { header.name },
                    set: { coordinator.updateHeader(id: header.id, name: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 130)
            .accessibilityIdentifier("header-name-field-\(header.id.uuidString)")
            .overlay {
                if header.isEnabled && header.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accent.opacity(0.5), lineWidth: 1)
                }
            }

            URLInputField(
                text: Binding(
                    get: { header.value },
                    set: { coordinator.updateHeader(id: header.id, value: $0) }
                ),
                variables: coordinator.listVariablesForCurrentContext(),
                placeholder: "Value",
                isFocused: Binding(
                    get: { isValueFocused },
                    set: { isValueFocused = $0 }
                ),
                focusRequest: 0,
                onPaste: { _ in false },
                accessibilityIdentifier: "header-value-field-\(header.id.uuidString)",
                accessibilityLabel: "Header value",
                enablesRequestImport: false
            )
            .frame(minHeight: 22)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                isValueFocused ? Color.accent : Color.borderSubtle.opacity(0.75),
                                lineWidth: isValueFocused ? 1.5 : 1
                            )
                    )
            )

            Button {
                coordinator.removeHeader(id: header.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red.opacity(0.7))
        }
        .opacity(header.isEnabled ? 1 : 0.55)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.surfaceInset)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.borderSubtle.opacity(0.65), lineWidth: 1)
                )
        )
    }

}

private struct RequestEditorAccordion: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    let expansion: RequestEditorExpansionState
    let headers: [Header]
    @Binding var bodyText: String
    let isJSONBody: Bool
    let onToggle: (RequestEditorSection) -> Void
    let onAddHeader: () -> Void
    @State private var foldedRanges: [NSRange] = []
    @State private var isScriptAPIReferencePresented = false

    var body: some View {
        PanelCard(padding: 14, cornerRadius: 16) {
            VStack(alignment: .leading, spacing: 10) {
                accordionRow(
                    title: "Headers",
                    icon: "line.3.horizontal.decrease.circle",
                    metadata: headerCountSummary,
                    isExpanded: expansion.headersExpanded
                ) {
                    onToggle(.headers)
                }

                if expansion.headersExpanded {
                    headersContent
                }

                Divider()

                accordionRow(
                    title: "Body",
                    icon: "doc.text",
                    metadata: isJSONBody ? "JSON" : "Raw",
                    isExpanded: expansion.bodyExpanded
                ) {
                    onToggle(.body)
                }

                if expansion.bodyExpanded {
                    bodyContent
                }

                Divider()

                accordionRow(
                    title: "Post-response script",
                    icon: "terminal",
                    metadata: scriptStatusTitle,
                    isExpanded: expansion.postResponseScriptExpanded
                ) {
                    onToggle(.postResponseScript)
                }

                if expansion.postResponseScriptExpanded {
                    postResponseScriptContent
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: expansion)
    }

    private var headerCountSummary: String {
        let enabledCount = headers.filter(\.isEnabled).count
        if headers.isEmpty {
            return "0"
        }
        return enabledCount == headers.count ? "\(enabledCount)" : "\(enabledCount)/\(headers.count)"
    }

    @ViewBuilder
    private var headersContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if headers.isEmpty {
                EmptySectionHint(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "No headers yet",
                    message: "Add headers as structured rows. Disabled rows stay in the editor but are ignored."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(headers) { header in
                        HeaderRowView(header: header)
                            .environmentObject(coordinator)
                    }
                }
            }

            HStack {
                Spacer()
                Button {
                    onAddHeader()
                } label: {
                    Label("Add", systemImage: "plus.circle")
                }
                .labelStyle(.iconOnly)
                .foregroundStyle(Color.accent)
                .help("Add a header")
                .accessibilityIdentifier("add-header-button")
            }
        }
        .transition(.opacity)
    }

    private func accordionRow(
        title: String,
        icon: String,
        metadata: String,
        isExpanded: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(Color.textMuted)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text(metadata)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textMuted)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("request-accordion-\(title.lowercased())")
    }

    private var bodyContent: some View {
        PanelCard(padding: 14, cornerRadius: 12, showsShadow: false) {
            VStack(alignment: .leading, spacing: 10) {
                if isJSONBody {
                    JSONEditorPanel(
                        text: $bodyText,
                        isEditable: true,
                        showsValidation: true,
                        minHeight: 240,
                        accessibilityIdentifier: "request-json-body-editor",
                        foldedRanges: $foldedRanges,
                        showsFoldingControls: true
                    )
                } else {
                    TextEditor(text: $bodyText)
                        .font(.body.monospaced())
                        .frame(minHeight: 220, maxHeight: .infinity)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .accessibilityIdentifier("request-raw-body-editor")
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var postResponseScriptContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Toggle(
                    "Run after every HTTP response",
                    isOn: Binding(
                        get: { coordinator.state.requestAutomation.postResponseScript.isEnabled },
                        set: { coordinator.setPostResponseScriptEnabled($0) }
                    )
                )
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("post-response-script-enabled")

                Spacer()

                Button {
                    isScriptAPIReferencePresented.toggle()
                } label: {
                    Label("API", systemImage: "book.closed")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.textMuted)
                .help("Show the post-response script API")
                .accessibilityIdentifier("post-response-script-api-button")
                .popover(isPresented: $isScriptAPIReferencePresented, arrowEdge: .top) {
                    scriptAPIReference
                }
            }

            Text("Use JavaScript to read the response and atomically update string variables. Scripts do not run for request validation or transport failures.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            JavaScriptCodeEditorView(
                text: Binding(
                    get: { coordinator.state.requestAutomation.postResponseScript.source },
                    set: { coordinator.setPostResponseScriptSource($0) }
                ),
                isEditable: coordinator.state.requestAutomation.postResponseScript.isEnabled,
                accessibilityIdentifier: "post-response-script-editor"
            )
            .frame(minHeight: 220)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
            )
            .accessibilityLabel("Post-response JavaScript")

            HStack(spacing: 8) {
                Circle()
                    .fill(scriptStatusColor)
                    .frame(width: 7, height: 7)
                Text(scriptStatusTitle)
                    .font(.caption.weight(.semibold))
                if let duration = coordinator.state.postResponseScriptState.durationMs {
                    Text("\(duration) ms")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color.textMuted)
                }
                if coordinator.state.postResponseScriptState.status == .passed {
                    Text("\(coordinator.state.postResponseScriptState.changedVariableCount) changed")
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("post-response-script-status")

            if let diagnostic = coordinator.state.postResponseScriptState.diagnostic {
                Text(scriptDiagnosticText(diagnostic))
                    .font(.caption.monospaced())
                    .foregroundStyle(Color.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("post-response-script-diagnostic")
            }

            if !coordinator.state.postResponseScriptState.logs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Console")
                        .font(.caption.weight(.semibold))
                    ForEach(coordinator.state.postResponseScriptState.logs) { entry in
                        Text(entry.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(logColor(entry.level))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .accessibilityIdentifier("post-response-script-console")
            }
        }
        .transition(.opacity)
    }

    private var scriptAPIReference: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Script API", systemImage: "book.closed")
                .font(.headline)

            scriptAPISection(
                title: "Response",
                entries: [
                    "curly.response.status",
                    "curly.response.ok",
                    "curly.response.header(name)",
                    "curly.response.text()",
                    "curly.response.json()"
                ]
            )

            scriptAPISection(
                title: "Variables",
                entries: [
                    "curly.variables.get(name)",
                    "curly.variables.global.set(name, value)",
                    "curly.variables.request.set(name, value)"
                ]
            )

            scriptAPISection(
                title: "Console",
                entries: [
                    "console.log(value)",
                    "console.warn(value)",
                    "console.error(value)"
                ]
            )

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("Example")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textMuted)
                Text("let body = curly.response.json();")
                Text("curly.variables.global.set(\"token\", body.auth.token);")
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)

            Text("Synchronous · 1 second limit · 8 MiB JSON limit · atomic string writes")
                .font(.caption2)
                .foregroundStyle(Color.textMuted)
        }
        .padding(16)
        .frame(width: 470, alignment: .leading)
        .accessibilityIdentifier("post-response-script-api-reference")
    }

    private func scriptAPISection(title: String, entries: [String]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.textMuted)
                .frame(width: 68, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(entries, id: \.self) { entry in
                    Text(entry)
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
        }
    }

    private var scriptStatusTitle: String {
        switch coordinator.state.postResponseScriptState.status {
        case .off: return "Off"
        case .ready: return "Ready"
        case .invalid: return "Invalid"
        case .running: return "Running"
        case .passed: return "Passed"
        case .failed: return "Failed"
        case .stale: return "Stale"
        }
    }

    private var scriptStatusColor: Color {
        switch coordinator.state.postResponseScriptState.status {
        case .passed: return .green
        case .invalid, .failed: return .red
        case .stale: return .orange
        case .running: return Color.accent
        case .off, .ready: return Color.textMuted
        }
    }

    private func scriptDiagnosticText(_ diagnostic: ScriptDiagnostic) -> String {
        let location: String
        if let line = diagnostic.line, let column = diagnostic.column {
            location = "Line \(line), column \(column): "
        } else if let line = diagnostic.line {
            location = "Line \(line): "
        } else {
            location = ""
        }
        return location + diagnostic.message
    }

    private func logColor(_ level: ScriptLogLevel) -> Color {
        switch level {
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private enum VariableTableLayout {
    static let nameWidth: CGFloat = 220
    static let actionWidth: CGFloat = 36
    static let columnSpacing: CGFloat = 12
    static let rowHeight: CGFloat = 48
}

enum VariableModalMetrics {
    static let minimumHeight: CGFloat = 360
    static let maximumHeight: CGFloat = 600

    static func height(contentHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let availableMaximum = min(maximumHeight, max(0, availableHeight))
        let desiredHeight = max(minimumHeight, contentHeight)
        return min(availableMaximum, desiredHeight)
    }
}

private struct VariablesModalContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct VariablesModalView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    let maximumHeight: CGFloat
    @State private var requestDraftID: UUID?
    @State private var globalDraftID: UUID?
    @State private var measuredContentHeight: CGFloat = VariableModalMetrics.minimumHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Variables")
                        .font(.title2.weight(.semibold))
                    Text("Changes save automatically.")
                        .font(.caption)
                        .foregroundStyle(Color.textMuted)
                }

                Spacer()

                Button {
                    dismissVariablesModalSavingEdits()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.surfaceInset))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("variables-modal-close-button")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)

            Divider()

            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VariableSectionView(
                            title: "Request",
                            emptyMessage: "No request variables",
                            variables: requestVariables,
                            draftID: $requestDraftID,
                            scope: .request
                        )
                        .environmentObject(coordinator)

                        VariableSectionView(
                            title: "Global",
                            emptyMessage: "No global variables",
                            variables: globalVariables,
                            draftID: $globalDraftID,
                            scope: .global
                        )
                        .environmentObject(coordinator)
                    }
                    .padding(20)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: VariablesModalContentHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                }
                .onChange(of: requestDraftID) { _, draftID in
                    scrollToDraft(draftID, using: scrollProxy)
                }
                .onChange(of: globalDraftID) { _, draftID in
                    scrollToDraft(draftID, using: scrollProxy)
                }
            }
        }
        .frame(height: modalHeight)
        .onPreferenceChange(VariablesModalContentHeightPreferenceKey.self) { contentHeight in
            measuredContentHeight = contentHeight + 86
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.surfaceRaised)
                .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var requestVariables: [Variable] {
        coordinator.listVariablesForCurrentContext().filter { $0.scope == .request }
    }

    private var globalVariables: [Variable] {
        coordinator.listVariablesForCurrentContext().filter { $0.scope == .global }
    }

    private var modalHeight: CGFloat {
        VariableModalMetrics.height(contentHeight: measuredContentHeight, availableHeight: maximumHeight)
    }

    private func dismissVariablesModalSavingEdits() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        DispatchQueue.main.async {
            coordinator.dismissVariablesModal()
        }
    }

    private func scrollToDraft(_ draftID: UUID?, using proxy: ScrollViewProxy) {
        guard let draftID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            proxy.scrollTo(draftID, anchor: .center)
        }
    }
}

private struct VariableSectionView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    let title: String
    let emptyMessage: String
    let variables: [Variable]
    @Binding var draftID: UUID?
    let scope: VariableScope

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(.headline)

                Text("\(variables.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.textMuted)

                Spacer()

                Button {
                    draftID = UUID()
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(scope == .request ? "variables-request-add-button" : "variables-global-add-button")
                .accessibilityLabel(scope == .request ? "Add Request Variable" : "Add Global Variable")
                .disabled(draftID != nil)
            }

            VStack(spacing: 0) {
                variableColumnHeader

                Divider()

                if variables.isEmpty && draftID == nil {
                    HStack(spacing: 8) {
                        Image(systemName: "tray")
                        Text(emptyMessage)
                    }
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, minHeight: VariableTableLayout.rowHeight, alignment: .center)
                }

                if let draftID {
                    VariableDraftRowView(id: draftID, scope: scope) {
                        self.draftID = nil
                    }
                    .environmentObject(coordinator)
                    .id(draftID)

                    if !variables.isEmpty {
                        Divider().padding(.leading, 12)
                    }
                }

                ForEach(Array(variables.enumerated()), id: \.element.id) { index, variable in
                    VariableEditableRowView(variable: variable)
                        .environmentObject(coordinator)

                    if index < variables.count - 1 {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.surfaceInset)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.borderSubtle.opacity(0.8), lineWidth: 1)
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var variableColumnHeader: some View {
        HStack(spacing: VariableTableLayout.columnSpacing) {
            Text("Name")
                .frame(width: VariableTableLayout.nameWidth, alignment: .leading)
            Text("Value")
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear
                .frame(width: VariableTableLayout.actionWidth)
                .accessibilityHidden(true)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Color.textMuted)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .frame(height: 28)
    }
}

private struct VariableDraftRowView: View {
    enum Field {
        case name
        case value
    }

    @EnvironmentObject private var coordinator: SessionCoordinator
    let id: UUID
    let scope: VariableScope
    let onFinish: () -> Void
    @State private var name = ""
    @State private var value = ""
    @State private var validationMessage: String?
    @State private var didFinish = false
    @FocusState private var focusedField: Field?

    var body: some View {
        variableRowShell(validationMessage: validationMessage) {
            TextField("name", text: $name)
                .focused($focusedField, equals: .name)
                .modifier(VariableFieldStyle(isFocused: focusedField == .name))
                .frame(width: VariableTableLayout.nameWidth)
                .accessibilityIdentifier("variable-name-field-\(id.uuidString)")

            URLInputField(
                text: $value,
                variables: coordinator.listVariablesForCurrentContext(),
                placeholder: "value",
                isFocused: valueFocusBinding,
                focusRequest: 0,
                onPaste: { _ in false },
                accessibilityIdentifier: "variable-value-field-\(id.uuidString)",
                accessibilityLabel: "Variable value",
                enablesRequestImport: false,
                onCommit: saveIfPossible
            )
                .modifier(VariableFieldStyle(isFocused: focusedField == .value))
                .frame(maxWidth: .infinity)

            VariableDeleteButton(
                accessibilityIdentifier: "variable-delete-button-\(id.uuidString)",
                accessibilityLabel: "Discard Variable Draft",
                action: {
                    didFinish = true
                    onFinish()
                }
            )
        }
        .onAppear {
            DispatchQueue.main.async {
                focusedField = .name
            }
        }
        .onSubmit {
            saveIfPossible()
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .value && newValue == nil {
                DispatchQueue.main.async {
                    guard focusedField == nil else { return }
                    saveIfPossible()
                }
            }
        }
        .onDisappear {
            saveIfPossible()
        }
    }

    private var valueFocusBinding: Binding<Bool> {
        Binding(
            get: { focusedField == .value },
            set: { isFocused in
                if isFocused {
                    focusedField = .value
                } else if focusedField == .value {
                    focusedField = nil
                }
            }
        )
    }

    private func saveIfPossible() {
        guard !didFinish else { return }
        let normalized = Variable.normalizedNameForStorage(name)
        if normalized.isEmpty && value.isEmpty {
            didFinish = true
            onFinish()
            return
        }
        guard Variable.isValidName(normalized) else {
            validationMessage = "Use letters, numbers, underscores, or hyphens. Start with a letter or underscore."
            return
        }
        guard coordinator.createVariable(name: normalized, value: value, scope: scope) != nil else {
            validationMessage = "A variable named \(normalized) already exists."
            return
        }
        didFinish = true
        onFinish()
    }
}

private struct VariableEditableRowView: View {
    enum Field {
        case name
        case value
    }

    @EnvironmentObject private var coordinator: SessionCoordinator
    let variable: Variable
    @State private var name: String
    @State private var value: String
    @State private var committedName: String
    @State private var committedValue: String
    @State private var validationMessage: String?
    @State private var isDeleteConfirmationPresented = false
    @FocusState private var focusedField: Field?

    init(variable: Variable) {
        self.variable = variable
        _name = State(initialValue: variable.name)
        _value = State(initialValue: variable.value)
        _committedName = State(initialValue: variable.name)
        _committedValue = State(initialValue: variable.value)
    }

    var body: some View {
        variableRowShell(
            isUsed: isUsed,
            usedIndicatorIdentifier: "variable-used-indicator-\(variable.id.uuidString)",
            validationMessage: validationMessage ?? resolutionDiagnostic?.message,
            validationIsWarning: validationMessage == nil && resolutionDiagnostic?.isWarning == true
        ) {
            TextField("name", text: $name)
                .focused($focusedField, equals: .name)
                .modifier(VariableFieldStyle(isFocused: focusedField == .name))
                .frame(width: VariableTableLayout.nameWidth)
                .accessibilityIdentifier("variable-name-field-\(variable.id.uuidString)")

            URLInputField(
                text: $value,
                variables: previewVariables,
                placeholder: "value",
                isFocused: valueFocusBinding,
                focusRequest: 0,
                onPaste: { _ in false },
                accessibilityIdentifier: "variable-value-field-\(variable.id.uuidString)",
                accessibilityLabel: "Variable value",
                enablesRequestImport: false,
                onCommit: saveIfChanged
            )
                .modifier(VariableFieldStyle(isFocused: focusedField == .value))
                .frame(maxWidth: .infinity)
                .help(valueHelpText)

            VariableDeleteButton(
                accessibilityIdentifier: "variable-delete-button-\(variable.id.uuidString)",
                accessibilityLabel: "Delete \(variable.name)"
            ) {
                isDeleteConfirmationPresented = true
            }
        }
        .onSubmit {
            saveIfChanged()
        }
        .onChange(of: focusedField) { oldValue, newValue in
            if oldValue == .name && newValue == .value {
                saveIfChanged()
            } else if oldValue == .value && newValue == nil {
                DispatchQueue.main.async {
                    guard focusedField == nil else { return }
                    saveIfChanged()
                }
            }
        }
        .onChange(of: variable.name) { oldValue, newValue in
            if name == oldValue {
                name = newValue
            }
            committedName = newValue
        }
        .onChange(of: variable.value) { oldValue, newValue in
            if value == oldValue {
                value = newValue
            }
            committedValue = newValue
        }
        .onDisappear {
            saveIfChanged()
        }
        .confirmationDialog(
            "Delete \(variable.name)?",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                coordinator.deleteVariable(id: variable.id)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var isUsed: Bool {
        coordinator.resolveCurrentRequestForRun().referencedVariableNames.contains(variable.name)
    }

    private var valueFocusBinding: Binding<Bool> {
        Binding(
            get: { focusedField == .value },
            set: { isFocused in
                if isFocused {
                    focusedField = .value
                } else if focusedField == .value {
                    focusedField = nil
                }
            }
        )
    }

    private var previewVariables: [Variable] {
        let normalizedName = Variable.normalizedNameForStorage(name)
        return coordinator.listVariablesForCurrentContext().map { candidate in
            guard candidate.id == variable.id else { return candidate }
            var preview = candidate
            if Variable.isValidName(normalizedName) {
                preview.name = normalizedName
            }
            preview.value = value
            return preview
        }
    }

    private var resolutionDiagnostic: (message: String, isWarning: Bool)? {
        guard let issue = previewExpansion.issues.first else {
            return nil
        }
        return (issue.diagnostic, issue.missingName != nil)
    }

    private var valueHelpText: String {
        if let issue = previewExpansion.issues.first {
            return issue.diagnostic
        }
        return previewExpansion.value.map { "\(previewVariableName) resolves to \($0)" } ?? value
    }

    private var previewVariableName: String {
        let normalizedName = Variable.normalizedNameForStorage(name)
        return Variable.isValidName(normalizedName) ? normalizedName : variable.name
    }

    private var previewExpansion: VariableExpansion {
        var resolver = VariableValueResolver(
            variablesByName: VariableLookup(variables: previewVariables).variablesByName
        )
        return resolver.resolveVariable(named: previewVariableName)
    }

    private func saveIfChanged() {
        guard name != committedName || value != committedValue else { return }
        let normalized = Variable.normalizedNameForStorage(name)
        guard Variable.isValidName(normalized) else {
            validationMessage = "Use letters, numbers, underscores, or hyphens. Start with a letter or underscore."
            return
        }
        guard coordinator.updateVariable(id: variable.id, name: normalized, value: value) != nil else {
            validationMessage = "A variable named \(normalized) already exists."
            return
        }
        name = normalized
        committedName = normalized
        committedValue = value
        validationMessage = nil
    }
}

@ViewBuilder
private func variableRowShell<Content: View>(
    isUsed: Bool = false,
    usedIndicatorIdentifier: String = "variable-used-indicator",
    validationMessage: String?,
    validationIsWarning: Bool = false,
    @ViewBuilder content: () -> Content
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: VariableTableLayout.columnSpacing) {
            content()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: VariableTableLayout.rowHeight)
        .background(Color.surfaceRaised.opacity(0.34))
        .overlay(alignment: .leading) {
            if isUsed {
                Rectangle()
                    .fill(Color.accent)
                    .frame(width: 2)
                    .padding(.vertical, 8)
                    .accessibilityElement()
                    .accessibilityLabel("Variable is used by the current request")
                    .accessibilityIdentifier(usedIndicatorIdentifier)
            }
        }

        if let validationMessage {
            Text(validationMessage)
                .font(.caption)
                .foregroundStyle(validationIsWarning ? Color.orange : Color.red)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .accessibilityIdentifier(
                    validationIsWarning ? "variable-resolution-warning" : "variable-validation-message"
                )
        }
    }
}

private struct VariableFieldStyle: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.body)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isFocused ? Color.accent : Color.borderSubtle, lineWidth: isFocused ? 1.5 : 1)
            )
    }
}

private struct VariableDeleteButton: View {
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.red.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isHovered ? Color.red : Color.textMuted)
        .frame(width: VariableTableLayout.actionWidth)
        .help(accessibilityLabel)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct InlineMessageCard: View {
    let title: String
    let message: String
    let severity: InlineMessageSeverity

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: severity == .warning ? "exclamationmark.triangle" : "exclamationmark.bubble")
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(accent.opacity(0.18), lineWidth: 1)
                )
        )
    }

    private var accent: Color {
        severity == .warning ? Color.accent : .red
    }
}

private struct EmptySectionHint: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Color.textMuted)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.surfaceInset)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.borderSubtle.opacity(0.65), lineWidth: 1)
                )
        )
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 14)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)
            }

            Text(value)
                .font(.headline.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 104, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.borderSubtle.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.borderSubtle.opacity(0.42), lineWidth: 1)
                )
        )
    }
}

private struct StatusMetric: View {
    let title: String
    let value: String
    let tone: ResponseTone

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(toneColor)
                    .frame(width: 14)
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)
            }

            Text(value)
                .font(.headline.monospacedDigit().weight(.semibold))
                .foregroundStyle(toneColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .accessibilityIdentifier("response-status-value")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: 104, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(toneColor.opacity(tone == .neutral ? 0.08 : 0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(toneColor.opacity(tone == .neutral ? 0.14 : 0.28), lineWidth: 1)
                )
        )
    }

    private var toneColor: Color {
        switch tone {
        case .neutral:
            return .textMuted
        case .success:
            return .green
        case .warning:
            return .accent
        case .failure:
            return .red
        }
    }
}

private struct StaleBadge: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            Text("Stale")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.red.opacity(0.12))
                )
                .accessibilityIdentifier("stale-response-badge")
        }
    }
}

private struct JSONRootView: View {
    let jsonValue: JSONValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                JSONNodeView(
                    label: "root",
                    value: jsonValue,
                    startsExpanded: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("response-json-tree")
    }
}

private struct JSONNodeView: View {
    let label: String?
    let value: JSONValue
    let startsExpanded: Bool

    @State private var isExpanded: Bool

    init(label: String?, value: JSONValue, startsExpanded: Bool = false) {
        self.label = label
        self.value = value
        self.startsExpanded = startsExpanded
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        switch value {
        case .object(let pairs):
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        JSONNodeView(label: pair.0, value: pair.1)
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 6)
            } label: {
                nodeLabel(text: labelText, detail: "Object (\(pairs.count))")
            }

        case .array(let values):
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(values.enumerated()), id: \.offset) { index, child in
                        JSONNodeView(label: "[\(index)]", value: child)
                    }
                }
                .padding(.leading, 16)
                .padding(.top, 6)
            } label: {
                nodeLabel(text: labelText, detail: "Array (\(values.count))")
            }

        case .string(let string):
            nodeLabel(text: labelText, detail: "\"\(string)\"")
        case .number(let number):
            nodeLabel(text: labelText, detail: number)
        case .bool(let bool):
            nodeLabel(text: labelText, detail: bool ? "true" : "false")
        case .null:
            nodeLabel(text: labelText, detail: "null")
        }
    }

    private var labelText: String {
        label ?? "value"
    }

    private func nodeLabel(text: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
            Text(detail)
                .font(.body.monospaced())
                .foregroundStyle(Color.textMuted)
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }
}
