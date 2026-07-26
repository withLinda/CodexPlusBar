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
            return "The saved browser session is missing or expired."
        case .invalidResponse:
            return "The usage service returned a response the app could not read."
        case let .httpStatus(code):
            return "The usage service returned HTTP \(code)."
        case let .decoding(message), let .unsupported(message), let .network(message):
            return message
        case .missingURL:
            return "The app tried to call an invalid URL."
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
