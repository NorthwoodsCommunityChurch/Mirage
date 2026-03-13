import Foundation

/// Represents a cached file with its metadata
struct CachedFile: Identifiable, Comparable {
    let id: String // relative path within cache
    let url: URL
    let size: UInt64
    let accessDate: Date
    let isOffline: Bool // marked "keep offline"

    static func < (lhs: CachedFile, rhs: CachedFile) -> Bool {
        lhs.accessDate < rhs.accessDate
    }
}

/// Manages the unified cache system.
/// Uses rclone's VFS cache directory and handles eviction based on file access times.
@MainActor
final class CacheManager: ObservableObject {
    // MARK: - Published State

    @Published var cachedFiles: [UUID: [CachedFile]] = [:] // per-share
    @Published var totalCacheSize: UInt64 = 0
    @Published var offlineFileSize: UInt64 = 0

    var availableSpace: UInt64 {
        maxCacheSize > totalCacheSize ? maxCacheSize - totalCacheSize : 0
    }

    var usagePercent: Double {
        guard maxCacheSize > 0 else { return 0 }
        return Double(totalCacheSize) / Double(maxCacheSize)
    }

    // MARK: - Configuration

    let cacheBaseDir: URL
    var maxCacheSize: UInt64

    // Per-share cache location overrides (custom cache paths)
    private var cacheOverrides: [UUID: URL] = [:]

    // Paths marked "keep offline" - stored per share
    // Key: shareId, Value: set of relative paths
    private var offlinePaths: [UUID: Set<String>] = [:]
    private let offlinePathsURL: URL

    // MARK: - Init

