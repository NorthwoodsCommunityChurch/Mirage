import Foundation

/// Tracks download progress and enforces a byte budget from concurrent tasks
private actor DownloadProgress {
    private(set) var completedURLs: [URL] = []
    private(set) var totalBytesWarmed: UInt64 = 0
    private let byteBudget: UInt64
    private(set) var isFinished = false
    var count: Int { completedURLs.count }

    init(byteBudget: UInt64) {
        self.byteBudget = byteBudget
    }

    /// Reserve space for a file. Returns true if within budget, false if over.
    func reserve(bytes: UInt64) -> Bool {
        guard totalBytesWarmed + bytes <= byteBudget else { return false }
        totalBytesWarmed += bytes
        return true
    }

    func addCompleted(_ url: URL) {
        completedURLs.append(url)
    }

    func markFinished() {
        isFinished = true
    }
}

/// Status of cache warming for a single project
enum WarmStatus: Equatable {
    case idle
    case warming(filesWarmed: Int, totalFiles: Int)
    case upToDate(fileCount: Int, totalSize: UInt64)
    case partial(filesCached: Int, totalFiles: Int, totalSize: UInt64) // stopped due to storage limit
    case error(String)
}

/// Walks a mounted directory and reads files to populate rclone's VFS cache.
///
/// When a project is set to "Keep Local", the CacheWarmer enumerates all files
/// under the mount point and reads each file in full. This forces rclone to
/// download and cache every byte. Each warmed file is then marked as
/// "keep offline" so CacheManager won't evict it.
///
/// A periodic re-walk catches new or changed files on the server.
@MainActor
final class CacheWarmer: ObservableObject {
    @Published var warmStatuses: [UUID: WarmStatus] = [:]

    private var warmingTasks: [UUID: Task<Void, Never>] = [:]
    private var periodicTasks: [UUID: Task<Void, Never>] = [:]

    private weak var cacheManager: CacheManager?

    /// How often to re-walk for new files (10 minutes)
    private let rewarmInterval: UInt64 = 10 * 60 * 1_000_000_000

    /// Number of files to download concurrently
    private let concurrentDownloads = 6

    func setCacheManager(_ manager: CacheManager) {
        self.cacheManager = manager
    }

    // MARK: - Start / Stop

    /// Begin warming all files under the mount point for a project
    func startWarming(shareId: UUID, mountPoint: String) {
        stopWarming(shareId: shareId)
        warmStatuses[shareId] = .warming(filesWarmed: 0, totalFiles: 0)

        let task = Task { [weak self] in
            await self?.warmFiles(shareId: shareId, mountPoint: mountPoint)

            // Schedule periodic re-warm
            guard !Task.isCancelled else { return }
            await self?.schedulePeriodicWarm(shareId: shareId, mountPoint: mountPoint)
        }
        warmingTasks[shareId] = task
    }

