import Darwin
import Foundation
import RelayModels

@_silgen_name("flock")
private func posixFlock(_ fd: Int32, _ operation: Int32) -> Int32

public struct RelayRunLockHolderInfo: Sendable, Codable, Hashable, Equatable {
    public let pid: Int32
    public let runID: String
    public let acquiredAt: Date

    public init(pid: Int32, runID: String, acquiredAt: Date = Date()) {
        self.pid = pid
        self.runID = runID
        self.acquiredAt = acquiredAt
    }
}

/// Non-blocking project-level exclusive `flock` lock on `<bundle>/run.lock` (`03-relayide.md` §8, §9).
/// Never opens with `O_TRUNC` prior to acquiring `LOCK_EX` and never unlinks `run.lock`, ensuring
/// contenders neither wipe an active holder's metadata nor split lock inodes.
public final class RelayProjectRunLock: @unchecked Sendable {
    public let lockFileURL: URL
    public let holderInfo: RelayRunLockHolderInfo
    private let stateLock = NSLock()
    private var fd: Int32

    private init(lockFileURL: URL, holderInfo: RelayRunLockHolderInfo, fd: Int32) {
        self.lockFileURL = lockFileURL
        self.holderInfo = holderInfo
        self.fd = fd
    }

    deinit {
        release()
    }

    public static func acquire(
        bundleDirectoryURL: URL,
        runID: String,
        pid: Int32 = ProcessInfo.processInfo.processIdentifier
    ) throws -> RelayProjectRunLock {
        let lockURL = bundleDirectoryURL.appendingPathComponent("run.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            let code = errno
            throw RelayIDEError.relayEnvironmentFailure(
                "Failed to open lock file '\(lockURL.path)' (errno \(code): \(String(cString: strerror(code))))"
            )
        }

        if posixFlock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockErr = errno
            if lockErr == EWOULDBLOCK || lockErr == EAGAIN {
                let existingHolder = readHolderInfo(from: descriptor)
                Darwin.close(descriptor)
                throw RelayIDEError.projectRunLocked(
                    projectPath: bundleDirectoryURL.path,
                    holderRunID: existingHolder?.runID,
                    holderPID: existingHolder?.pid
                )
            }
            Darwin.close(descriptor)
            throw RelayIDEError.relayEnvironmentFailure(
                "flock(LOCK_EX | LOCK_NB) failed on '\(lockURL.path)' (errno \(lockErr): \(String(cString: strerror(lockErr))))"
            )
        }

        let info = RelayRunLockHolderInfo(pid: pid, runID: runID, acquiredAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        do {
            let payload = try encoder.encode(info) + Data("\n".utf8)
            _ = Darwin.ftruncate(descriptor, 0)
            try payload.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var written = 0
                while written < rawBuffer.count {
                    let rc = Darwin.pwrite(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written,
                        off_t(written)
                    )
                    if rc < 0 {
                        if errno == EINTR { continue }
                        let writeErr = errno
                        throw RelayIDEError.relayEnvironmentFailure(
                            "Failed writing run.lock metadata (errno \(writeErr): \(String(cString: strerror(writeErr))))"
                        )
                    }
                    written += rc
                }
            }
        } catch {
            _ = posixFlock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }

        return RelayProjectRunLock(lockFileURL: lockURL, holderInfo: info, fd: descriptor)
    }

    public static func inspectActiveHolder(bundleDirectoryURL: URL) -> (isHeld: Bool, holder: RelayRunLockHolderInfo?) {
        let lockURL = bundleDirectoryURL.appendingPathComponent("run.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            return (false, nil)
        }
        defer { Darwin.close(descriptor) }

        if posixFlock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            _ = posixFlock(descriptor, LOCK_UN)
            return (false, nil)
        }
        let err = errno
        if err == EWOULDBLOCK || err == EAGAIN {
            return (true, readHolderInfo(from: descriptor))
        }
        return (false, nil)
    }

    public func release() {
        stateLock.lock()
        let currentFD = fd
        fd = -1
        stateLock.unlock()

        guard currentFD >= 0 else { return }
        _ = Darwin.ftruncate(currentFD, 0)
        _ = posixFlock(currentFD, LOCK_UN)
        Darwin.close(currentFD)
    }

    /// Closes the underlying file descriptor without truncating `run.lock`, matching kernel cleanup on `SIGKILL`.
    public func closeDescriptorSimulatingCrash() {
        stateLock.lock()
        let currentFD = fd
        fd = -1
        stateLock.unlock()

        guard currentFD >= 0 else { return }
        Darwin.close(currentFD)
    }

    private static func readHolderInfo(from descriptor: Int32) -> RelayRunLockHolderInfo? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var total = 0
        while total < buffer.count {
            let rc = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.pread(descriptor, base.advanced(by: total), raw.count - total, off_t(total))
            }
            if rc < 0 {
                if errno == EINTR { continue }
                break
            }
            if rc == 0 { break }
            total += rc
        }
        guard total > 0 else { return nil }
        let data = Data(buffer.prefix(total)).trimmingTrailingWhitespace()
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RelayRunLockHolderInfo.self, from: data)
    }
}

private extension Data {
    func trimmingTrailingWhitespace() -> Data {
        var end = count
        while end > 0 {
            let b = self[end - 1]
            if b == 0x0A || b == 0x0D || b == 0x20 || b == 0x09 || b == 0x00 {
                end -= 1
            } else {
                break
            }
        }
        return prefix(end)
    }
}