    init(maxCacheSizeGB: Int = 50) {
        let caches = FileManager.default.safeURL(for: .cachesDirectory)
        self.cacheBaseDir = caches.appendingPathComponent("MountCache")
        self.maxCacheSize = UInt64(maxCacheSizeGB) * 1_073_741_824

        let appSupport = FileManager.default.safeURL(for: .applicationSupportDirectory)
        self.offlinePathsURL = appSupport
            .appendingPathComponent("MountCache")
            .appendingPathComponent("offline-paths.plist")

        try? FileManager.default.createDirectory(at: cacheBaseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: offlinePathsURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        loadOfflinePaths()
    }

    func updateMaxCacheSize(gb: Int) {
        maxCacheSize = UInt64(gb) * 1_073_741_824
    }

    // MARK: - Cache Directory

    /// Register a custom cache base directory for a specific share.
    /// Pass nil to revert to the default location.
    func registerCachePath(for shareId: UUID, path: String?) {
        if let path {
            cacheOverrides[shareId] = URL(fileURLWithPath: path)
        } else {
            cacheOverrides.removeValue(forKey: shareId)
        }
    }

    func cacheDir(for shareId: UUID) -> URL {
        let base = cacheOverrides[shareId] ?? cacheBaseDir
        return base.appendingPathComponent(shareId.uuidString).appendingPathComponent("vfs")
    }

    // MARK: - Scanning

    /// Scan all share caches and update state
    func refreshCache(shareIds: [UUID]) async {
        var allFiles: [UUID: [CachedFile]] = [:]
        var total: UInt64 = 0
        var offlineTotal: UInt64 = 0

        for shareId in shareIds {
            let files = await scanCacheDirectory(for: shareId)
            allFiles[shareId] = files

            for file in files {
                total += file.size
                if file.isOffline {
                    offlineTotal += file.size
                }
            }
        }

        cachedFiles = allFiles
        totalCacheSize = total
        offlineFileSize = offlineTotal
    }

    /// Scan a single share's cache directory (runs file I/O off main thread)
    private func scanCacheDirectory(for shareId: UUID) async -> [CachedFile] {
        let dir = cacheDir(for: shareId)
        let offlineSet = offlinePaths[shareId] ?? []

        // Move file enumeration off the main actor
        return await Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: dir.path) else { return [CachedFile]() }

            var files: [CachedFile] = []
            let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return [CachedFile]() }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }

                let relativePath = fileURL.path.replacingOccurrences(of: dir.path + "/", with: "")
                let size = UInt64(values.fileSize ?? 0)
                let accessDate = values.contentAccessDate ?? Date.distantPast
                let isOffline = offlineSet.contains(relativePath)

                files.append(CachedFile(
                    id: relativePath,
                    url: fileURL,
                    size: size,
                    accessDate: accessDate,
                    isOffline: isOffline
                ))
            }

            return files.sorted(by: >) // Most recently accessed first
        }.value
    }

    // MARK: - Keep Offline

    /// Mark a path to keep offline (protected from eviction)
    func markOffline(shareId: UUID, relativePath: String) {
        if offlinePaths[shareId] == nil {
            offlinePaths[shareId] = []
        }
        offlinePaths[shareId]?.insert(relativePath)
        saveOfflinePaths()
    }

    /// Remove offline mark from a path
    func unmarkOffline(shareId: UUID, relativePath: String) {
        offlinePaths[shareId]?.remove(relativePath)
        saveOfflinePaths()
    }

    /// Check if a path is marked offline
    func isOffline(shareId: UUID, relativePath: String) -> Bool {
        offlinePaths[shareId]?.contains(relativePath) ?? false
    }

    /// Get all offline paths for a share
    func offlinePathsFor(shareId: UUID) -> Set<String> {
        offlinePaths[shareId] ?? []
    }

    // MARK: - Eviction

    /// Evict files to get under the max cache size.
    /// First removes non-offline files (oldest first), then offline files if still over limit.
    /// The cache limit is a hard ceiling — even offline files are evicted if necessary.
    func evictIfNeeded(shareIds: [UUID]) async -> Int {
        guard totalCacheSize > maxCacheSize else { return 0 }

        // Two-pass eviction: non-offline first, then offline if still over limit
        var nonOffline: [(shareId: UUID, file: CachedFile)] = []
        var offline: [(shareId: UUID, file: CachedFile)] = []
        for shareId in shareIds {
            let files = cachedFiles[shareId] ?? []
            for file in files {
                if file.isOffline {
                    offline.append((shareId, file))
                } else {
                    nonOffline.append((shareId, file))
                }
            }
        }
        // Oldest-accessed files evicted first within each group
        nonOffline.sort { $0.file.accessDate < $1.file.accessDate }
        offline.sort { $0.file.accessDate < $1.file.accessDate }

        var bytesToFree = totalCacheSize - maxCacheSize
        var evictedCount = 0

        // Pass 1: evict non-offline files
        for (_, file) in nonOffline {
            guard bytesToFree > 0 else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
                bytesToFree = bytesToFree > file.size ? bytesToFree - file.size : 0
                evictedCount += 1
            } catch {
                // Skip files we can't delete
            }
        }

        // Pass 2: if still over limit, evict offline files too and unmark them
        for (shareId, file) in offline {
            guard bytesToFree > 0 else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
                unmarkOffline(shareId: shareId, relativePath: file.id)
                bytesToFree = bytesToFree > file.size ? bytesToFree - file.size : 0
                evictedCount += 1
            } catch {
                // Skip files we can't delete
            }
        }

        // Refresh state after eviction
        await refreshCache(shareIds: shareIds)

        return evictedCount
    }

    // MARK: - Cache Clearing

    /// Clear all cached files for a share (respects offline files if protect is true)
    func clearCache(for shareId: UUID, protectOffline: Bool = true) throws {
        let dir = cacheDir(for: shareId)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }

        if protectOffline {
            // Only delete non-offline files
            let offlineSet = offlinePaths[shareId] ?? []
            let files = cachedFiles[shareId] ?? []
            for file in files where !offlineSet.contains(file.id) {
                try? FileManager.default.removeItem(at: file.url)
            }
        } else {
            // Delete everything
            try FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            offlinePaths[shareId] = nil
            saveOfflinePaths()
        }
    }

    /// Clear all caches for all shares (including custom cache locations)
    func clearAllCaches() throws {
        // Clear custom cache locations first
        for (shareId, baseURL) in cacheOverrides {
            let shareDir = baseURL.appendingPathComponent(shareId.uuidString)
            if FileManager.default.fileExists(atPath: shareDir.path) {
                try? FileManager.default.removeItem(at: shareDir)
            }
        }

        // Clear default cache location
        if FileManager.default.fileExists(atPath: cacheBaseDir.path) {
            try FileManager.default.removeItem(at: cacheBaseDir)
            try FileManager.default.createDirectory(at: cacheBaseDir, withIntermediateDirectories: true)
        }
        offlinePaths.removeAll()
        saveOfflinePaths()
        cachedFiles.removeAll()
        totalCacheSize = 0
        offlineFileSize = 0
    }

    // MARK: - Persistence

    private func loadOfflinePaths() {
        guard FileManager.default.fileExists(atPath: offlinePathsURL.path),
              let data = try? Data(contentsOf: offlinePathsURL),
              let dict = try? PropertyListDecoder().decode([String: [String]].self, from: data) else {
            return
        }

        for (key, paths) in dict {
            if let uuid = UUID(uuidString: key) {
                offlinePaths[uuid] = Set(paths)
            }
        }
    }

    private func saveOfflinePaths() {
        var dict: [String: [String]] = [:]
        for (uuid, paths) in offlinePaths {
            dict[uuid.uuidString] = Array(paths)
        }

        if let data = try? PropertyListEncoder().encode(dict) {
            try? data.write(to: offlinePathsURL)
        }
    }
}