    /// Stop warming and unmark all offline files for a project
    func stopWarming(shareId: UUID) {
        warmingTasks[shareId]?.cancel()
        warmingTasks.removeValue(forKey: shareId)
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

    // MARK: - Warming Logic

    private func warmFiles(shareId: UUID, mountPoint: String) async {
        guard let cacheManager else {
            warmStatuses[shareId] = .error("Cache manager not available")
            return
        }

        let mountURL = URL(fileURLWithPath: mountPoint)
        guard FileManager.default.fileExists(atPath: mountPoint) else {
            warmStatuses[shareId] = .error("Mount point not accessible")
            return
        }

        // Enumerate all files under the mount
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: mountURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            warmStatuses[shareId] = .error("Could not enumerate files")
            return
        }

        // Collect file URLs and their sizes so we can enforce the cache budget
        var fileEntries: [(url: URL, size: UInt64)] = []
        for case let fileURL as URL in enumerator {
            guard !Task.isCancelled else { return }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = UInt64(values.fileSize ?? 0)
            fileEntries.append((url: fileURL, size: size))
        }

        guard !Task.isCancelled else { return }

        // Calculate the byte budget: how much space is available in the cache
        let existingCacheSize = cacheManager.totalCacheSize
        let maxCacheSize = cacheManager.maxCacheSize
        let byteBudget = maxCacheSize > existingCacheSize ? maxCacheSize - existingCacheSize : 0

        // Filter out files that won't fit individually, then sort smallest-first
        // to maximize the number of files we can cache
        let totalOnServer = fileEntries.count
        fileEntries = fileEntries
            .filter { $0.size <= byteBudget }
            .sorted { $0.size < $1.size }

        warmStatuses[shareId] = .warming(filesWarmed: 0, totalFiles: totalOnServer)

        let mountPrefix = mountPoint.hasSuffix("/") ? mountPoint : mountPoint + "/"
        let progress = DownloadProgress(byteBudget: byteBudget)
        let maxConcurrent = concurrentDownloads

        // Run all downloads in a DETACHED task so they escape @MainActor
        // and actually run in parallel. withTaskGroup inside @MainActor
        // serializes child tasks — this is the workaround.
        let downloadTask = Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var inFlight = 0

                for entry in fileEntries {
                    guard !Task.isCancelled else { break }

                    // Check budget before starting a new download
                    let reserved = await progress.reserve(bytes: entry.size)
                    guard reserved else { break }

                    // Limit concurrent downloads
                    if inFlight >= maxConcurrent {
                        _ = await group.next()
                        inFlight -= 1
                    }

                    let fileURL = entry.url
                    group.addTask {
                        do {
                            let handle = try FileHandle(forReadingFrom: fileURL)
                            defer { try? handle.close() }
                            // Read in 1 MB chunks — larger chunks = fewer round-trips
                            while true {
                                guard let chunk = try handle.read(upToCount: 1_048_576),
                                      !chunk.isEmpty else { break }
                            }
                            await progress.addCompleted(fileURL)
                        } catch {
                            // Skip files we can't read (I/O errors on network mounts, etc.)
                        }
                    }
                    inFlight += 1
                }

                // Wait for remaining downloads
                await group.waitForAll()
            }
            await progress.markFinished()
        }

        // Monitor progress from the main actor so the UI updates
        while true {
            let count = await progress.count
            let finished = await progress.isFinished
            if finished { break }
            if Task.isCancelled { downloadTask.cancel(); return }
            warmStatuses[shareId] = .warming(filesWarmed: count, totalFiles: totalOnServer)
            try? await Task.sleep(nanoseconds: 500_000_000) // update every 0.5s
        }
        await downloadTask.value

        guard !Task.isCancelled else { return }

        // Mark all successfully downloaded files as offline-protected
        let completedURLs = await progress.completedURLs
        for url in completedURLs {
            let path = url.path.replacingOccurrences(of: mountPrefix, with: "")
            cacheManager.markOffline(shareId: shareId, relativePath: path)
        }

        // Refresh cache stats and use actual cached sizes for the final status
        await cacheManager.refreshCache(shareIds: [shareId])
        let actualCached = cacheManager.cachedFiles[shareId] ?? []
        let actualSize = actualCached.reduce(UInt64(0)) { $0 + $1.size }

        if completedURLs.count < totalOnServer {
            // Not all files were downloaded — storage budget ran out
            warmStatuses[shareId] = .partial(
                filesCached: actualCached.count,
                totalFiles: totalOnServer,
                totalSize: actualSize
            )
        } else {
            warmStatuses[shareId] = .upToDate(fileCount: actualCached.count, totalSize: actualSize)
        }
    }

    private func schedulePeriodicWarm(shareId: UUID, mountPoint: String) async {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: self?.rewarmInterval ?? 600_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.warmFiles(shareId: shareId, mountPoint: mountPoint)
            }
        }
        periodicTasks[shareId] = task
    }
}
