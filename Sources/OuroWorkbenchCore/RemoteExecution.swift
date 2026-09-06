import Darwin
import Foundation

public struct RemoteHelperContext {
    public let invocation: RemoteHelperInvocation
    public let environment: [String: String]
    public let workingDirectory: String
    public let helperPath: String

    public init(invocation: RemoteHelperInvocation, environment: [String: String], workingDirectory: String, helperPath: String) {
        self.invocation = invocation
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.helperPath = helperPath
    }

    public func value(_ option: String, environment environmentKey: String? = nil) throws -> String {
        if let value = invocation.options[option], !value.isEmpty { return value }
        if let environmentKey, let value = environment[environmentKey], !value.isEmpty { return value }
        throw RemoteControlError.invalidConfiguration("required option '--\(option)' is empty or missing")
    }

    public func path(_ option: String, environment environmentKey: String? = nil) throws -> String {
        let value = try value(option, environment: environmentKey)
        guard value.hasPrefix("/"), URL(fileURLWithPath: value).standardizedFileURL.path == value else {
            throw RemoteControlError.invalidConfiguration("absolute path required for '--\(option)'")
        }
        return value
    }

    public func herdrValue(_ option: String, ouroKey: String, herdrKey: String) throws -> String {
        let values = [invocation.options[option], environment[ouroKey], environment[herdrKey]].compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
        guard let selected = values.first else { throw RemoteControlError.invalidConfiguration("required Herdr context '--\(option)' is missing") }
        guard values.allSatisfy({ $0 == selected }) else { throw RemoteControlError.invalidConfiguration("Herdr context '--\(option)' values disagree") }
        return selected
    }
}

public enum RemoteHerdrRootLocator {
    public static func locate(environment: [String: String]) throws -> URL {
        if let explicit = environment["OURO_HERDR_ROOT"], !explicit.isEmpty {
            let root = try normalizedDirectory(explicit)
            guard root.lastPathComponent == "herdr" else {
                throw RemoteControlError.invalidConfiguration("Herdr root must be the exact Herdr config directory")
            }
            return root
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return try normalizedDirectory(xdg).appendingPathComponent("herdr", isDirectory: true)
        }
        if let home = environment["HOME"], !home.isEmpty {
            return try normalizedDirectory(home).appendingPathComponent(".config/herdr", isDirectory: true)
        }
        throw RemoteControlError.invalidConfiguration("Herdr root is unavailable")
    }

    private static func normalizedDirectory(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw RemoteControlError.invalidConfiguration("absolute normalized Herdr root path is required")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

private final class RemoteCapturedStream: @unchecked Sendable {
    private let handle: FileHandle
    private let maximumBytes: Int
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var data = Data()
    private var overflowed = false
    private var cancelled = false

    init(handle: FileHandle, maximumBytes: Int) {
        self.handle = handle
        self.maximumBytes = maximumBytes
    }

    func start() {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            while true {
                lock.lock()
                let shouldStop = cancelled
                lock.unlock()
                if shouldStop { break }
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 50)
                if ready <= 0 { continue }
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock()
                let remaining = maximumBytes - data.count
                if remaining > 0 { data.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { overflowed = true }
                lock.unlock()
            }
        }
    }

    func finish() -> (Data, Bool) {
        if group.wait(timeout: .now() + 0.25) == .timedOut {
            lock.lock()
            cancelled = true
            lock.unlock()
            group.wait()
        }
        try? handle.close()
        lock.lock()
        defer { lock.unlock() }
        return (data, overflowed)
    }
}

final class RemoteInputWriter: @unchecked Sendable {
    typealias Write = (Int32, UnsafeRawPointer, Int) -> (count: Int, error: Int32)

    private let handle: FileHandle
    private let writeBytes: Write
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var cancelled = false

    init(handle: FileHandle, writeBytes: @escaping Write = { descriptor, bytes, count in
        let written = Darwin.write(descriptor, bytes, count)
        return (written, errno)
    }) {
        self.handle = handle
        self.writeBytes = writeBytes
        let descriptor = handle.fileDescriptor
        let descriptorFlags = Darwin.fcntl(descriptor, F_GETFD)
        if descriptorFlags >= 0 { _ = Darwin.fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) }
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
        _ = Darwin.fcntl(descriptor, F_SETNOSIGPIPE, 1)
    }

