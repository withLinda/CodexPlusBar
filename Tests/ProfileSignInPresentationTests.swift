import Foundation
import Testing
@testable import CodexPlusBar

struct ProfileSignInPresentationTests {
    @Test(arguments: [
        (#"{"error":"invalid_request"}"#, false),
        (#"{"error":"unknown_error"}"#, false),
        ("<html>Bad request</html>", false),
        (#"{"error":"invalid_grant"}"#, true),
        (#"{"error":{"code":"refresh_token_expired"}}"#, true),
        (#"{"error":{"code":"refresh_token_reused"}}"#, true),
        (#"{"error":"refresh_token_invalidated"}"#, true)
    ])
    func desktopRefreshOnlyRequestsRepairForExplicitRejection(body: String, needsRepair: Bool) async throws {
        let signIn = try CodexSignIn(data: CodexSignInFixture.data())
        let verifier = CodexSignInVerifier(request: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil))
            return (Data(body.utf8), response)
        })
        do {
            _ = try await verifier.refresh(signIn)
            Issue.record("Expected refresh failure")
        } catch let error as CodexSignInError {
            #expect(error == (needsRepair ? .unauthorized : .httpStatus(400)))
            let switchError = CodexSignInSwitchError(cause: error, recovery: .unchanged, reopenFailed: false)
            let presentation = ProfileSignInPresentation(hasSavedSignIn: true, needsRepair: switchError.requiresNewSignIn)
            #expect(presentation.showsSave == needsRepair)
        }
    }

    @Test func malformedDesktopRefreshResponseDoesNotBlameSavedCredential() async throws {
        let signIn = try CodexSignIn(data: CodexSignInFixture.data())
        let verifier = CodexSignInVerifier(request: { request in
            let url = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(#"{"access_token":""}"#.utf8), response)
        })
        await #expect(throws: CodexSignInError.invalidResponse) { try await verifier.refresh(signIn) }
    }

    @Test func savedSignInOffersOnlySwitch() {
        let presentation = ProfileSignInPresentation(hasSavedSignIn: true, needsRepair: false)
        #expect(!presentation.showsSave)
        #expect(presentation.statusText == "Sign-in saved")
    }

    @Test func missingAndRejectedSignInsOfferSaveWithoutClaimingReady() {
        let missing = ProfileSignInPresentation(hasSavedSignIn: false, needsRepair: false)
        #expect(missing.showsSave)
        #expect(missing.statusText == "No saved sign-in")
        let rejected = ProfileSignInPresentation(hasSavedSignIn: true, needsRepair: true)
        #expect(rejected.showsSave)
        #expect(rejected.statusText == "Sign-in needs updating")
    }

    @Test func switchErrorsRetainCredentialRecoveryWithoutParsingMessages() {
        for error in [CodexSignInError.unauthorized, .invalidCredential, .missingSavedSignIn, .unsupportedCredential] {
            #expect(error.requiresNewSignIn)
            #expect(CodexSignInSwitchError(cause: error, recovery: .restored, reopenFailed: false).requiresNewSignIn)
        }
        for error in [CodexSignInError.unavailable, .appCouldNotClose, .reopenFailed, .concurrentChange,
                      .keychainUnavailable, .unsupportedConfiguration, .identityMismatch, .storageFailed] {
            #expect(!error.requiresNewSignIn)
            #expect(!CodexSignInSwitchError(cause: error, recovery: .unchanged, reopenFailed: true).requiresNewSignIn)
        }
        #expect(!CodexSignInSwitchError(cause: nil, recovery: .selected, reopenFailed: true).requiresNewSignIn)
        for error in [OpenCodeOpenAIVerificationError.unauthorized, .reauthenticationRequired] {
            #expect(OpenCodeOpenAISwitchError(cause: error, recovery: .restored).requiresNewSignIn)
        }
        for error in [OpenCodeOpenAIVerificationError.unavailable, .accessDenied, .invalidResponse, .httpStatus(500)] {
            #expect(!OpenCodeOpenAISwitchError(cause: error, recovery: .restored).requiresNewSignIn)
        }
        for error in [OpenCodeOpenAIAuthError.profileCredentialMissing, .credentialNotFound, .invalidCredential, .unsupportedCredential] {
            #expect(error.requiresNewSignIn)
            #expect(OpenCodeOpenAISwitchError(cause: error, recovery: .unchanged, requiresNewSignIn: true).requiresNewSignIn)
        }
        #expect(!OpenCodeOpenAISwitchError(cause: OpenCodeOpenAIAuthError.invalidCredential, recovery: .unchanged).requiresNewSignIn)
        #expect(!OpenCodeOpenAISwitchError(cause: CancellationError(), recovery: .unchanged).requiresNewSignIn)
    }
}

actor RepairableSignInService: CodexAccountSwitchServing, OpenCodeOpenAIAuthServing {
    enum Failure { case credential, network }
    private var failure: Failure? = .credential

    func setFailure(_ value: Failure?) { failure = value }

    func saveCurrent(for profile: PlusProfile) async throws -> CodexSignInIdentity {
        if failure != nil { throw CodexSignInError.unavailable }
        return .init(accountID: "workspace", userID: "user", email: profile.label)
    }

    func saveCurrent(for profile: PlusProfile) async throws -> OpenCodeOpenAIIdentity {
        if failure != nil { throw OpenCodeOpenAIAuthError.runtimeUnavailable }
        return .init(accountID: "workspace", userID: "user", email: profile.label)
    }

    func switchAndOpen(profile: PlusProfile) async throws {
        if let failure {
            throw CodexSignInSwitchError(cause: failure == .credential ? CodexSignInError.unauthorized : .unavailable,
                                        recovery: .restored, reopenFailed: false)
        }
    }

    func switchTo(profile: PlusProfile) async throws {
        if let failure {
            throw OpenCodeOpenAISwitchError(
                cause: failure == .credential ? OpenCodeOpenAIVerificationError.reauthenticationRequired : .unavailable,
                recovery: .restored)
        }
    }
}
