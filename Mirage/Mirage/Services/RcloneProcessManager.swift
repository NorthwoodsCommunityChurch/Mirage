import Foundation

@MainActor
final class RcloneProcessManager: ObservableObject {
    struct MountProcess {
        let process: Process
        let stderrPipe: Pipe
        var lastError: String?
    }

    @Published var runningMounts: [UUID: MountProcess] = [:]

    private var commandBuilder: RcloneCommandBuilder

    init(commandBuilder: RcloneCommandBuilder = RcloneCommandBuilder()) {
        self.commandBuilder = commandBuilder
    }

    func updateCommandBuilder(_ builder: RcloneCommandBuilder) {
        self.commandBuilder = builder
    }

    // MARK: - rclone binary

    var rcloneURL: URL {
        URL(fileURLWithPath: commandBuilder.rclonePath)
    }

    func validateRclone() async -> (valid: Bool, version: String?) {
        do {
            let result = try await Process.run(
                executableURL: rcloneURL,
                arguments: commandBuilder.versionArguments()
            )
            if result.exitCode == 0 {
                let firstLine = result.output.components(separatedBy: "\n").first ?? ""
                return (true, firstLine)
            }
            return (false, nil)
        } catch {
            return (false, nil)
        }
    }

    // MARK: - Remote config management

    func createRemote(share: SMBShareConfig, password: String) async throws {
        let args = commandBuilder.createRemoteArguments(
            name: share.rcloneRemoteName,
            host: share.host,
            username: share.username,
            password: password
        )

        let result = try await Process.run(executableURL: rcloneURL, arguments: args)
        if result.exitCode != 0 {
            throw RcloneError.configCreateFailed(result.error)
        }
    }

    func deleteRemote(name: String) async throws {
        let args = commandBuilder.deleteRemoteArguments(name: name)
        let result = try await Process.run(executableURL: rcloneURL, arguments: args)
        if result.exitCode != 0 {
            throw RcloneError.configDeleteFailed(result.error)
        }
    }