    func start(_ input: Data) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                group.leave()
            }
            var offset = 0
            while offset < input.count {
                lock.lock()
                let shouldStop = cancelled
                lock.unlock()
                if shouldStop { return }
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, 50)
                guard ready > 0, descriptor.revents & Int16(POLLOUT) != 0 else {
                    if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
                    continue
                }
                let result = input.withUnsafeBytes { raw in
                    writeBytes(handle.fileDescriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                }
                if result.count > 0 {
                    offset += result.count
                } else if Self.shouldRetryWrite(result.count, error: result.error) {
                    continue
                } else {
                    return
                }
            }
        }
    }

    func finish() {
        lock.lock()
        cancelled = true
        lock.unlock()
        _ = group.wait(timeout: .now() + 0.2)
    }

    static func shouldRetryWrite(_ count: Int, error: Int32) -> Bool {
        count < 0 && (error == EAGAIN || error == EINTR)
    }
}

final class RemoteChildWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var waitStatus: Int32?

    init(pid: Int32) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            waitStatus = Self.readStatus(pid: pid, wait: { Darwin.waitpid($0, $1, 0) })
            lock.unlock()
            group.leave()
        }
    }

    var isRunning: Bool { group.wait(timeout: .now()) == .timedOut }

    func wait(timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func wait() -> Int32? {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return waitStatus
    }

    static func readStatus(pid: Int32, wait: (Int32, UnsafeMutablePointer<Int32>) -> Int32) -> Int32? {
        var status: Int32 = 0
        var waited: Int32
        repeat { waited = wait(pid, &status) }
        while waited < 0 && errno == EINTR
        return waited == pid ? status : nil
    }
}

final class RemoteInteractiveSignalShield: @unchecked Sendable {
    private struct SavedDisposition {
        let signal: Int32
        let action: sigaction
    }

    private let lock = NSLock()
    private var saved: [SavedDisposition]

    private init(saved: [SavedDisposition]) {
        self.saved = saved
    }

    static func install(failingSignalForTesting: Int32? = nil) throws -> RemoteInteractiveSignalShield {
        var ignored = sigaction()
        ignored.__sigaction_u.__sa_handler = SIG_IGN
        sigemptyset(&ignored.sa_mask)
        var saved: [SavedDisposition] = []
        for value in [SIGINT, SIGQUIT, SIGTSTP] {
            var prior = sigaction()
            guard value != failingSignalForTesting, sigaction(value, &ignored, &prior) == 0 else {
                restore(saved)
                throw RemoteControlError.resume("interactive signal shield could not be installed")
            }
            saved.append(SavedDisposition(signal: value, action: prior))
        }
        return RemoteInteractiveSignalShield(saved: saved)
    }

    func restore() {
        lock.lock()
        let dispositions = saved
        saved.removeAll()
        lock.unlock()
        Self.restore(dispositions)
    }

    deinit { restore() }

    private static func restore(_ dispositions: [SavedDisposition]) {
        for disposition in dispositions.reversed() {
            var action = disposition.action
            _ = sigaction(disposition.signal, &action, nil)
        }
    }
}

final class RemoteOwnedProcess: @unchecked Sendable {
    let pid: Int32
    private let processGroup: SpawnInOwnGroup.ProcessGroup
    private let waiter: RemoteChildWaiter
    private let inputWriter: RemoteInputWriter?

    private init(pid: Int32, processGroup: SpawnInOwnGroup.ProcessGroup, inputWriter: RemoteInputWriter?) {
        self.pid = pid
        self.processGroup = processGroup
        waiter = RemoteChildWaiter(pid: pid)
        self.inputWriter = inputWriter
    }

