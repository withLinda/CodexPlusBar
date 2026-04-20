import Foundation
import Testing
@testable import CodexPlusBar

struct WebBootstrapServiceTests {
    @Test
    func parsesUsagePageBootstrap() throws {
        let bootstrap = try WebBootstrapService.parseBootstrap(
            from: Data(
                """
                <!DOCTYPE html>
                <html data-build="prod-build-123">
                <body>
                  <script id="client-bootstrap" type="application/json">
                    {"authStatus":"logged_in","session":{"accessToken":"token-alpha","expires":"2026-06-16T03:28:00Z","account":{"id":"workspace-a"}},"locale":"en-US"}
                  </script>
                </body>
                </html>
                """.utf8
            )
        )

        #expect(bootstrap.authStatus == "logged_in")
        #expect(bootstrap.accessToken == "token-alpha")
        #expect(bootstrap.accountID == "workspace-a")
        #expect(bootstrap.clientVersion == "prod-build-123")
        #expect(bootstrap.locale == "en-US")
        #expect(bootstrap.hasUsableSession)
    }

    @Test
    func loggedOutShellDoesNotProduceUsableSession() throws {
        let bootstrap = try WebBootstrapService.parseBootstrap(
            from: Data(
                """
                <!DOCTYPE html>
                <html data-build="prod-build-123">
                <body>
                  <script id="client-bootstrap" type="application/json">
                    {"authStatus":"logged_out","locale":"en-US"}
                  </script>
                </body>
                </html>
                """.utf8
            )
        )

        #expect(bootstrap.authStatus == "logged_out")
        #expect(bootstrap.accessToken == nil)
        #expect(bootstrap.accountID == nil)
        #expect(bootstrap.hasUsableSession == false)
    }

    @Test
    func publicShellWithoutBootstrapDataStaysUnsignedIn() throws {
        let bootstrap = try WebBootstrapService.parseBootstrap(
            from: Data(
                """
                <!DOCTYPE html>
                <html data-build="prod-build-123">
                <body>
                  <h1>Codex</h1>
                </body>
                </html>
                """.utf8
            )
        )

        #expect(bootstrap.authStatus == nil)
        #expect(bootstrap.accessToken == nil)
        #expect(bootstrap.accountID == nil)
        #expect(bootstrap.clientVersion == "prod-build-123")
        #expect(bootstrap.hasUsableSession == false)
    }
}
