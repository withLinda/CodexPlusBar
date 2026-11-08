import Darwin
import Foundation

enum SelectorControlError: LocalizedError, Equatable {
    case unverified, protocolMismatch, ownershipChanged, maintenanceRequired
    var errorDescription: String? {
        switch self {
        case .unverified: "Could not verify the expiry selector. Open its panel and pause it before changing sign-ins."
        case .protocolMismatch: "The expiry selector control version is not supported."
        case .ownershipChanged: "The expiry selector restarted during this operation. Retry after checking its panel."
        case .maintenanceRequired: "The expiry selector must acknowledge maintenance before changing sign-ins."
        }
    }
}
enum SelectorMaintenanceReason: String, Sendable { case manualAccountChange = "manual-account-change", signInRepair = "sign-in-repair" }
struct SelectorMaintenanceHold: Sendable {
    let epoch: String
    let token: String
    let operationID: UUID
    let endOperationID: UUID
}
struct SelectorControlStatus: Sendable {
    enum State: Sendable { case unavailable, paused, auto, maintenance, blocked }
    let state: State
    let epoch: String?
    let holdsCount: Int
    var ownsSelection: Bool { state != .unavailable }
}
protocol SelectorControlling: Sendable {
    func status() async throws -> SelectorControlStatus
    func beginMaintenance(operationID: UUID, reason: SelectorMaintenanceReason) async throws -> SelectorMaintenanceHold?
    func endMaintenance(_ hold: SelectorMaintenanceHold) async throws
}
extension SelectorControlling {
    func validateMaintenance(_ hold: SelectorMaintenanceHold?) async throws {
        let status = try await status()
        if let hold {
            guard status.epoch == hold.epoch else { throw SelectorControlError.ownershipChanged }
            guard status.state == .maintenance, status.holdsCount > 0 else { throw SelectorControlError.maintenanceRequired }
        } else if status.state != .unavailable { throw SelectorControlError.ownershipChanged }
    }
    func withMaintenance<T: Sendable>(reason: SelectorMaintenanceReason, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        // Admission may commit remotely even if Cancel arrives before its response.
        let hold = try await SelectorMaintenanceContext.settle { try await self.beginMaintenance(operationID: UUID(), reason: reason) }
        let context = SelectorMaintenanceContext(control: self, hold: hold)
        do {
            try Task.checkCancellation()
            try await context.validate()
            let result = try await SelectorMaintenanceContext.$current.withValue(context) { try await operation() }
            if let hold { try await endMaintenance(hold) }
            return result
        } catch {
            // Cleanup must survive cancellation. A failed release leaves Auto safely paused.
            if let hold { try? await Task.detached { try await self.endMaintenance(hold) }.value }
            throw error
        }
    }
}

struct SelectorMaintenanceContext: Sendable {
    @TaskLocal static var current: SelectorMaintenanceContext?
    let control: any SelectorControlling
    let hold: SelectorMaintenanceHold?
    func validate() async throws { try await control.validateMaintenance(hold) }
    static func check() async throws { try await current?.validate() }
    static func settle<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let context = current
        return try await Task.detached { try await $current.withValue(context) { try await operation() } }.value
    }
}

