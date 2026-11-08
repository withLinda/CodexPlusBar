import Foundation
import Testing
@testable import CodexPlusBar

struct SelectorControlClientTests {
    @Test func statusTransportFailureIsSanitized() async throws {
        let fixture = try SelectorControlFixture(); defer { fixture.remove() }
        let client = SelectorControlClient(homeDirectory: fixture.home, request: { _ in throw URLError(.timedOut) })
        await #expect(throws: SelectorControlError.unverified) { try await client.status() }
    }

    @Test func canceledMaintenanceAdmissionReleasesAcknowledgedHoldWithoutRunningOperation() async throws {
        let barrier = SyncBarrier(), selector = MaintenanceTestControl(state: .auto, admissionBarrier: barrier)
        let calls = SelectorRequestCount()
        let task = Task { try await selector.withMaintenance(reason: .manualAccountChange) { _ = await calls.next() } }
        await barrier.started(); task.cancel(); await barrier.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await calls.value == 0)
        #expect(await selector.state == .paused)
        #expect(await selector.events.last == "end")
    }

    @Test func descriptorDirectorySymlinkIsNotAbsenceEvenWhenTargetHasNoDescriptor() async throws {
        let fixture = try SelectorControlFixture(); defer { fixture.remove() }
        let target = fixture.home.appendingPathComponent("target")
        try FileManager.default.moveItem(at: fixture.directory, to: target)
        try FileManager.default.removeItem(at: target.appendingPathComponent("runtime.json"))
        try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: target)
        let client = SelectorControlClient(homeDirectory: fixture.home, connectionRefused: { true })
        await #expect(throws: SelectorControlError.unverified) { try await client.status() }
    }

    @Test func absenceRequiresBothMissingDescriptorAndRefusedConnection() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let absent = SelectorControlClient(homeDirectory: home, connectionRefused: { true })
        #expect(try await absent.status().state == .unavailable)
        #expect(try await absent.beginMaintenance(operationID: UUID(), reason: .manualAccountChange) == nil)
        let unknown = SelectorControlClient(homeDirectory: home, connectionRefused: { false })
        await #expect(throws: SelectorControlError.unverified) { try await unknown.status() }
    }

    @Test func lostBeginResponseRetriesSameOperationAndEndRemainsPaused() async throws {
        let fixture = try SelectorControlFixture(); defer { fixture.remove() }
        let server = SelectorControlStub(epoch: fixture.epoch)
        let client = fixture.client(server)
        let operation = UUID()
        let hold = try #require(await client.beginMaintenance(operationID: operation, reason: .manualAccountChange))
        #expect(await server.operations == [operation.uuidString, operation.uuidString])
        try await client.validateMaintenance(hold)
        try await client.endMaintenance(hold)
        #expect(try await client.status().state == .paused)
        #expect(await server.allRequestsLocal)
    }

    @Test(arguments: [0o644, 0o666]) func insecureDescriptorBlocksMutation(mode: Int) async throws {
        let fixture = try SelectorControlFixture(); defer { fixture.remove() }
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: fixture.file.path)
        await #expect(throws: SelectorControlError.unverified) {
            try await fixture.client(SelectorControlStub(epoch: fixture.epoch)).beginMaintenance(operationID: UUID(), reason: .signInRepair)
        }
    }

    @Test func wrongBearerAndUnsupportedProtocolNeverBecomeAbsent() async throws {
        let fixture = try SelectorControlFixture(); defer { fixture.remove() }
        let server = SelectorControlStub(epoch: fixture.epoch)
        await server.setStatus(401)
        await #expect(throws: SelectorControlError.unverified) { try await fixture.client(server).status() }
        try fixture.write(version: 2)
        await #expect(throws: SelectorControlError.protocolMismatch) { try await fixture.client(server).status() }
    }

    @Test func staleStatusEpochRereadsDescriptorOnce() async throws {
        let fixture = try SelectorControlFixture(); defer { fixture.remove() }
        let next = UUID().uuidString
        let count = SelectorRequestCount()
        let client = SelectorControlClient(homeDirectory: fixture.home, request: { request in
            let n = await count.next()
            if n == 1 { try fixture.write(epoch: next) }
            let epoch = n == 1 ? fixture.epoch : next
            let data = Data("{\"protocolVersion\":1,\"epoch\":\"\(epoch)\",\"mode\":\"paused\",\"holdsCount\":0,\"blockedReason\":\"paused\"}".utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: n == 1 ? 409 : 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(try await client.status().epoch == next)
        #expect(await count.value == 2)
    }

    @Test func staleMutationEpochNeverReplaysAgainstNewOwner() async throws {
        let fixture = try SelectorControlFixture(); defer { fixture.remove() }
        let next = UUID().uuidString, count = SelectorRequestCount()
        let client = SelectorControlClient(homeDirectory: fixture.home, request: { request in
            _ = await count.next(); try fixture.write(epoch: next)
            return (Data("{\"protocolVersion\":1,\"epoch\":\"\(next)\"}".utf8),
                HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: SelectorControlError.ownershipChanged) {
            try await client.beginMaintenance(operationID: UUID(), reason: .manualAccountChange)
        }
        #expect(await count.value == 1)
    }
}

struct SelectorControlFixture: Sendable {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let epoch = UUID().uuidString
    var directory: URL { home.appendingPathComponent(".codexplusbar-selector") }
    var file: URL { directory.appendingPathComponent("runtime.json") }
    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try write()
    }
    func write(version: Int = 1, epoch: String? = nil) throws {
        let data = Data("{\"protocolVersion\":\(version),\"pid\":123,\"epoch\":\"\(epoch ?? self.epoch)\",\"port\":53971,\"bearer\":\"\(String(repeating: "a", count: 64))\"}".utf8)
        try OpenCodePrivateFile.write(data, to: file)
    }
    func client(_ server: SelectorControlStub) -> SelectorControlClient {
        SelectorControlClient(homeDirectory: home, request: { try await server.request($0) })
    }
    func remove() { try? FileManager.default.removeItem(at: home) }
}

actor SelectorControlStub {
    let epoch: String
    let token = UUID().uuidString
    var operations: [String] = []
    var allRequestsLocal = true
    var held = false
    var status = 200
    init(epoch: String) { self.epoch = epoch }
    func setStatus(_ value: Int) { status = value }
    func request(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        allRequestsLocal = allRequestsLocal && request.url?.host == "127.0.0.1" && request.url?.port == 53971
            && request.value(forHTTPHeaderField: "X-Selector-Epoch") == epoch
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64)
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        if request.url?.path == "/v1/maintenance/begin" {
            operations.append(body["operationID"] ?? "missing"); held = true
            if operations.count == 1 { throw URLError(.timedOut) }
        }
        if request.url?.path == "/v1/maintenance/end" { held = false }
        let response: [String: Any] = ["protocolVersion": 1, "epoch": epoch, "holdToken": token,
            "mode": "paused", "holdsCount": held ? 1 : 0, "blockedReason": held ? "maintenance" : "paused"]
        return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

actor SelectorRequestCount {
    var value = 0
    func next() -> Int { value += 1; return value }
}

actor MaintenanceTestControl: SelectorControlling {
    var state: SelectorControlStatus.State
    var events: [String] = []
    var epoch = UUID().uuidString
    let gate: OpenCodeOperationGate?
    let admissionBarrier: SyncBarrier?
    init(state: SelectorControlStatus.State, gate: OpenCodeOperationGate? = nil, admissionBarrier: SyncBarrier? = nil) {
        self.state = state; self.gate = gate; self.admissionBarrier = admissionBarrier
    }
    func restart() { epoch = UUID().uuidString; state = .auto }
    func status() -> SelectorControlStatus {
        events.append("status")
        return .init(state: state, epoch: state == .unavailable ? nil : epoch, holdsCount: state == .maintenance ? 1 : 0)
    }
    func beginMaintenance(operationID: UUID, reason: SelectorMaintenanceReason) async throws -> SelectorMaintenanceHold? {
        if let gate { _ = try await gate.withOperation { true } }
        events.append("begin"); state = .maintenance
        if let admissionBarrier { await admissionBarrier.wait() }
        return .init(epoch: epoch, token: UUID().uuidString, operationID: operationID, endOperationID: UUID())
    }
    func endMaintenance(_ hold: SelectorMaintenanceHold) { events.append("end"); state = .paused }
}