    func listShares(remoteName: String) async throws -> [String] {
        let args = commandBuilder.listSharesArguments(remoteName: remoteName)
        let result = try await Process.run(executableURL: rcloneURL, arguments: args)
        if result.exitCode != 0 {
            throw RcloneError.listSharesFailed(result.error)
        }
        return result.output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "/"))) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Mount / Unmount

    func mount(share: SMBShareConfig, maxCacheSizeGB: Int? = nil) async throws {
        guard runningMounts[share.id] == nil else {
            throw RcloneError.alreadyMounted
        }

        // Ensure mount point directory exists
        let mountURL = URL(fileURLWithPath: share.mountPoint)
        do {
            try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        } catch {
            // /Volumes/ requires root — use privileged helper
            try await createDirectoryPrivileged(share.mountPoint)
        }

        // Ensure cache directories exist (respects custom cache location)
        let cacheDir = URL(fileURLWithPath: commandBuilder.cacheDirPath(for: share.id, customBase: share.customCachePath))
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let nfsCacheDir = URL(fileURLWithPath: commandBuilder.nfsCacheDirPath(for: share.id, customBase: share.customCachePath))
        try FileManager.default.createDirectory(at: nfsCacheDir, withIntermediateDirectories: true)

        // Ensure log directory exists
        let logDir = URL(fileURLWithPath: commandBuilder.logBaseDir)
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        let args = commandBuilder.mountArguments(share: share, maxCacheSizeGB: maxCacheSizeGB)

        let process = Process()
        process.executableURL = rcloneURL
        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        // Capture stderr output in background using a class for thread safety
        let shareId = share.id
        let errorCollector = ErrorCollector()
        stderrPipe.fileHandleForReading.readabilityHandler = { [errorCollector] handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                errorCollector.append(str)
            }
        }

        // Handle unexpected termination
        process.terminationHandler = { [weak self, errorCollector] proc in
            Task { @MainActor [weak self] in
                guard let self, self.runningMounts[shareId] != nil else { return }
                if proc.terminationStatus != 0 && proc.terminationStatus != 15 { // 15 = SIGTERM
                    self.runningMounts[shareId]?.lastError = errorCollector.value
                }
                self.runningMounts.removeValue(forKey: shareId)
            }
        }

        try process.run()
        AppLogger.shared.log("rclone process spawned (PID \(process.processIdentifier)) for '\(share.displayName)'")

        runningMounts[share.id] = MountProcess(
            process: process,
            stderrPipe: stderrPipe
        )

        // Wait for mount to become available. rclone needs time to start
        // the NFS server and mount it. Check both process health and that
        // the mount point is actually accessible.
        var mounted = false
        for _ in 0..<20 { // Up to 10 seconds (20 × 500ms)
            try await Task.sleep(nanoseconds: 500_000_000)

            if !process.isRunning {
                runningMounts.removeValue(forKey: share.id)
                throw RcloneError.mountFailed(errorCollector.value)
            }

            if isMountPointActive(share.mountPoint) {
                mounted = true
                break
            }
        }

        if !mounted {
            // Process is running but mount point never became accessible
            process.terminate()
            runningMounts.removeValue(forKey: share.id)
            throw RcloneError.mountFailed("Mount point not accessible after timeout. \(errorCollector.value)")
        }
    }

    func unmount(shareId: UUID, mountPoint: String? = nil) async throws {
        if let mountProcess = runningMounts[shareId] {
            let process = mountProcess.process
            process.terminate() // Sends SIGTERM — rclone will flush pending VFS write-backs

            // Wait for graceful shutdown. Allow up to 30 seconds because rclone
            // needs time to flush any pending VFS write-back uploads to the remote.
            // Killing rclone before write-back completes would lose data.
            for _ in 0..<300 { // 30 seconds max
                if !process.isRunning { break }
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            // Force kill only as last resort — pending writes may be lost
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }

            runningMounts.removeValue(forKey: shareId)
        }

        // Always force-unmount the NFS mount point. The NFS mount can persist
        // after rclone exits (e.g., orphan from a previous app session).
        if let path = mountPoint {
            await forceUnmountNFS(path)
        }
    }

    func unmountAll() async {
        for shareId in runningMounts.keys {
            try? await unmount(shareId: shareId)
        }
    }

    func terminateAll() {
        AppLogger.shared.log("Terminating all rclone processes (\(runningMounts.count) active)")
        // Collect PIDs before clearing state
        var pids: [Int32] = []
        for (_, mountProcess) in runningMounts {
            mountProcess.process.terminate()
            pids.append(mountProcess.process.processIdentifier)
        }
        runningMounts.removeAll()

        // Give processes a moment, then force kill any stragglers
        let capturedPids = pids
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for pid in capturedPids {
                // Check if process still exists before sending SIGKILL
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    func isRunning(shareId: UUID) -> Bool {
        runningMounts[shareId]?.process.isRunning ?? false
    }

    func lastError(shareId: UUID) -> String? {
        runningMounts[shareId]?.lastError
    }

    /// Kill any orphan rclone nfsmount processes from previous app sessions
    /// and unmount their stale NFS mounts. Called on app startup before mounting.
    func cleanupOrphanMounts(shares: [SMBShareConfig]) async {
        for share in shares {
            // Kill any rclone process using this remote name
            await killOrphanRclone(remoteName: share.rcloneRemoteName)
            // Force-unmount any stale NFS mount at this mount point
            await forceUnmountNFS(share.mountPoint)
        }

        // Verify all mount points are actually free before returning.
        // The NFS unmount can take a moment to fully release.
        for _ in 0..<10 { // Up to 5 seconds
            let anyStillMounted = shares.contains { isMountPointActive($0.mountPoint) }
            if !anyStillMounted { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
            // Retry unmount for any that are still active
            for share in shares where isMountPointActive(share.mountPoint) {
                await forceUnmountNFS(share.mountPoint)
            }
        }
    }

    /// Force-unmount an NFS mount point using the system `umount` command.
    private func forceUnmountNFS(_ path: String) async {
        _ = try? await Process.run(
            executableURL: URL(fileURLWithPath: "/sbin/umount"),
            arguments: [path]
        )
    }

    /// Kill any rclone processes matching a specific remote name.
    private func killOrphanRclone(remoteName: String) async {
        // Use pkill to find and kill rclone processes with this remote name
        _ = try? await Process.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/pkill"),
            arguments: ["-f", "rclone nfsmount \(remoteName):"]
        )
        // Brief pause to let processes exit
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// Check whether a path is an active NFS mount point (used by rclone nfsmount).
    private func isMountPointActive(_ path: String) -> Bool {
        var buf = statfs()
        guard statfs(path, &buf) == 0 else { return false }
        let fsType = withUnsafePointer(to: buf.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: buf.f_fstypename)) {
                String(cString: $0)
            }
        }
        return fsType == "nfs"
    }

    /// Creates a directory using elevated privileges (prompts for admin password).
    private func createDirectoryPrivileged(_ path: String) async throws {
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"mkdir -p '\(escapedPath)'\" with administrator privileges"
        let result = try await Process.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script]
        )
        if result.exitCode != 0 {
            throw RcloneError.mountFailed("Failed to create mount point: \(result.error)")
        }
    }
}

// MARK: - Thread-safe error collector

/// Collects error output from rclone stderr in a thread-safe manner.
private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func append(_ str: String) {
        lock.lock()
        defer { lock.unlock() }
        _value += str
    }
}

// MARK: - Errors

enum RcloneError: LocalizedError {
    case configCreateFailed(String)
    case configDeleteFailed(String)
    case listSharesFailed(String)
    case mountFailed(String)
    case alreadyMounted
    case notMounted
    case rcloneNotFound

    var errorDescription: String? {
        switch self {
        case .configCreateFailed(let msg):
            return "Failed to create rclone remote: \(msg)"
        case .configDeleteFailed(let msg):
            return "Failed to delete rclone remote: \(msg)"
        case .listSharesFailed(let msg):
            return "Failed to list shares: \(msg)"
        case .mountFailed(let msg):
            return "Mount failed: \(msg)"
        case .alreadyMounted:
            return "This share is already mounted."
        case .notMounted:
            return "This share is not currently mounted."
        case .rcloneNotFound:
            return "rclone binary not found. Please install rclone or set the correct path in Settings."
        }
    }
}
