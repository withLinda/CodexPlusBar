import Foundation

typealias JSONObject = [String: Any]

enum WorkspacePayloadInspection {
    case html
    case unauthorizedJSON
    case json(Any)
    case empty
    case unrecognized
}

struct WorkspaceEntry {
    let payload: Any
    let fallbackID: String?
}

struct WorkspaceCollection {
    let entries: [WorkspaceEntry]
    let ordering: WorkspaceOrdering
}

enum WorkspaceOrdering {
    case explicit([String])
    case preserveInput
    case sortByNameThenID
}

enum WorkspacePayloadSupport {
    static func inspectPayload(in data: Data) -> WorkspacePayloadInspection {
        let raw = String(decoding: data, as: UTF8.self)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.isEmpty == false else {
            return .empty
        }

        if trimmed.hasPrefix("<") {
            return .html
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .unrecognized
        }

        if let rootObject = payload as? JSONObject, isClearlyUnauthorized(rootObject) {
            return .unauthorizedJSON
        }

        return .json(payload)
    }

    static func extractCollection(from payload: Any, traceHint: String) throws -> WorkspaceCollection {
        if let rootObject = payload as? JSONObject {
            if let accountsObject = rootObject["accounts"] as? JSONObject {
                let entries = accountsObject.map { key, value in
                    WorkspaceEntry(payload: value, fallbackID: key)
                }
                let ordering = stringArray(from: rootObject["account_ordering"] ?? rootObject["accountOrdering"])
                if let ordering, ordering.isEmpty == false {
                    return WorkspaceCollection(entries: entries, ordering: .explicit(ordering))
                }
                return WorkspaceCollection(entries: entries, ordering: .sortByNameThenID)
            }

            if let accountsArray = rootObject["accounts"] as? [Any] {
                return WorkspaceCollection(
                    entries: accountsArray.map { WorkspaceEntry(payload: $0, fallbackID: nil) },
                    ordering: .preserveInput
                )
            }

            if looksLikeWorkspaceEntry(rootObject) {
                return WorkspaceCollection(
                    entries: [WorkspaceEntry(payload: rootObject, fallbackID: nil)],
                    ordering: .preserveInput
                )
            }

            if isClearlyUnauthorized(rootObject) {
                throw ChatGPTAPIError.unauthorized
            }

            throw ChatGPTAPIError.unsupported(
                "ChatGPT returned an authenticated workspace response the app could not understand. \(traceHint)"
            )
        }

        if let rootArray = payload as? [Any] {
            return WorkspaceCollection(
                entries: rootArray.map { WorkspaceEntry(payload: $0, fallbackID: nil) },
                ordering: .preserveInput
            )
        }

        throw ChatGPTAPIError.unsupported(
            "ChatGPT returned a workspace response the app could not understand. \(traceHint)"
        )
    }

    static func resolveWorkspaceID(from entry: WorkspaceEntry) -> String? {
        guard let object = entry.payload as? JSONObject else {
            return nil
        }

        let accountObject = (object["account"] as? JSONObject) ?? object
        return firstNonEmptyString(
            from: accountObject["account_id"],
            accountObject["id"],
            object["account_id"],
            object["id"],
            entry.fallbackID
        )
    }

    static func firstNonEmptyString(from values: Any?...) -> String? {
        for value in values {
            guard let string = value as? String else {
                continue
            }

            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                return trimmed
            }
        }

        return nil
    }

    static func stringArray(from value: Any?) -> [String]? {
        guard let values = value as? [Any] else {
            return nil
        }

        let strings = values.compactMap { firstNonEmptyString(from: $0) }
        return strings.isEmpty ? nil : strings
    }

    static func boolValue(from value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            switch string.lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    static func intValue(from value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func dateValue(from value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }

        for formatter in makeISO8601DateFormatters() {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return nil
    }

    private static func looksLikeWorkspaceEntry(_ object: JSONObject) -> Bool {
        object["account"] is JSONObject
            || firstNonEmptyString(from: object["account_id"], object["id"], object["name"]) != nil
    }

    private static func isClearlyUnauthorized(_ object: JSONObject) -> Bool {
        let authStatus = firstNonEmptyString(from: object["authStatus"], object["auth_status"])?.lowercased()
        if authStatus == "logged_out" || authStatus == "loggedout" {
            return true
        }

        for key in ["detail", "message", "error", "description"] {
            guard let message = firstNonEmptyString(from: object[key])?.lowercased() else {
                continue
            }

            if message.contains("sign in")
                || message.contains("login")
                || message.contains("logged out")
                || message.contains("unauthorized")
                || message.contains("authenticated") {
                return true
            }
        }

        return false
    }

    private static func makeISO8601DateFormatters() -> [ISO8601DateFormatter] {
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return [fractional, standard]
    }
}
