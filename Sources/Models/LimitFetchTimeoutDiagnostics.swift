import Foundation

enum LimitFetchTimeoutCheckpoint: String, Equatable, Sendable {
    case switchAccount = "switch"
    case request
    case decode
    case restore
}

struct LimitFetchTimeoutDiagnostics: Equatable, Sendable {
    let accountID: String
    let sweepIndex: Int
    let sweepTotal: Int
    let checkpoint: LimitFetchTimeoutCheckpoint
    let elapsedMilliseconds: Int
    let timeoutMilliseconds: Int
    let thresholdMilliseconds: Int
    let sessionAccountBefore: String
    let sessionAccountAfter: String
    let accountCookieBefore: String
    let accountCookieAfter: String

    var fields: [NetworkTraceField] {
        [
            NetworkTraceField(key: "account_id", value: accountID),
            NetworkTraceField(key: "sweep_index", value: String(sweepIndex)),
            NetworkTraceField(key: "sweep_total", value: String(sweepTotal)),
            NetworkTraceField(key: "checkpoint", value: checkpoint.rawValue),
            NetworkTraceField(key: "elapsed_ms", value: String(elapsedMilliseconds)),
            NetworkTraceField(key: "threshold_ms", value: String(thresholdMilliseconds)),
            NetworkTraceField(key: "timeout_ms", value: String(timeoutMilliseconds)),
            NetworkTraceField(key: "session_account_before", value: sessionAccountBefore),
            NetworkTraceField(key: "session_account_after", value: sessionAccountAfter),
            NetworkTraceField(key: "_account_cookie_before", value: accountCookieBefore),
            NetworkTraceField(key: "_account_cookie_after", value: accountCookieAfter),
        ]
    }

    var cardDetailsText: String {
        """
        account_id: \(accountID)
        sweep_index: \(sweepIndex)
        sweep_total: \(sweepTotal)
        checkpoint: \(checkpoint.rawValue)
        elapsed_ms: \(elapsedMilliseconds)
        timeout_ms: \(timeoutMilliseconds)
        threshold_ms: \(thresholdMilliseconds)
        session_account_before: \(sessionAccountBefore)
        session_account_after: \(sessionAccountAfter)
        _account_cookie_before: \(accountCookieBefore)
        _account_cookie_after: \(accountCookieAfter)
        """
    }

    func logLine(event: String = "limit_fetch_timeout") -> String {
        NetworkTraceLogger.eventMessage(event: event, fields: fields)
    }
}
