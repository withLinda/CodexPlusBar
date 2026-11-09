import Darwin
import Foundation

enum CloudAssetError: Error, Equatable, Sendable { case inUse }

/// Keep this lease alive until CloudKit's send completion, including cancellation drain.
/// A shared inode lock protects the asset across store instances and processes.
final class CloudAssetLease: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32?

    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }

    func release() {
        lock.withLock {
            if let descriptor { flock(descriptor, LOCK_UN); close(descriptor) }
            descriptor = nil
        }
    }

    deinit { release() }
}

struct CloudAssetStore: Sendable {
    let root: URL
    private let io: CloudJournalIO

    init(root: URL, io: CloudJournalIO = .init()) {
        self.root = CloudSyncPaths(root: root).root
        self.io = io
    }

    /// This boundary accepts ciphertext only; encryption/authentication belongs to the cipher.
    /// Files survive store destruction and failed/uncertain writes. No age-based auto-cleanup.
    func stage(_ encrypted: Data) throws -> URL {
        guard !encrypted.isEmpty, encrypted.count <= CloudPayloadCipher.maximumAssetBytes else { throw CloudJournalError.tooLarge }
        return try withStorage { directory in
            let name = UUID().uuidString.lowercased() + ".asset"
            try CloudPrivateFiles.replace(name, bytes: encrypted, in: directory, io: io)
            return root.appendingPathComponent(name)
        }
    }

    /// CloudKit-owned input may be mode 0644, but must be a regular, single-link file
    /// owned by this user. Walk every parent without following symlinks or creating paths.
    /// The shared reader preflights size, then caps every streaming read at limit + 1.
    func copyBounded(from source: URL) throws -> URL {
        let source = CloudSyncPaths(root: source).root
        guard source.isFileURL else { throw CloudJournalError.unsafePath }
        let parent = try CloudPrivateFiles.openRoot(source.deletingLastPathComponent(), io: io, create: false, requirePrivate: false)
        defer { close(parent) }
        guard let bytes = try CloudPrivateFiles.read(source.lastPathComponent, in: parent,
                limit: CloudPayloadCipher.maximumAssetBytes, requirePrivate: false) else { throw CloudJournalError.missingAsset }
        return try stage(bytes)
    }

    /// Caller supplies only completed or durably established orphan assets. A live send
    /// lease prevents cleanup even from another instance/process; release after completion.
    func remove(_ file: URL) throws {
        let name = try assetName(file)
        try withStorage { directory in
            guard let descriptor = try CloudPrivateFiles.openFile(name, in: directory) else { return }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                if errno == EWOULDBLOCK { throw CloudAssetError.inUse }
                throw CloudPrivateFiles.systemError()
            }
            try CloudPrivateFiles.remove(name, in: directory)
        }
    }

    func retainForSend(_ file: URL) throws -> CloudAssetLease {
        let name = try assetName(file)
        return try withStorage { directory in
            guard let descriptor = try CloudPrivateFiles.openFile(name, in: directory) else { throw CloudJournalError.missingAsset }
            do {
                guard flock(descriptor, LOCK_SH | LOCK_NB) == 0 else { throw CloudAssetError.inUse }
                try io.before(.recoverySync, name)
                try CloudPrivateFiles.synchronize(name, in: directory)
                return CloudAssetLease(descriptor: descriptor)
            } catch { close(descriptor); throw error }
        }
    }

    private func assetName(_ file: URL) throws -> String {
        let file = CloudSyncPaths(root: file).root
        let name = file.lastPathComponent
        guard file.isFileURL, file.deletingLastPathComponent().path == root.path,
              file.pathExtension == "asset", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
              name == id.uuidString.lowercased() + ".asset" else { throw CloudJournalError.unsafePath }
        return name
    }

    private func withStorage<T>(_ body: (Int32) throws -> T) throws -> T {
        let directory = try CloudPrivateFiles.openRoot(root, io: io)
        defer { close(directory) }
        let lock = try CloudPrivateFiles.lock(in: directory)
        defer { flock(lock, LOCK_UN); close(lock) }
        return try body(directory)
    }
}
