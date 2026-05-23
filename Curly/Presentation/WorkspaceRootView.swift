import SwiftUI

struct WorkspaceRootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @FocusState private var isURLFieldFocused: Bool
    @State private var pendingURLInput = ""
    @State private var responseFoldedRanges: [NSRange] = []
    @State private var pendingDeleteRequest: RequestListItem?

    var body: some View {
        HSplitView {
            if coordinator.state.isLibraryCollapsed {
                collapsedLibraryRail
                    .frame(minWidth: 52, idealWidth: 52, maxWidth: 52)
            } else {
                libraryPane
                    .frame(minWidth: 220, idealWidth: 220, maxWidth: 220)
            }

            requestPane
                .frame(minWidth: 360, idealWidth: 420)

            responsePane
                .frame(minWidth: 420, idealWidth: 680)
        }
        .frame(minWidth: 980, minHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
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
                pendingURLInput = coordinator.state.workspaceRequest.urlString
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
            pendingURLInput = coordinator.state.workspaceRequest.urlString
            if coordinator.state.workspaceRequest.urlString.isEmpty {
                DispatchQueue.main.async {
                    isURLFieldFocused = true
                }
            }
        }
        .onChange(of: coordinator.state.workspaceRequest.urlString) { _, newValue in
            if pendingURLInput != newValue {
                pendingURLInput = newValue
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
            get: { pendingURLInput },
            set: { newValue in
                pendingURLInput = newValue
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
                        isURLFieldFocused: $isURLFieldFocused,
                        canRun: coordinator.state.canRun,
                        onPaste: handleURLBarPaste,
                        onRun: coordinator.runCurrentRequest
                    )

                    if let requestIssueMessage = coordinator.state.requestIssueMessage {
                        InlineMessageCard(
                            title: coordinator.state.requestIssueSeverity == .warning ? "Request Warning" : "Request Issue",
                            message: requestIssueMessage,
                            severity: coordinator.state.requestIssueSeverity
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
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }
        }
        .background(Color.surfaceGrouped)
    }

    private var requestHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Request Name", text: workspaceNameBinding)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("request-name-field")

                Button {
                    coordinator.saveCurrentRequest()
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
    }

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            libraryHeader

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
        .padding(10)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var libraryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Requests")
                        .font(.headline.weight(.semibold))
                }
                Spacer()
                Button {
                    coordinator.toggleLibraryCollapsed()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Collapse request list")
                .accessibilityIdentifier("toggle-library-button")

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
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.borderSubtle, lineWidth: 1)
                )
        )
    }

    private var collapsedLibraryRail: some View {
        VStack(spacing: 10) {
            Button {
                coordinator.setLibraryCollapsed(false)
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .help("Show request list")
            .accessibilityIdentifier("expand-library-button")

            Button {
                coordinator.createOrFocusHiddenNewDraft()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accent)
            .controlSize(.small)
            .help("New request")
            .accessibilityIdentifier("collapsed-new-request-button")

            Spacer()
        }
        .padding(.top, 12)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .underPageBackgroundColor))
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
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Response", systemImage: "arrow.left.arrow.right")
                        .font(.title3.weight(.semibold))
                    Text("Inspect the last response in a formatted JSON or raw body view.")
                        .font(.subheadline)
                        .foregroundStyle(Color.textMuted)
                }
                Spacer()
            }

            GroupBox {
                HStack(alignment: .top, spacing: 12) {
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
                .padding(14)
            }

            GroupBox {
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
                .padding(18)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .background(Color.surfaceGrouped)
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
                Image(systemName: coordinator.state.statusIconName)
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Color.textMuted)

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
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Color.textMuted)
        }
    }

    private func handleURLBarPaste(_ text: String) -> Bool {
        coordinator.handleURLBarPaste(text)
        pendingURLInput = coordinator.state.workspaceRequest.urlString
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

private struct RequestComposerView: View {
    @Binding var method: HTTPMethod
    @Binding var url: String
    var isURLFieldFocused: FocusState<Bool>.Binding
    let canRun: Bool
    let onPaste: (String) -> Bool
    let onRun: () -> Void

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
                    placeholder: "Paste a URL or cURL command",
                    isFocused: isURLFieldFocused,
                    onPaste: onPaste
                )
                .frame(minHeight: 24)

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
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.surfaceRaised)
                    .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isURLFieldFocused.wrappedValue ? 1.5 : 1)
            }

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
            .overlay {
                if header.isEnabled && header.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accent.opacity(0.5), lineWidth: 1)
                }
            }

            TextField(
                "Value",
                text: Binding(
                    get: { header.value },
                    set: { coordinator.updateHeader(id: header.id, value: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)

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
                .fill(Color.surfaceGrouped)
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

    var body: some View {
        GroupBox {
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
            }
            .padding(12)
        }
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
        GroupBox {
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
            .padding(14)
        }
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
                .fill(Color.surfaceGrouped)
        )
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)
                Text(value)
                    .font(.headline.monospacedDigit())
            }
        }
        .frame(minWidth: 86, alignment: .leading)
    }
}

private struct StatusMetric: View {
    let title: String
    let value: String
    let tone: ResponseTone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(toneColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(Color.textMuted)
                Text(value)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(toneColor)
            }
        }
        .frame(minWidth: 100, alignment: .leading)
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
        Text("Stale")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.red.opacity(isVisible ? 0.12 : 0.0))
            )
            .opacity(isVisible ? 1 : 0)
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
