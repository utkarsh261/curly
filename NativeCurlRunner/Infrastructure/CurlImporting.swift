import Foundation

enum CurlImportError: LocalizedError, Equatable {
    case emptyInput
    case notCurl
    case missingURL
    case unsupportedSyntax(String)
    case malformedInput(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The pasted input is empty."
        case .notCurl:
            return "The pasted input is not a supported cURL command."
        case .missingURL:
            return "The cURL command does not contain a request URL."
        case .unsupportedSyntax(let detail):
            return "This cURL pattern is not supported yet: \(detail)"
        case .malformedInput(let detail):
            return "The cURL command could not be parsed: \(detail)"
        }
    }
}

protocol CurlImporting {
    func parse(_ rawInput: String) throws -> Request
}
