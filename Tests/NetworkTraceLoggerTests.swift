import Foundation
import Testing
@testable import CodexPlusBar

struct NetworkTraceLoggerTests {
    @Test
    func requestMessagesRedactSensitiveHeaders() {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        request.setValue("__Secure-next-auth.session-token=secret-session", forHTTPHeaderField: "Cookie")
        request.setValue("workspace-a", forHTTPHeaderField: "ChatGPT-Account-ID")

        let messages = NetworkTraceLogger.requestMessages(for: request).joined(separator: "\n")

        #expect(messages.contains("REDACTED"))
        #expect(messages.contains("secret-token") == false)
        #expect(messages.contains("secret-session") == false)
        #expect(messages.contains("workspace-a"))
    }

    @Test
    func workspaceResponseMessagesIncludeContentTypeAndBody() {
        let request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data(
            """
            {
              "accounts": {
                "workspace-a": {
                  "account": {
                    "account_id": "workspace-a",
                    "name": "Alpha Team",
                    "plan_type": "team"
                  }
                }
              }
            }
            """.utf8
        )

        let messages = NetworkTraceLogger.responseMessages(for: response, data: data).joined(separator: "\n")

        #expect(messages.contains("content-type: application/json"))
        #expect(messages.contains("\"workspace-a\""))
        #expect(messages.contains("workspace body:"))
    }

    @Test
    func accountsCheckResponseMessagesIncludeContentTypeAndBody() {
        let request = URLRequest(
            url: URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")!
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let data = Data(
            """
            {
              "accounts": {
                "workspace-a": {
                  "account": {
                    "account_id": "workspace-a",
                    "plan_type": "team"
                  },
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 10,
                      "limit_window_seconds": 18000,
                      "reset_after_seconds": 60,
                      "reset_at": 1773819260
                    }
                  }
                }
              }
            }
            """.utf8
        )

        let messages = NetworkTraceLogger.responseMessages(for: response, data: data).joined(separator: "\n")

        #expect(messages.contains("content-type: application/json"))
        #expect(messages.contains("\"workspace-a\""))
        #expect(messages.contains("workspace body:"))
    }

}