    static func spawn(
        _ request: RemoteProcessRequest,
        nullOutput: Bool,
        processGroup: SpawnInOwnGroup.ProcessGroup = .isolated
    ) throws -> RemoteOwnedProcess {
        let inputPipe = request.standardInput.map { _ in Pipe() }
        let inputWriter = inputPipe.map { RemoteInputWriter(handle: $0.fileHandleForWriting) }
        let null = FileHandle.nullDevice.fileDescriptor
        let spawned: SpawnInOwnGroup.Spawned
        do {
            spawned = try SpawnInOwnGroup.spawn(
                executablePath: request.executable,
                arguments: [request.executable] + request.arguments,
                environment: request.environment,
                stdio: .init(
                    stdin: inputPipe?.fileHandleForReading.fileDescriptor ?? (nullOutput ? null : FileHandle.standardInput.fileDescriptor),
                    stdout: nullOutput ? null : FileHandle.standardOutput.fileDescriptor,
                    stderr: nullOutput ? null : FileHandle.standardError.fileDescriptor
                ),
                workingDirectory: request.workingDirectory,
                processGroup: processGroup
            )
        } catch {
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            throw error
        }
        try? inputPipe?.fileHandleForReading.close()
        if let input = request.standardInput { inputWriter?.start(input) }
        return RemoteOwnedProcess(pid: spawned.pid, processGroup: processGroup, inputWriter: inputWriter)
    }

    var isRunning: Bool { waiter.isRunning }

    func waitForExit() throws -> Int32 {
        defer { inputWriter?.finish() }
        let status = waiter.wait()
        if processGroup == .isolated { _ = Darwin.killpg(pid, SIGKILL) }
        return try RemoteSystemRunner.exitCode(waitStatus: status)
    }

    func terminate() {
        _ = signal(SIGTERM)
    }

    func terminateAndWait(timeout: TimeInterval) -> Bool {
        let grace = min(0.1, max(0, timeout / 2))
        _ = signal(SIGTERM)
        if waiter.wait(timeout: grace) {
            if processGroup == .isolated { _ = Darwin.killpg(pid, SIGKILL) }
            inputWriter?.finish()
            return true
        }
        _ = signal(SIGKILL)
        let stopped = waiter.wait(timeout: max(0, timeout - grace))
        inputWriter?.finish()
        return stopped
    }

    private func signal(_ value: Int32) -> Int32 {
        processGroup == .isolated ? Darwin.killpg(pid, value) : Darwin.kill(pid, value)
    }
}

public struct RemoteSystemRunner {
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int

    public init(timeout: TimeInterval = 15, maximumOutputBytes: Int = 1_048_576) {
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }

    public func run(_ request: RemoteProcessRequest) throws -> RemoteProcessResult {
        guard request.executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: request.executable) else {
            throw RemoteControlError.dependency("required executable is unavailable")
        }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let inputPipe = request.standardInput.map { _ in Pipe() }
        let inputWriter = inputPipe.map { RemoteInputWriter(handle: $0.fileHandleForWriting) }
        let stdout = RemoteCapturedStream(handle: stdoutPipe.fileHandleForReading, maximumBytes: maximumOutputBytes)
        let stderr = RemoteCapturedStream(handle: stderrPipe.fileHandleForReading, maximumBytes: maximumOutputBytes)
        let spawned: SpawnInOwnGroup.Spawned
        do {
            spawned = try SpawnInOwnGroup.spawn(
                executablePath: request.executable,
                arguments: [request.executable] + request.arguments,
                environment: request.environment,
                stdio: .init(
                    stdin: inputPipe?.fileHandleForReading.fileDescriptor ?? FileHandle.nullDevice.fileDescriptor,
                    stdout: stdoutPipe.fileHandleForWriting.fileDescriptor,
                    stderr: stderrPipe.fileHandleForWriting.fileDescriptor
                ),
                workingDirectory: request.workingDirectory
            )
        } catch {
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForWriting.close()
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            throw RemoteControlError.dependency("dependency process could not start")
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? inputPipe?.fileHandleForReading.close()
        stdout.start()
        stderr.start()
        if let input = request.standardInput { inputWriter?.start(input) }
        let waiter = RemoteChildWaiter(pid: spawned.pid)
        if !waiter.wait(timeout: timeout) {
            _ = Darwin.killpg(spawned.pid, SIGTERM)
            if !waiter.wait(timeout: 1) {
                _ = Darwin.killpg(spawned.pid, SIGKILL)
                _ = waiter.wait(timeout: 2)
            }
            _ = Darwin.killpg(spawned.pid, SIGKILL)
            inputWriter?.finish()
            _ = stdout.finish()
            _ = stderr.finish()
            throw RemoteControlError.dependency("dependency process timed out")
        }
        _ = Darwin.killpg(spawned.pid, SIGKILL)
        inputWriter?.finish()
        let stdoutResult = stdout.finish()
        let stderrResult = stderr.finish()
        guard !stdoutResult.1, !stderrResult.1 else {
            throw RemoteControlError.dependency("dependency output exceeded the byte bound")
        }
        return RemoteProcessResult(exitCode: try Self.exitCode(waitStatus: waiter.wait()), stdout: stdoutResult.0, stderr: stderrResult.0)
    }

