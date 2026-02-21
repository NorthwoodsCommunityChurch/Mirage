import Foundation

/// Status of cache warming for a single project
enum WarmStatus: Equatable {
    case idle
    case scanning                // enumerating files on the remote
    case warming(filesWarmed: Int, totalFiles: Int, bytesDownloaded: UInt64, totalBytes: UInt64)
    case upToDate(fileCount: Int, totalSize: UInt64)
    case partial(filesCached: Int, totalFiles: Int, totalSize: UInt64) // stopped due to storage limit
    case error(String)
}

/// Downloads all files from a remote share using `rclone copy`, bypassing
/// the NFS mount entirely. This uses rclone's native parallel transfer
/// engine for maximum throughput and doesn't interfere with the mount.
///
/// When a project is set to "Keep Local", the CacheWarmer runs a separate
/// rclone process that copies files from the remote to the VFS cache
/// directory. A periodic re-sync catches new or changed files.
@MainActor
final class CacheWarmer: ObservableObject {
    @Published var warmStatuses: [UUID: WarmStatus] = [:]

    private var warmingTasks: [UUID: Task<Void, Never>] = [:]
    private var warmingProcesses: [UUID: Process] = [:]
    private var periodicTasks: [UUID: Task<Void, Never>] = [:]

    private weak var cacheManager: CacheManager?
    private var rclonePath: String = "/usr/local/bin/rclone"

    /// How often to re-sync for new files (10 minutes)
    private let resyncInterval: UInt64 = 10 * 60 * 1_000_000_000

    func setCacheManager(_ manager: CacheManager) {
        self.cacheManager = manager
    }

    func setRclonePath(_ path: String) {
        self.rclonePath = path
    }

    // MARK: - Start / Stop

    /// Begin warming all files for a project using rclone copy
    func startWarming(share: SMBShareConfig, maxCacheSizeGB: Int?) {
        stopWarming(shareId: share.id)
        warmStatuses[share.id] = .scanning

        let task = Task { [weak self] in
            await self?.warmFiles(share: share, maxCacheSizeGB: maxCacheSizeGB)

            // Schedule periodic re-sync
            guard !Task.isCancelled else { return }
            await self?.schedulePeriodicWarm(share: share, maxCacheSizeGB: maxCacheSizeGB)
        }
        warmingTasks[share.id] = task
    }

    /// Stop warming and unmark all offline files for a project
    func stopWarming(shareId: UUID) {
        warmingTasks[shareId]?.cancel()
        warmingTasks.removeValue(forKey: shareId)
        warmingProcesses[shareId]?.terminate()
        warmingProcesses.removeValue(forKey: shareId)
        periodicTasks[shareId]?.cancel()
        periodicTasks.removeValue(forKey: shareId)
        warmStatuses[shareId] = .idle
    }

    /// Cancel all warming tasks (called on app quit)
    func cancelAll() {
        for (id, task) in warmingTasks {
            task.cancel()
            warmStatuses[id] = .idle
        }
        warmingTasks.removeAll()
        for (_, process) in warmingProcesses {
            process.terminate()
        }
        warmingProcesses.removeAll()
        for (_, task) in periodicTasks {
            task.cancel()
        }
        periodicTasks.removeAll()
    }

    /// Unmark all offline files for a share (when switching from keepLocal to stream)
    func unmarkAllOffline(shareId: UUID) {
        guard let cacheManager else { return }
        let paths = cacheManager.offlinePathsFor(shareId: shareId)
        for path in paths {
            cacheManager.unmarkOffline(shareId: shareId, relativePath: path)
        }
    }

    // MARK: - Warming via rclone copy

