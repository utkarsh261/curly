import Foundation

protocol ResponseFormatting {
    func format(_ response: ExecutedResponse) async -> VisibleResponseState
}

struct DefaultResponseFormatter: ResponseFormatting {
    func format(_ response: ExecutedResponse) async -> VisibleResponseState {
        await Task.detached(priority: .userInitiated) {
            let body = Self.makeResponseBody(from: response)
            return VisibleResponseState(
                summary: ResponseSummary(
                    statusCode: response.statusCode,
                    durationDescription: Self.durationString(for: response.duration),
                    sizeDescription: Self.sizeString(for: response.bodyData.count),
                    timestampDescription: Self.timestampString(for: response.timestamp),
                    tone: Self.tone(for: response.statusCode)
                ),
                body: body,
                selectedMode: body.jsonValue == nil ? .raw : .tree,
                isStale: false
            )
        }.value
    }

    private static func makeResponseBody(from response: ExecutedResponse) -> ResponseBody {
        let headerText = response.headers
            .map { "\($0.name): \($0.value)" }
            .joined(separator: "\n")

        let contentType = response.mimeType?.lowercased()
        let jsonValue = parseJSONIfPossible(data: response.bodyData, mimeType: contentType)

        if let jsonValue {
            let prettyJSON = prettyJSONString(from: jsonValue) ?? (String(data: response.bodyData, encoding: .utf8) ?? "")
            return ResponseBody(
                headerText: headerText,
                bodyText: prettyJSON,
                isPreviewable: true,
                rawData: response.bodyData,
                mimeType: response.mimeType,
                jsonValue: jsonValue,
                exportFilename: suggestedFilename(for: response.request, mimeType: response.mimeType)
            )
        }

        if let text = String(data: response.bodyData, encoding: .utf8) {
            return ResponseBody(
                headerText: headerText,
                bodyText: text,
                isPreviewable: true,
                rawData: response.bodyData,
                mimeType: response.mimeType,
                jsonValue: nil,
                exportFilename: suggestedFilename(for: response.request, mimeType: response.mimeType)
            )
        }

        return ResponseBody(
            headerText: headerText,
            bodyText: "Binary response body. Export the body to inspect it outside the app.",
            isPreviewable: false,
            rawData: response.bodyData,
            mimeType: response.mimeType,
            jsonValue: nil,
            exportFilename: suggestedFilename(for: response.request, mimeType: response.mimeType)
        )
    }

    private static func parseJSONIfPossible(data: Data, mimeType: String?) -> JSONValue? {
        let shouldTryJSON = mimeType?.contains("json") ?? true
        guard shouldTryJSON else {
            return nil
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        return makeJSONValue(from: object)
    }

    private static func makeJSONValue(from raw: Any) -> JSONValue {
        switch raw {
        case let dictionary as [String: Any]:
            return .object(dictionary.map { ($0.key, makeJSONValue(from: $0.value)) })
        case let array as [Any]:
            return .array(array.map(makeJSONValue))
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            return .number(value.stringValue)
        default:
            return .null
        }
    }

    private static func prettyJSONString(from jsonValue: JSONValue) -> String? {
        guard let foundationObject = makeFoundationObject(from: jsonValue) else {
            return nil
        }

        guard
            let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return string
    }

    private static func makeFoundationObject(from value: JSONValue) -> Any? {
        switch value {
        case .object(let pairs):
            var dictionary: [String: Any] = [:]
            for (key, child) in pairs {
                dictionary[key] = makeFoundationObject(from: child) ?? NSNull()
            }
            return dictionary
        case .array(let values):
            return values.map { makeFoundationObject(from: $0) ?? NSNull() }
        case .string(let string):
            return string
        case .number(let numberString):
            if let intValue = Int(numberString) {
                return intValue
            }
            if let doubleValue = Double(numberString) {
                return doubleValue
            }
            return numberString
        case .bool(let boolValue):
            return boolValue
        case .null:
            return NSNull()
        }
    }

    private static func durationString(for interval: TimeInterval) -> String {
        "\(Int((interval * 1000).rounded())) ms"
    }

    private static func sizeString(for bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func timestampString(for timestamp: Date) -> String {
        DateFormatter.localizedString(from: timestamp, dateStyle: .none, timeStyle: .medium)
    }

    private static func tone(for statusCode: Int) -> ResponseTone {
        switch statusCode {
        case 200..<400:
            return .success
        case 400..<500:
            return .warning
        case 500...:
            return .failure
        default:
            return .neutral
        }
    }

    private static func suggestedFilename(for request: Request, mimeType: String?) -> String {
        let baseName: String
        if let url = URL(string: request.urlString) {
            let lastPath = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
            baseName = lastPath.isEmpty ? "response" : lastPath
        } else {
            baseName = "response"
        }

        let ext: String
        switch mimeType?.lowercased() {
        case let type? where type.contains("json"):
            ext = "json"
        case let type? where type.contains("html"):
            ext = "html"
        case let type? where type.contains("xml"):
            ext = "xml"
        case let type? where type.contains("plain"):
            ext = "txt"
        default:
            ext = "bin"
        }

        return "\(baseName).\(ext)"
    }
}