    static func exitCode(waitStatus: Int32?) throws -> Int32 {
        guard let waitStatus else { throw RemoteControlError.dependency("dependency process status is unavailable") }
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : signal
    }
}

public enum RemoteSupervisedProcessFactory {
    public static func spawn(
        _ request: RemoteProcessRequest,
        identityForPID: @escaping (Int32, String) -> RemoteProcessIdentity? = remoteProcessIdentity
    ) throws -> RemoteSupervisedChild {
        try spawn(request, identityForPID: identityForPID, failingSignalForTesting: nil)
    }

    static func spawn(
        _ request: RemoteProcessRequest,
        identityForPID: @escaping (Int32, String) -> RemoteProcessIdentity?,
        failingSignalForTesting: Int32?
    ) throws -> RemoteSupervisedChild {
        let signalShield: RemoteInteractiveSignalShield
        do { signalShield = try RemoteInteractiveSignalShield.install(failingSignalForTesting: failingSignalForTesting) }
        catch { throw RemoteSupervisedSpawnFailure.beforeKernel }
        let process: RemoteOwnedProcess
        do { process = try RemoteOwnedProcess.spawn(request, nullOutput: false, processGroup: .inherited) }
        catch {
            signalShield.restore()
            throw RemoteSupervisedSpawnFailure.beforeKernel
        }
        let generation = request.environment["OURO_GENERATION"] ?? "unknown"
        guard let identity = identityForPID(process.pid, generation) else {
            _ = process.terminateAndWait(timeout: 0.5)
            signalShield.restore()
            throw RemoteSupervisedSpawnFailure.afterKernel
        }
        return RemoteSupervisedChild(
            identity: identity,
            wait: { try process.waitForExit() },
            terminate: { process.terminate() },
            finish: { signalShield.restore() }
        )
    }
}

public enum RemotePrivateFile {
    public static func read(path: String, maximumBytes: Int = 1_048_576) throws -> Data {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw RemoteControlError.invalidConfiguration("absolute normalized private-file path is required")
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_uid == getuid(),
              parentInfo.st_mode & mode_t(0o077) == 0
        else {
            throw RemoteControlError.invalidConfiguration("private-file directory is unavailable or unsafe")
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw RemoteControlError.invalidConfiguration("private file is unavailable") }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_uid == getuid(),
              info.st_mode & mode_t(0o777) == 0o600,
              info.st_size >= 0,
              info.st_size <= maximumBytes
        else {
            throw RemoteControlError.invalidConfiguration("private file must be an owned 0600 regular file within the byte bound")
        }
        return try readAll(maximumBytes: maximumBytes) { buffer in
            Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    static func readAll(maximumBytes: Int, readChunk: (UnsafeMutableRawBufferPointer) -> Int) throws -> Data {
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes(readChunk)
            guard count >= 0 else { throw RemoteControlError.invalidConfiguration("private file could not be read") }
            if count == 0 { break }
            guard count <= buffer.count, output.count + count <= maximumBytes else {
                throw RemoteControlError.invalidConfiguration("private file exceeds the byte bound")
            }
            output.append(buffer, count: count)
        }
        return output
    }
}

public func remoteLoadRegistry(configPath: String) throws -> RemoteProfileRegistry {
    try RemoteProfileRegistry.decode(try RemotePrivateFile.read(path: configPath))
}

public enum RemoteProcessIdentityReader {
    public typealias Metadata = (pid: Int32, seconds: UInt64, microseconds: UInt64)

