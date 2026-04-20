import Foundation

enum ChatGPTAPIError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case invalidResponse
    case httpStatus(Int)
    case decoding(String)
    case unsupported(String)
    case network(String)
    case missingURL

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The ChatGPT session is missing or expired."
        case .invalidResponse:
            return "ChatGPT returned a response the app could not read."
        case let .httpStatus(code):
            return "ChatGPT returned HTTP \(code)."
        case let .decoding(message), let .unsupported(message), let .network(message):
            return message
        case .missingURL:
            return "The app tried to call an invalid URL."
        }
    }

    var accountLimitErrorDescription: String {
        switch self {
        case .unauthorized:
            return "The ChatGPT session expired while loading this account. Sign in again in the account window."
        case .invalidResponse:
            return "ChatGPT returned limit data for this account, but the app could not read the response."
        case let .httpStatus(code):
            return "ChatGPT returned HTTP \(code) while loading this account's limit data."
        case let .decoding(message), let .unsupported(message):
            return message
        case let .network(message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "This account's limit data is unavailable right now."
            }
            if trimmed.compare("cancelled", options: .caseInsensitive) == .orderedSame {
                return "This account did not finish loading during the last refresh."
            }
            return trimmed
        case .missingURL:
            return "The app tried to load limit data from an invalid URL."
        }
    }

    static func map(_ error: Error) -> ChatGPTAPIError {
        if let apiError = error as? ChatGPTAPIError {
            return apiError
        }

        if let urlError = error as? URLError {
            return .network(urlError.localizedDescription)
        }

        return .network(error.localizedDescription)
    }
}
