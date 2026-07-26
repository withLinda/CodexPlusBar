import Foundation

struct HTTPResponseData {
    let data: Data
    let response: HTTPURLResponse
}

@MainActor
protocol HTTPTransport {
    func data(for request: URLRequest) async throws -> HTTPResponseData
}

struct NetworkTraceLogger: @unchecked Sendable {
    let isEnabled: Bool
    private let sink: (String) -> Void

    init(
        isEnabled: Bool,
        sink: @escaping (String) -> Void = { print($0) }
    ) {
        self.isEnabled = isEnabled
        self.sink = sink
    }

    static let live = NetworkTraceLogger(
        isEnabled: Self.isTraceEnabled(in: ProcessInfo.processInfo.environment)
    )

    func logRequest(_ request: URLRequest) {
#if DEBUG
        guard isEnabled else { return }

        Self.requestMessages(for: request).forEach { sink($0) }
#endif
    }

    func logResponse(_ response: HTTPURLResponse, data: Data) {
#if DEBUG
        guard isEnabled else { return }

        Self.responseMessages(for: response, data: data).forEach { sink($0) }
#endif
    }

    static func requestMessages(for request: URLRequest) -> [String] {
        let url = request.url?.absoluteString ?? "<missing-url>"
        let method = request.httpMethod ?? "GET"
        let headers = redacted(headers: request.allHTTPHeaderFields ?? [:])
        return [
            "[CodexPlusBar] -> \(method) \(url)",
            "[CodexPlusBar] headers: \(headers)",
        ]
    }

    static func responseMessages(for response: HTTPURLResponse, data: Data) -> [String] {
        let url = response.url?.absoluteString ?? "<missing-url>"
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "<missing>"
        var messages = [
            "[CodexPlusBar] <- \(response.statusCode) \(url)",
            "[CodexPlusBar] content-type: \(contentType)",
        ]

        if shouldLogPrettyJSONBody(for: response.url) {
            messages.append("[CodexPlusBar] workspace body:\n\(formattedWorkspaceBody(from: data))")
            return messages
        }

        if response.url?.path == ClaudeWebURLs.bootstrapEndpoint.path {
            messages.append("[CodexPlusBar] Claude bootstrap body redacted (\(data.count) bytes)")
            return messages
        }

        if let sessionSummary = authSessionSummary(from: response.url, data: data) {
            messages.append("[CodexPlusBar] session summary: \(sessionSummary)")
            return messages
        }

        if looksLikeHTMLResponse(contentType: contentType, data: data) {
            messages.append("[CodexPlusBar] html summary: \(htmlSummary(from: data))")
            return messages
        }

        let preview = previewString(from: data, limit: 320)
        if preview.isEmpty == false {
            messages.append("[CodexPlusBar] preview: \(preview)")
        }

        return messages
    }

    private static func isTraceEnabled(in environment: [String: String]) -> Bool {
        environment["TRACE_PRIVATE_API"] == "1" || environment["CODEXPLUSBAR_TRACE_PRIVATE_API"] == "1"
    }

    private static func redacted(headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { partialResult, item in
            let key = item.key
            let value = item.value

            if key.caseInsensitiveCompare("Authorization") == .orderedSame
                || key.caseInsensitiveCompare("Cookie") == .orderedSame
                || key.caseInsensitiveCompare("Set-Cookie") == .orderedSame {
                partialResult[key] = "REDACTED"
                return
            }

            let lowercased = value.lowercased()
            if lowercased.contains("bearer") || lowercased.contains("session") {
                partialResult[key] = "REDACTED"
                return
            }

            partialResult[key] = value
        }
    }

    private static func shouldLogPrettyJSONBody(for url: URL?) -> Bool {
        guard let path = url?.path else {
            return false
        }

        return path == "/backend-api/wham/usage"
            || path == "/backend-api/accounts/check/v4-2023-04-27"
            || path == "/backend-anon/accounts/check/v4-2023-04-27"
    }

    private static func looksLikeHTMLResponse(contentType: String, data: Data) -> Bool {
        if contentType.lowercased().contains("text/html") {
            return true
        }

        let trimmed = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<")
    }

    private static func formattedWorkspaceBody(from data: Data) -> String {
        let prettyPrinted = prettyPrintedJSON(from: data) ?? String(decoding: data, as: UTF8.self)
        let trimmed = prettyPrinted.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "<empty>"
        }

        let limit = 16_000
        guard trimmed.count > limit else {
            return trimmed
        }

        let truncated = String(trimmed.prefix(limit))
        return "\(truncated)\n...[truncated \(trimmed.count - limit) characters]"
    }

    private static func authSessionSummary(from url: URL?, data: Data) -> String? {
        guard url?.path == "/api/auth/session",
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        else {
            return nil
        }

        let sessionObject = (object["session"] as? [String: Any]) ?? object
        let accountObject = (sessionObject["account"] as? [String: Any]) ?? (object["account"] as? [String: Any])
        let accountID = (accountObject?["id"] as? String) ?? (accountObject?["account_id"] as? String) ?? "<missing>"
        let hasAccessToken = ((sessionObject["accessToken"] as? String) ?? (object["accessToken"] as? String))?.isEmpty == false
        return "accountID=\(accountID), hasAccessToken=\(hasAccessToken)"
    }

    private static func previewString(from data: Data, limit: Int) -> String {
        String(decoding: data.prefix(limit), as: UTF8.self)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func prettyPrintedJSON(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let formattedData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            return nil
        }

        return String(decoding: formattedData, as: UTF8.self)
    }

    private static func htmlSummary(from data: Data) -> String {
        let html = String(decoding: data, as: UTF8.self)
        var parts: [String] = []

        if let title = firstMatch(in: html, pattern: #"<title[^>]*>(.*?)</title>"#, options: [.dotMatchesLineSeparators]) {
            parts.append("title=\(title.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        if let build = firstMatch(in: html, pattern: #"data-build="([^"]+)""#) {
            parts.append("build=\(build)")
        }

        if let authStatus = firstMatch(in: html, pattern: #""authStatus"\s*:\s*"([^"]+)""#) {
            parts.append("authStatus=\(authStatus)")
        }

        parts.append("hasBootstrap=\(html.contains(#"id="client-bootstrap""#))")
        return parts.joined(separator: ", ")
    }

    private static func firstMatch(
        in text: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
    }
}
