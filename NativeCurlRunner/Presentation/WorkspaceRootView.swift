import SwiftUI

struct WorkspaceRootView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @FocusState private var isURLFieldFocused: Bool
    @State private var pendingURLInput = ""

    var body: some View {
        HSplitView {
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
            Text("Pasting a full cURL command into a non-empty workspace will replace the current request.")
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

    private var requestPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneTitle(
                    title: "Request",
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
                        title: "Request Issue",
                        message: requestIssueMessage,
                        accent: .orange
                    )
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Headers")
                                .font(.headline)
                            Spacer()
                            Button("Add Header") {
                                coordinator.addHeader()
                            }
                            .buttonStyle(.bordered)
                        }

                        if coordinator.state.workspaceRequest.headers.isEmpty {
                            EmptySectionHint(
                                symbol: "line.3.horizontal.decrease.circle",
                                title: "No headers yet",
                                message: "Add headers as structured rows. Disabled rows stay in the editor but are ignored."
                            )
                        } else {
                            VStack(spacing: 10) {
                                ForEach(coordinator.state.workspaceRequest.headers) { header in
                                    HeaderRowView(header: header)
                                        .environmentObject(coordinator)
                                }
                            }
                        }
                    }
                    .padding(14)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Body")
                            .font(.headline)

                        TextEditor(text: bodyBinding)
                            .font(.body.monospaced())
                            .frame(minHeight: 220)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                    }
                    .padding(14)
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.28))
    }

    private var responsePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Response")
                        .font(.title3.weight(.semibold))
                    Text("Inspect the last response in a structured tree or raw body view.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("Mode", selection: responseModeBinding) {
                    ForEach(ResponseViewMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(!coordinator.state.hasVisibleResponse)

                Button("Export Body") {
                    coordinator.exportVisibleResponseBody()
                }
                .buttonStyle(.bordered)
                .disabled(!coordinator.state.canExportResponseBody)
            }

            GroupBox {
                HStack(spacing: 12) {
                    StatusMetric(
                        title: "Status",
                        value: coordinator.state.responseSummaryStatusValue,
                        tone: coordinator.state.responseTone
                    )
                    SummaryMetric(title: "Duration", value: coordinator.state.responseSummaryDurationValue)
                    SummaryMetric(title: "Size", value: coordinator.state.responseSummarySizeValue)
                    SummaryMetric(title: "Last Run", value: coordinator.state.responseSummaryTimestampValue)
                    Spacer()
                    StaleBadge(isVisible: coordinator.state.responseIsStale)
                }
                .padding(14)
            }

            GroupBox {
                responseContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
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
    private var responseContent: some View {
        if let jsonValue = coordinator.state.responseJSONValue, coordinator.state.currentResponseMode == .tree {
            JSONRootView(jsonValue: jsonValue)
        } else if coordinator.state.hasVisibleResponse {
            ScrollView {
                if coordinator.state.responseBodyIsPreviewable {
                    Text(coordinator.state.responseHeaderAndBodyText)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
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
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)

                VStack(spacing: 6) {
                    Text(coordinator.state.responsePlaceholderTitle)
                        .font(.headline)

                    Text(coordinator.state.responsePlaceholderMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private func paneTitle(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func handleURLBarPaste(_ text: String) -> Bool {
        processURLFieldInput(text)
        return true
    }

    private func processURLFieldInput(_ text: String) {
        coordinator.handleURLBarTextChange(text)

        if coordinator.state.replaceConfirmationState == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("curl ") {
            pendingURLInput = coordinator.state.workspaceRequest.urlString
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
                    .foregroundStyle(.secondary)

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
                .controlSize(.regular)
                .accessibilityIdentifier("run-button")
                .disabled(!canRun)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: isURLFieldFocused.wrappedValue ? 1.5 : 1)
            }

            Text("Paste cURL directly. The request below updates automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var borderColor: Color {
        isURLFieldFocused.wrappedValue ? .accentColor : Color(nsColor: .separatorColor).opacity(0.7)
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
                    .foregroundStyle(header.isEnabled ? Color.accentColor : .secondary)
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
                        .stroke(Color.orange.opacity(0.7), lineWidth: 1)
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
            .foregroundStyle(.secondary)
        }
        .opacity(header.isEnabled ? 1 : 0.55)
    }
}

private struct InlineMessageCard: View {
    let title: String
    let message: String
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(accent)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(accent.opacity(0.12))
        )
    }
}

private struct EmptySectionHint: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct SummaryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
        }
        .frame(minWidth: 78, alignment: .leading)
    }
}

private struct StatusMetric: View {
    let title: String
    let value: String
    let tone: ResponseTone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(toneColor.opacity(0.14))
                )
                .foregroundStyle(toneColor)
        }
        .frame(minWidth: 96, alignment: .leading)
    }

    private var toneColor: Color {
        switch tone {
        case .neutral:
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

private struct StaleBadge: View {
    let isVisible: Bool

    var body: some View {
        Text("Stale")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.orange.opacity(isVisible ? 0.14 : 0.0))
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
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }
}