    private func warmFiles(share: SMBShareConfig, maxCacheSizeGB: Int?) async {
        guard let cacheManager else {
            warmStatuses[share.id] = .error("Cache manager not available")
            return
        }

        let shareId = share.id

        // The VFS cache stores files at: <cache-dir>/vfs/<remote>/<path>
        // We copy directly into that structure so VFS recognizes them
        let cacheDirURL = cacheManager.cacheDir(for: shareId)

        // Build the destination path to match VFS cache structure:
        // <cache-dir>/vfs/<remoteName>/<shareName>/<subfolder>
        var destComponents = [cacheDirURL.path, "vfs", share.rcloneRemoteName, share.shareName]
        if !share.subfolder.isEmpty {
            let clean = share.subfolder.hasPrefix("/") ? String(share.subfolder.dropFirst()) : share.subfolder
            destComponents.append(clean)
        }
        let destPath = destComponents.joined(separator: "/")

        // Ensure destination exists
        try? FileManager.default.createDirectory(
            atPath: destPath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Use a stats file so we can parse rclone's progress output
        let statsFile = cacheDirURL
            .deletingLastPathComponent()
            .appendingPathComponent("warm-stats.json")

        // Build rclone copy command with aggressive parallelism
        var args = [
            "copy",
            share.remotePath,
            destPath,
            "--transfers", "8",
            "--checkers", "16",
            "--stats", "1s",
            "--stats-file-name-length", "0",
            "--use-json-log",
            "--stats-log-level", "NOTICE",
            "--log-file", statsFile.path,
            "--log-level", "NOTICE",
        ]

        // Enforce cache size limit — subtract what's already cached globally
        // so total disk usage never exceeds the user's setting
        if let gb = maxCacheSizeGB, gb > 0 {
            let maxBytes = UInt64(gb) * 1_073_741_824
            let usedBytes = cacheManager.totalCacheSize
            let remainingBytes = maxBytes > usedBytes ? maxBytes - usedBytes : 0
            let remainingMB = max(1, remainingBytes / (1024 * 1024)) // at least 1 MB
            args += ["--max-transfer", "\(remainingMB)M"]
        }

        AppLogger.shared.log("Cache warming started for '\(share.displayName)' via rclone copy")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rclonePath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        warmingProcesses[shareId] = process

        do {
            try process.run()
        } catch {
            warmStatuses[shareId] = .error("Failed to start rclone: \(error.localizedDescription)")
            warmingProcesses.removeValue(forKey: shareId)
            return
        }

        // Monitor progress by polling the stats file and cache directory
        warmStatuses[shareId] = .warming(filesWarmed: 0, totalFiles: 0, bytesDownloaded: 0, totalBytes: 0)

        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                warmingProcesses.removeValue(forKey: shareId)
                return
            }

            // Parse the latest stats from rclone's JSON log
            let stats = parseRcloneStats(from: statsFile)
            let cachedBytes = Self.directorySize(URL(fileURLWithPath: destPath))

            warmStatuses[shareId] = .warming(
                filesWarmed: stats.transfers,
                totalFiles: stats.totalFiles,
                bytesDownloaded: cachedBytes,
                totalBytes: stats.totalBytes
            )

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        warmingProcesses.removeValue(forKey: shareId)

        guard !Task.isCancelled else { return }

        // Clean up stats file
        try? FileManager.default.removeItem(at: statsFile)

        // Scan what we actually downloaded
        let downloadedFiles = Self.listFiles(at: URL(fileURLWithPath: destPath))
        let totalSize = downloadedFiles.reduce(UInt64(0)) { $0 + $1.size }

        // Mark all downloaded files as offline-protected
        let mountPrefix = share.mountPoint.hasSuffix("/") ? share.mountPoint : share.mountPoint + "/"
        for file in downloadedFiles {
            // Convert cache path to relative path for the share
            let relativePath = file.url.path.replacingOccurrences(of: destPath + "/", with: "")
            cacheManager.markOffline(shareId: shareId, relativePath: relativePath)
        }

        if process.terminationStatus == 0 {
            AppLogger.shared.log("Cache warming complete for '\(share.displayName)': \(downloadedFiles.count) files, \(totalSize.formattedByteCount)")
            warmStatuses[shareId] = .upToDate(fileCount: downloadedFiles.count, totalSize: totalSize)
        } else {
            // rclone exited with an error — could be partial transfer
            let exitMsg = process.terminationStatus == 15 ? "cancelled" : "rclone exit code \(process.terminationStatus)"
            AppLogger.shared.log("Cache warming ended for '\(share.displayName)': \(exitMsg)")
            if downloadedFiles.count > 0 {
                warmStatuses[shareId] = .partial(
                    filesCached: downloadedFiles.count,
                    totalFiles: downloadedFiles.count, // we don't know total from rclone exit
                    totalSize: totalSize
                )
            } else {
                warmStatuses[shareId] = .error("Download failed: \(exitMsg)")
            }
        }
    }

    // MARK: - rclone stats parsing

    private struct RcloneStats {
        var transfers: Int = 0
        var totalFiles: Int = 0
        var totalBytes: UInt64 = 0
    }

    /// Parse the last JSON stats line from rclone's log file
    private func parseRcloneStats(from url: URL) -> RcloneStats {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return RcloneStats()
        }

        // rclone writes one JSON object per stats line; we want the last one
        let lines = text.components(separatedBy: "\n").reversed()
        for line in lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let stats = json["stats"] as? [String: Any] else { continue }

            var result = RcloneStats()
            result.transfers = stats["transfers"] as? Int ?? 0
            result.totalBytes = stats["totalBytes"] as? UInt64
                ?? UInt64(stats["totalBytes"] as? Int ?? 0)

            // totalChecks gives us the file count (checker = file enumerated)
            let totalChecks = stats["totalChecks"] as? Int ?? 0
            let totalTransfers = stats["totalTransfers"] as? Int ?? 0
            result.totalFiles = max(totalChecks, totalTransfers)

            return result
        }

        return RcloneStats()
    }

    // MARK: - Helpers

    /// Sum of all file sizes in a directory
    private static func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    /// List all files with their sizes
    private static func listFiles(at url: URL) -> [(url: URL, size: UInt64)] {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(url: URL, size: UInt64)] = []
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            results.append((url: fileURL, size: UInt64(values.fileSize ?? 0)))
        }
        return results
    }

    private func schedulePeriodicWarm(share: SMBShareConfig, maxCacheSizeGB: Int?) async {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.resyncInterval ?? 600_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.warmFiles(share: share, maxCacheSizeGB: maxCacheSizeGB)
            }
        }
        periodicTasks[share.id] = task
    }
}
