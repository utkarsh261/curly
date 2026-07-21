import Foundation

enum ScriptLogLevel: Equatable, Sendable {
    case info
    case warning
    case error
}

struct ScriptLogEntry: Equatable, Sendable, Identifiable {
    let id: UUID
    var level: ScriptLogLevel
    var text: String

    init(id: UUID = UUID(), level: ScriptLogLevel, text: String) {
        self.id = id
        self.level = level
        self.text = text
    }
}

struct ScriptDiagnostic: Equatable, Sendable {
    var message: String
    var line: Int?
    var column: Int?
}

enum ScriptValidationResult: Equatable, Sendable {
    case valid
    case invalid(ScriptDiagnostic)
    case failed(ScriptDiagnostic)
    case cancelled
}

struct PostResponseScriptInput: Equatable, Sendable {
    var response: ExecutedResponse
    var variables: [Variable]
    var currentRequestID: UUID?
    var source: String
}

struct ScriptVariableWrite: Equatable, Sendable {
    var scope: VariableScope
    var name: String
    var value: String
}

enum PostResponseScriptRunOutcome: Equatable, Sendable {
    case passed
    case invalid
    case failed
    case timedOut
    case cancelled
}

struct PostResponseScriptRunResult: Equatable, Sendable {
    var outcome: PostResponseScriptRunOutcome
    var diagnostic: ScriptDiagnostic?
    var durationMs: Int
    var writes: [ScriptVariableWrite]
    var logs: [ScriptLogEntry]
    var logsWereTruncated: Bool
}

protocol PostResponseScriptRunning: Sendable {
    func validate(source: String) async -> ScriptValidationResult
    func run(_ input: PostResponseScriptInput) async -> PostResponseScriptRunResult
}