    public static func read(
        pid: Int32,
        generation: String,
        metadata: (Int32) -> Metadata?,
        executablePath: (Int32) -> String?
    ) -> RemoteProcessIdentity? {
        guard pid > 0, let metadata = metadata(pid), metadata.pid == pid, let path = executablePath(pid) else { return nil }
        return RemoteProcessIdentity(
            pid: pid,
            startIdentity: "\(metadata.seconds).\(metadata.microseconds)",
            executable: URL(fileURLWithPath: path).standardizedFileURL.path,
            generation: generation
        )
    }
}

public func remoteProcessIdentity(pid: Int32, generation: String) -> RemoteProcessIdentity? {
    RemoteProcessIdentityReader.read(
        pid: pid,
        generation: generation,
        metadata: RemoteNativeProcessIdentity.metadata,
        executablePath: RemoteNativeProcessIdentity.executablePath
    )
}

enum RemoteNativeProcessIdentity {
    static func metadata(pid: Int32) -> RemoteProcessIdentityReader.Metadata? {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let readSize = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, infoSize) }
        guard readSize == infoSize else { return nil }
        return (Int32(info.pbi_pid), UInt64(info.pbi_start_tvsec), UInt64(info.pbi_start_tvusec))
    }

    static func executablePath(pid: Int32) -> String? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        guard length > 0 else { return nil }
        return String(decoding: path.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public struct RemoteProcessSnapshot: Equatable, Sendable {
    public var arguments: [String]
    public var environment: [String: String]

    public init(arguments: [String], environment: [String: String]) {
        self.arguments = arguments
        self.environment = environment
    }
}

public enum RemoteArgvDigest {
    public static let unavailable = String(repeating: "0", count: 64)

    public static func sha256(_ arguments: [String]) -> String {
        RemoteArtifactVerifier.sha256(try! JSONEncoder().encode(arguments))
    }
}

public enum RemoteProcessArguments {
    public static func read(pid: Int32) -> [String]? {
        readSnapshot(pid: pid)?.arguments
    }

    public static func readSnapshot(pid: Int32) -> RemoteProcessSnapshot? {
        rawSnapshot(
            pid: pid,
            querySize: { candidate in
                var keys = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), candidate]
                var size = 0
                let result = sysctl(&keys, 3, nil, &size, nil, 0)
                return (result, size)
            },
            queryBytes: { candidate, capacity in
                var keys = [Int32(CTL_KERN), Int32(KERN_PROCARGS2), candidate]
                var size = capacity
                var bytes = [UInt8](repeating: 0, count: capacity)
                let result = bytes.withUnsafeMutableBytes { sysctl(&keys, 3, $0.baseAddress, &size, nil, 0) }
                return (result, size, bytes)
            }
        )
    }

    static func read(
        pid: Int32,
        querySize: (Int32) -> (result: Int32, size: Int),
        queryBytes: (Int32, Int) -> (result: Int32, size: Int, bytes: [UInt8])
    ) -> [String]? {
        rawSnapshot(pid: pid, querySize: querySize, queryBytes: queryBytes)?.arguments
    }

    static func rawSnapshot(
        pid: Int32,
        querySize: (Int32) -> (result: Int32, size: Int),
        queryBytes: (Int32, Int) -> (result: Int32, size: Int, bytes: [UInt8])
    ) -> RemoteProcessSnapshot? {
        guard pid > 0 else { return nil }
        let sizeResult = querySize(pid)
        guard sizeResult.result == 0, sizeResult.size >= MemoryLayout<Int32>.size, sizeResult.size <= 1_048_576 else { return nil }
        let bytesResult = queryBytes(pid, sizeResult.size)
        guard bytesResult.result == 0, bytesResult.size >= MemoryLayout<Int32>.size, bytesResult.size <= bytesResult.bytes.count else { return nil }
        var argumentCount: Int32 = 0
        withUnsafeMutableBytes(of: &argumentCount) { $0.copyBytes(from: bytesResult.bytes.prefix(MemoryLayout<Int32>.size)) }
        return decodeSnapshot(argumentCount: argumentCount, bytesAfterCount: Array(bytesResult.bytes[MemoryLayout<Int32>.size..<bytesResult.size]))
    }

    static func decode(argumentCount: Int32, bytesAfterCount bytes: [UInt8]) -> [String]? {
        decodeSnapshot(argumentCount: argumentCount, bytesAfterCount: bytes)?.arguments
    }

    static func decodeSnapshot(argumentCount: Int32, bytesAfterCount bytes: [UInt8]) -> RemoteProcessSnapshot? {
        guard argumentCount > 0, let executableEnd = bytes.firstIndex(of: 0) else { return nil }
        var offset = executableEnd
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        for _ in 0..<argumentCount {
            guard offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0), end > offset else { return nil }
            arguments.append(String(decoding: bytes[offset..<end], as: UTF8.self))
            offset = end + 1
        }
        var environment: [String: String] = [:]
        while offset < bytes.count {
            while offset < bytes.count, bytes[offset] == 0 { offset += 1 }
            guard offset < bytes.count else { break }
            guard let end = bytes[offset...].firstIndex(of: 0), end > offset else { return nil }
            let entry = String(decoding: bytes[offset..<end], as: UTF8.self)
            guard let separator = entry.firstIndex(of: "="), separator != entry.startIndex else { return nil }
            let key = String(entry[..<separator])
            guard environment[key] == nil else { return nil }
            environment[key] = String(entry[entry.index(after: separator)...])
            offset = end + 1
        }
        return RemoteProcessSnapshot(arguments: arguments, environment: environment)
    }
}