actor SelectorControlClient: SelectorControlling {
    typealias Request = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private struct Descriptor: Decodable, Equatable, Sendable {
        let protocolVersion: Int
        let pid: Int
        let epoch: String
        let port: Int
        let bearer: String
    }
    private struct Reply: Decodable {
        let protocolVersion: Int
        let epoch: String
        let mode: String?
        let blockedReason: String?
        let holdsCount: Int?
        let holdToken: String?
    }
    private let directory: URL
    private let request: Request
    private let connectionRefused: @Sendable () async -> Bool
    private let session: URLSession?
    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, request: Request? = nil,
         connectionRefused: @escaping @Sendable () async -> Bool = { await SelectorControlClient.fixedPortRefused() }) {
        directory = homeDirectory.appendingPathComponent(".codexplusbar-selector")
        self.connectionRefused = connectionRefused
        if let request { self.request = request; session = nil }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
            config.urlCache = nil; config.timeoutIntervalForRequest = 40; config.timeoutIntervalForResource = 45
            let session = URLSession(configuration: config, delegate: OpenCodeNoRedirect(), delegateQueue: nil)
            self.session = session
            self.request = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse else { throw SelectorControlError.unverified }
                return (data, response)
            }
        }
    }
    deinit { session?.invalidateAndCancel() }

    func status() async throws -> SelectorControlStatus {
        guard var descriptor = try await discover() else { return .init(state: .unavailable, epoch: nil, holdsCount: 0) }
        for attempt in 0...1 {
            do { return try status(from: await send("status", descriptor: descriptor)) }
            catch SelectorControlError.ownershipChanged where attempt == 0 {
                guard let next = try await discover() else { throw SelectorControlError.ownershipChanged }
                descriptor = next
            }
            catch let error as SelectorControlError { throw error }
            catch { throw SelectorControlError.unverified }
        }
        throw SelectorControlError.ownershipChanged
    }

    func beginMaintenance(operationID: UUID, reason: SelectorMaintenanceReason) async throws -> SelectorMaintenanceHold? {
        guard let descriptor = try await discover() else { return nil }
        let body = ["operationID": operationID.uuidString, "reason": reason.rawValue]
        let reply = try await mutation("maintenance/begin", body: body, descriptor: descriptor)
        guard let token = reply.holdToken, UUID(uuidString: token) != nil else { throw SelectorControlError.unverified }
        return .init(epoch: descriptor.epoch, token: token, operationID: operationID, endOperationID: UUID())
    }

    func endMaintenance(_ hold: SelectorMaintenanceHold) async throws {
        guard let descriptor = try await discover(), descriptor.epoch == hold.epoch else { throw SelectorControlError.ownershipChanged }
        let reply = try await mutation("maintenance/end", body: ["operationID": hold.endOperationID.uuidString, "holdToken": hold.token], descriptor: descriptor)
        guard reply.mode == "paused" else { throw SelectorControlError.unverified }
    }

    private func mutation(_ path: String, body: [String: String], descriptor: Descriptor) async throws -> Reply {
        do { return try await send(path, body: body, descriptor: descriptor) }
        catch SelectorControlError.ownershipChanged {
            _ = try await discover() // Refresh discovery, but never replay a POST against a new owner.
            throw SelectorControlError.ownershipChanged
        }
        catch let error as SelectorControlError { throw error }
        catch {
            // Unknown outcome is retried with exactly the original operation ID and epoch.
            guard try await discover() == descriptor else { throw SelectorControlError.ownershipChanged }
            do { return try await send(path, body: body, descriptor: descriptor) }
            catch let error as SelectorControlError { throw error }
            catch { throw SelectorControlError.unverified }
        }
    }

    private func status(from reply: Reply) throws -> SelectorControlStatus {
        guard let mode = reply.mode, ["paused", "auto"].contains(mode), let holds = reply.holdsCount, (0...256).contains(holds) else {
            throw SelectorControlError.unverified
        }
        let state: SelectorControlStatus.State = holds > 0 ? .maintenance :
            (reply.blockedReason != nil && reply.blockedReason != "paused" ? .blocked : mode == "auto" ? .auto : .paused)
        return .init(state: state, epoch: reply.epoch, holdsCount: holds)
    }

    private func send(_ path: String, body: [String: String]? = nil, descriptor: Descriptor) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:53971/v1/\(path)")!)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = try body.map { try JSONEncoder().encode($0) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(descriptor.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(descriptor.epoch, forHTTPHeaderField: "X-Selector-Epoch")
        let (data, response) = try await self.request(request)
        guard data.count <= 1_048_576, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw SelectorControlError.unverified }
        guard reply.protocolVersion == 1 else { throw SelectorControlError.protocolMismatch }
        guard reply.epoch == descriptor.epoch, response.statusCode != 409 else { throw SelectorControlError.ownershipChanged }
        guard response.statusCode == 200 else { throw SelectorControlError.unverified }
        return reply
    }

    private func discover() async throws -> Descriptor? {
        if let descriptor = try readDescriptor() { return descriptor }
        guard await connectionRefused(), try readDescriptor() == nil else { throw SelectorControlError.unverified }
        return nil
    }

    private func readDescriptor() throws -> Descriptor? {
        let parentFD = open(directory.path, O_RDONLY | O_NOFOLLOW | O_DIRECTORY | O_NONBLOCK)
        if parentFD < 0 {
            if errno == ENOENT { return nil }
            throw SelectorControlError.unverified
        }
        defer { close(parentFD) }
        var parent = stat()
        guard fstat(parentFD, &parent) == 0, parent.st_uid == getuid(), parent.st_mode & 0o777 == 0o700 else {
            throw SelectorControlError.unverified
        }
        let fd = openat(parentFD, "runtime.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SelectorControlError.unverified
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_uid == getuid(), parent.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              parent.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o600, parent.st_mode & 0o777 == 0o700,
              info.st_size > 0, info.st_size <= 4096 else { throw SelectorControlError.unverified }
        var bytes = [UInt8](repeating: 0, count: 4097)
        let count = read(fd, &bytes, bytes.count)
        guard count > 0, count <= 4096, let descriptor = try? JSONDecoder().decode(Descriptor.self, from: Data(bytes.prefix(count))) else {
            throw SelectorControlError.unverified
        }
        guard descriptor.protocolVersion == 1 else { throw SelectorControlError.protocolMismatch }
        guard descriptor.pid > 0, descriptor.port == 53971, UUID(uuidString: descriptor.epoch) != nil,
              descriptor.bearer.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw SelectorControlError.unverified }
        return descriptor
    }

    private static func fixedPortRefused() async -> Bool {
        // An HTTP timeout or generic connection error is not proof of absence.
        await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return false }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(53971).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if result == 0 { return false }
            if errno == ECONNREFUSED { return true }
            guard errno == EINPROGRESS else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&descriptor, 1, 1000) > 0 else { return false }
            var error: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            return getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == ECONNREFUSED
        }.value
    }
}