struct QuickJSPostResponseScriptRunner: PostResponseScriptRunning {
    func validate(source: String) async -> ScriptValidationResult {
        let cancellation = QuickJSCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Self.validateSynchronously(source: source, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    func run(_ input: PostResponseScriptInput) async -> PostResponseScriptRunResult {
        let cancellation = QuickJSCancellation()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                Self.runSynchronously(input, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func validateSynchronously(
        source: String,
        cancellation: QuickJSCancellation
    ) -> ScriptValidationResult {
        let result = source.utf8CString.withUnsafeBufferPointer { sourceBuffer in
            CQJSValidate(sourceBuffer.baseAddress, sourceBuffer.count - 1, cancellation.token)
        }
        guard let result else {
            return .failed(ScriptDiagnostic(message: "Could not allocate the JavaScript result.", line: nil, column: nil))
        }
        defer { CQJSResultDestroy(result) }
        switch CQJSResultGetStatus(result) {
        case CQJS_RESULT_VALID:
            return .valid
        case CQJS_RESULT_INVALID:
            return .invalid(diagnostic(from: result))
        case CQJS_RESULT_CANCELLED:
            return .cancelled
        default:
            return .failed(diagnostic(from: result))
        }
    }

    private static func runSynchronously(
        _ scriptInput: PostResponseScriptInput,
        cancellation: QuickJSCancellation
    ) -> PostResponseScriptRunResult {
        guard let bridgeInput = CQJSInputCreate() else {
            return allocationFailureResult()
        }
        defer { CQJSInputDestroy(bridgeInput) }

        CQJSInputSetResponse(
            bridgeInput,
            Int32(scriptInput.response.statusCode),
            Int64((scriptInput.response.duration * 1_000).rounded()),
            scriptInput.response.bodyData.count
        )

        for header in scriptInput.response.headers {
            let added = withUTF8(header.name) { name, nameLength in
                withUTF8(header.value) { value, valueLength in
                    CQJSInputAddHeader(bridgeInput, name, nameLength, value, valueLength)
                }
            }
            guard added else { return allocationFailureResult() }
        }

        let visibleVariables = scriptInput.variables.filter { variable in
            variable.scope == .global
                || (variable.scope == .request && variable.requestID == scriptInput.currentRequestID)
        }
        let resolvedVariables = VariableLookup(variables: visibleVariables).variablesByName.values.sorted {
            $0.name < $1.name
        }
        for variable in resolvedVariables {
            let scope = variable.scope == .global ? CQJS_SCOPE_GLOBAL : CQJS_SCOPE_REQUEST
            let belongsToCurrentRequest = variable.scope == .request && variable.requestID == scriptInput.currentRequestID
            let added = withUTF8(variable.name) { name, nameLength in
                withUTF8(variable.value) { value, valueLength in
                    CQJSInputAddVariable(
                        bridgeInput,
                        scope,
                        belongsToCurrentRequest,
                        name,
                        nameLength,
                        value,
                        valueLength
                    )
                }
            }
            guard added else { return allocationFailureResult() }
        }

        let rawResult = scriptInput.response.bodyData.withUnsafeBytes { bodyBuffer in
            CQJSInputSetBorrowedBody(
                bridgeInput,
                bodyBuffer.bindMemory(to: UInt8.self).baseAddress,
                bodyBuffer.count
            )
            return scriptInput.source.utf8CString.withUnsafeBufferPointer { sourceBuffer in
                CQJSRun(bridgeInput, sourceBuffer.baseAddress, sourceBuffer.count - 1, cancellation.token)
            }
        }
        guard let rawResult else { return allocationFailureResult() }
        defer { CQJSResultDestroy(rawResult) }
        return mappedResult(from: rawResult)
    }

    private static func mappedResult(from result: OpaquePointer) -> PostResponseScriptRunResult {
        let outcome: PostResponseScriptRunOutcome
        switch CQJSResultGetStatus(result) {
        case CQJS_RESULT_PASSED: outcome = .passed
        case CQJS_RESULT_INVALID: outcome = .invalid
        case CQJS_RESULT_TIMED_OUT: outcome = .timedOut
        case CQJS_RESULT_CANCELLED: outcome = .cancelled
        default: outcome = .failed
        }

        let writes = (0..<CQJSResultGetWriteCount(result)).compactMap { index -> ScriptVariableWrite? in
            guard let namePointer = CQJSResultGetWriteName(result, index),
                  let valuePointer = CQJSResultGetWriteValue(result, index) else { return nil }
            let name = String(cString: namePointer)
            let valueLength = CQJSResultGetWriteValueLength(result, index)
            let value = String(decoding: UnsafeBufferPointer(start: valuePointer, count: valueLength), as: UTF8.self)
            let scope: VariableScope = CQJSResultGetWriteScope(result, index) == CQJS_SCOPE_REQUEST ? .request : .global
            return ScriptVariableWrite(scope: scope, name: name, value: value)
        }

        let logs = (0..<CQJSResultGetLogCount(result)).compactMap { index -> ScriptLogEntry? in
            guard let textPointer = CQJSResultGetLogText(result, index) else { return nil }
            let textLength = CQJSResultGetLogTextLength(result, index)
            let text = String(decoding: UnsafeBufferPointer(start: textPointer, count: textLength), as: UTF8.self)
            let level: ScriptLogLevel
            switch CQJSResultGetLogLevel(result, index) {
            case CQJS_LOG_WARNING: level = .warning
            case CQJS_LOG_ERROR: level = .error
            default: level = .info
            }
            return ScriptLogEntry(level: level, text: text)
        }

        return PostResponseScriptRunResult(
            outcome: outcome,
            diagnostic: outcome == .passed ? nil : diagnostic(from: result),
            durationMs: Int(CQJSResultGetDurationMilliseconds(result)),
            writes: writes,
            logs: logs,
            logsWereTruncated: CQJSResultLogsWereTruncated(result)
        )
    }

    private static func diagnostic(from result: OpaquePointer) -> ScriptDiagnostic {
        let message = CQJSResultGetMessage(result).map(String.init(cString:)) ?? "Script execution failed."
        let line = Int(CQJSResultGetLine(result))
        let column = Int(CQJSResultGetColumn(result))
        return ScriptDiagnostic(
            message: message,
            line: line > 0 ? line : nil,
            column: column > 0 ? column : nil
        )
    }

    private static func allocationFailureResult() -> PostResponseScriptRunResult {
        PostResponseScriptRunResult(
            outcome: .failed,
            diagnostic: ScriptDiagnostic(message: "Could not allocate JavaScript bridge state.", line: nil, column: nil),
            durationMs: 0,
            writes: [],
            logs: [],
            logsWereTruncated: false
        )
    }

    private static func withUTF8<T>(
        _ string: String,
        _ body: (UnsafePointer<CChar>?, Int) -> T
    ) -> T {
        string.utf8CString.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count - 1)
        }
    }
}

private final class QuickJSCancellation: @unchecked Sendable {
    let token: OpaquePointer?

    init() {
        token = CQJSCancellationTokenCreate()
    }

    deinit {
        CQJSCancellationTokenDestroy(token)
    }

    func cancel() {
        CQJSCancellationTokenCancel(token)
    }
}