public enum RemoteNativeProcessIDs {
    public static func all() throws -> [Int32] {
        let estimated = proc_listallpids(nil, 0)
        let capacity = max(0, Int(estimated)) + 64
        var pids = [Int32](repeating: 0, count: capacity)
        let listed = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return try validated(estimated: estimated, capacity: capacity, listed: listed, pids: pids)
    }

    static func all(estimatedCount: () -> Int32, listedPIDs: (Int) -> [Int32]) throws -> [Int32] {
        let estimated = estimatedCount()
        let capacity = Int(estimated) + 64
        let listed = listedPIDs(capacity)
        return try validated(estimated: estimated, capacity: capacity, listed: Int32(listed.count), pids: listed)
    }

    static func validated(estimated: Int32, capacity: Int, listed: Int32, pids: [Int32]) throws -> [Int32] {
        guard estimated > 0, listed >= 0 else { throw RemoteControlError.guardian("Herdr process enumeration failed") }
        guard listed > 0, listed < capacity, listed <= pids.count else { throw RemoteControlError.guardian("Herdr process enumeration was incomplete") }
        return Array(pids.prefix(Int(listed)))
    }
}

public struct RemoteHerdrProcessScanner {
    public let herdrExecutable: String
    private let listProcessIDs: () throws -> [Int32]
    private let processIdentityForPID: (Int32, String) -> RemoteProcessIdentity?
    private let processArgumentsForPID: (Int32) -> [String]?

    public init(
        herdrExecutable: String,
        listProcessIDs: @escaping () throws -> [Int32] = RemoteNativeProcessIDs.all,
        processIdentityForPID: @escaping (Int32, String) -> RemoteProcessIdentity? = remoteProcessIdentity,
        processArgumentsForPID: @escaping (Int32) -> [String]? = RemoteProcessArguments.read
    ) {
        self.herdrExecutable = herdrExecutable
        self.listProcessIDs = listProcessIDs
        self.processIdentityForPID = processIdentityForPID
        self.processArgumentsForPID = processArgumentsForPID
    }

    public func listServerSessions() throws -> [String] {
        let resolvedHerdr = URL(fileURLWithPath: herdrExecutable).resolvingSymlinksInPath().standardizedFileURL.path
        var sessions = Set<String>()
        for pid in try listProcessIDs() where pid > 0 {
            guard let before = processIdentityForPID(pid, "process-inventory"), before.executable == resolvedHerdr else { continue }
            guard let argv = processArgumentsForPID(pid), processIdentityForPID(pid, "process-inventory") == before else {
                throw RemoteControlError.guardian("Herdr process identity changed during enumeration")
            }
            if let session = RemoteHerdrServerProcess.sessionName(executable: before.executable, argv: argv, expectedExecutable: herdrExecutable) {
                sessions.insert(session)
            } else if argv.contains("server") {
                throw RemoteControlError.guardian("Herdr server arguments are not exact")
            }
        }
        return sessions.sorted()
    }
}
