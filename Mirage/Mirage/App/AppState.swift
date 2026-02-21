import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    // Sub-managers
    let shareStore = ShareStore()
    let processManager = RcloneProcessManager()
    let cacheManager: CacheManager
    let statusMonitor = StatusMonitor()
    let cacheWarmer = CacheWarmer()

    // Shares — forwarded from ShareStore so views observe changes properly.
    // (Nested ObservableObjects don't propagate objectWillChange automatically.)
    @Published var shares: [SMBShareConfig] = []

    // UI state
    @Published var selectedShareId: UUID?
    @Published var showAddShare = false
    @Published var showSettings = false
    @Published var mountStatuses: [UUID: MountStatus] = [:]
    @Published var rcloneValid = false
    @Published var rcloneVersion: String?
    @Published var alertMessage: String?
    @Published var showAlert = false

    // Pre-fill from drag-and-drop
    @Published var dropInfo: SMBDropInfo?

    // Cache warmer status per project
    @Published var warmStatuses: [UUID: WarmStatus] = [:]

    // Settings (persisted via UserDefaults)
    @AppStorage("rclonePath") var rclonePath = "/usr/local/bin/rclone" {
        didSet {
            rebuildCommandBuilder()
            cacheWarmer.setRclonePath(rclonePath)
        }
    }
    @AppStorage("globalMaxCacheGB") var globalMaxCacheGB = 50 {
        didSet { cacheManager.updateMaxCacheSize(gb: globalMaxCacheGB) }
    }
    @AppStorage("autoMountOnLaunch") var autoMountOnLaunch = true
    @AppStorage("launchAtLogin") var launchAtLogin = false
    @AppStorage("volumeLocation") var volumeLocation = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Volumes").path

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Initialize cache manager with saved setting
        let savedCacheGB = UserDefaults.standard.integer(forKey: "globalMaxCacheGB")
        cacheManager = CacheManager(maxCacheSizeGB: savedCacheGB > 0 ? savedCacheGB : 50)

        shareStore.load()
        shares = shareStore.shares
        rebuildCommandBuilder()
        syncCacheOverrides()

        // Forward shareStore changes to our @Published shares property
        shareStore.$shares
            .receive(on: DispatchQueue.main)
            .assign(to: &$shares)

        // Sync status monitor statuses to our published property
        statusMonitor.$mountStatuses
            .receive(on: DispatchQueue.main)
            .assign(to: &$mountStatuses)

        // Wire up cache warmer
        cacheWarmer.setCacheManager(cacheManager)
        cacheWarmer.setRclonePath(rclonePath)
        cacheWarmer.$warmStatuses
            .receive(on: DispatchQueue.main)
            .assign(to: &$warmStatuses)
    }

    // MARK: - Setup

    func initialSetup() async {
        AppLogger.shared.log("Initial setup started")
        let validation = await processManager.validateRclone()
        rcloneValid = validation.valid
        rcloneVersion = validation.version
        AppLogger.shared.log("rclone valid: \(validation.valid), version: \(validation.version ?? "nil")")

        // Clean up orphan rclone processes and stale NFS mounts from
        // previous app sessions that may have been force-quit.
        await processManager.cleanupOrphanMounts(shares: shareStore.shares)

        // Initial cache scan + enforce limit on startup
        await cacheManager.refreshCache(shareIds: shareStore.shares.map(\.id))
        _ = await cacheManager.evictIfNeeded(shareIds: shareStore.shares.map(\.id))

        statusMonitor.start(
            processManager: processManager,
            cacheManager: cacheManager,
            shareIds: shareStore.shares.map(\.id)
        )

        if autoMountOnLaunch && rcloneValid {
            await mountAutoShares()
        }
    }

    // MARK: - Mount operations

    func mount(shareId: UUID) async {
        guard let share = shareStore.share(for: shareId) else { return }

        // Prevent double-mounting — bail out if already active
        let currentStatus = mountStatuses[shareId]
        if currentStatus == .mounted || currentStatus == .indexing || currentStatus == .mounting {
            return
        }

        AppLogger.shared.log("Mount started for '\(share.displayName)' (\(share.host)/\(share.shareName))")

        // Check if custom cache location is available (e.g., external drive connected)
        if let customPath = share.customCachePath {
            if !FileManager.default.fileExists(atPath: customPath) {
                mountStatuses[shareId] = .error("Cache drive not available")
                showError("The cache drive for \"\(share.displayName)\" is not connected. Connect the drive and try again, or change the cache location in project settings.")
                return
            }
        }

        mountStatuses[shareId] = .mounting

        do {
            try await processManager.mount(share: share, maxCacheSizeGB: globalMaxCacheGB)
            mountStatuses[shareId] = .indexing
            AppLogger.shared.log("Mount succeeded for '\(share.displayName)', indexing files...")

            // Update last mounted date
            var updated = share
            updated.lastMounted = Date()
            shareStore.update(updated)

            statusMonitor.updateShareIds(shareStore.shares.map(\.id))

            // Start cache warming if this project is set to "Keep Local"
            if share.syncMode == .keepLocal {
                cacheWarmer.startWarming(share: share, maxCacheSizeGB: globalMaxCacheGB)
            }

            // Index the root directory in the background so the user sees activity.
            // rclone populates its directory cache on the first listing, which
            // generates network traffic. Show "Indexing..." until that finishes.
            let mountPoint = share.mountPoint
            let sid = share.id
            Task.detached {
                // This blocks until rclone fetches the root directory listing from SMB
                _ = try? FileManager.default.contentsOfDirectory(atPath: mountPoint)
                await MainActor.run { [weak self = self] in
                    guard let self else { return }
                    if self.mountStatuses[sid] == .indexing {
                        self.mountStatuses[sid] = .mounted
                        AppLogger.shared.log("Indexing complete for '\(share.displayName)'")
                    }
                }
            }
        } catch {
            AppLogger.shared.log("Mount failed for '\(share.displayName)': \(error.localizedDescription)")
            mountStatuses[shareId] = .error(error.localizedDescription)
            showError(error.localizedDescription)
        }
    }

    func unmount(shareId: UUID) async {
        guard let share = shareStore.share(for: shareId) else { return }
        AppLogger.shared.log("Unmount started for '\(share.displayName)'")
        mountStatuses[shareId] = .unmounting

        // Stop cache warming if active
        cacheWarmer.stopWarming(shareId: shareId)

        do {
            try await processManager.unmount(shareId: shareId, mountPoint: share.mountPoint)
            mountStatuses[shareId] = .disconnected

            // Clean up mount point directory — ONLY if it's an empty directory.
            // Using POSIX rmdir which fails on non-empty dirs, preventing
            // accidental recursive deletion if the NFS mount is still lingering.
            rmdir(share.mountPoint)

            // Run eviction check after unmount
            await cacheManager.refreshCache(shareIds: shareStore.shares.map(\.id))
            _ = await cacheManager.evictIfNeeded(shareIds: shareStore.shares.map(\.id))
        } catch {
            showError(error.localizedDescription)
        }
    }

    func mountAll() async {
        for share in shareStore.shares {
            if mountStatuses[share.id] != .mounted && mountStatuses[share.id] != .indexing {
                await mount(shareId: share.id)
            }
        }
    }

    func unmountAll() async {
        for share in shareStore.shares {
            if mountStatuses[share.id] == .mounted || mountStatuses[share.id] == .indexing {
                await unmount(shareId: share.id)
            }
        }
    }

    private func mountAutoShares() async {
        for share in shareStore.shares where share.autoMount {
            await mount(shareId: share.id)
        }
    }

    // MARK: - Share management

    func addShare(_ config: SMBShareConfig, password: String) async {
        AppLogger.shared.log("Adding share '\(config.displayName)' (\(config.host)/\(config.shareName))")
        do {
            // Store password in Keychain
            try shareStore.storePassword(password, for: config)

            // Create rclone remote
            try await processManager.createRemote(share: config, password: password)

            // Save to store
            shareStore.add(config)
            cacheManager.registerCachePath(for: config.id, path: config.customCachePath)
            statusMonitor.updateShareIds(shareStore.shares.map(\.id))
            mountStatuses[config.id] = .disconnected

            // Auto-mount if enabled
            if config.autoMount {
                await mount(shareId: config.id)
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// Save config and credentials, then return immediately so the sheet can dismiss.
    /// Mounting happens in the background — the card shows "Connecting..." status.
    func addShareAndDismiss(_ config: SMBShareConfig, password: String) async {
        do {
            try shareStore.storePassword(password, for: config)
            try await processManager.createRemote(share: config, password: password)

            shareStore.add(config)
            cacheManager.registerCachePath(for: config.id, path: config.customCachePath)
            statusMonitor.updateShareIds(shareStore.shares.map(\.id))
            mountStatuses[config.id] = .disconnected

            // Mount in a detached task so we return immediately
            if config.autoMount {
                let shareId = config.id
                Task { await self.mount(shareId: shareId) }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removeShare(id: UUID) async {
        guard let share = shareStore.share(for: id) else { return }
        AppLogger.shared.log("Removing share '\(share.displayName)'")

        // Unmount if running
        if mountStatuses[id]?.isActive == true {
            await unmount(shareId: id)
        }

        // Delete rclone remote
        try? await processManager.deleteRemote(name: share.rcloneRemoteName)

        // Clear cache (including offline markers)
        try? cacheManager.clearCache(for: id, protectOffline: false)

        // Remove custom cache override
        cacheManager.registerCachePath(for: id, path: nil)

        // Remove from store (also deletes Keychain entry)
        shareStore.remove(id: id)
        mountStatuses.removeValue(forKey: id)
        statusMonitor.updateShareIds(shareStore.shares.map(\.id))

        if selectedShareId == id {
            selectedShareId = shareStore.shares.first?.id
        }
    }

    func updateShare(_ config: SMBShareConfig) {
        shareStore.update(config)
    }

    // MARK: - Share browsing

    func listShares(for remoteName: String) async throws -> [String] {
        try await processManager.listShares(remoteName: remoteName)
    }

    // MARK: - Keep Local (cache warming)

    /// Enable "Keep on this Mac" for a project — forces full cache mode and starts warming
    func enableKeepLocal(shareId: UUID) async {
        guard var share = shareStore.share(for: shareId) else { return }
        share.syncMode = .keepLocal
        share.cacheMode = .full  // Required for VFS cache to store read files
        shareStore.update(share)

        // If already mounted, start warming immediately
        if mountStatuses[shareId] == .mounted {
            cacheWarmer.startWarming(share: share, maxCacheSizeGB: globalMaxCacheGB)
        }
        // If not mounted, warming will start after mount (see mount method)
    }

    /// Disable "Keep on this Mac" — stops warming, unmarks offline files
    func disableKeepLocal(shareId: UUID) {
        guard var share = shareStore.share(for: shareId) else { return }
        share.syncMode = .stream
        shareStore.update(share)

        cacheWarmer.stopWarming(shareId: shareId)
        cacheWarmer.unmarkAllOffline(shareId: shareId)
    }

    // MARK: - Keep Offline management (individual files)

    /// Mark a file/folder to keep offline (protected from cache eviction)
    func markOffline(shareId: UUID, relativePath: String) {
        cacheManager.markOffline(shareId: shareId, relativePath: relativePath)
    }

    /// Remove offline mark from a file/folder
    func unmarkOffline(shareId: UUID, relativePath: String) {
        cacheManager.unmarkOffline(shareId: shareId, relativePath: relativePath)
    }

    /// Check if a path is marked for offline access
    func isOffline(shareId: UUID, relativePath: String) -> Bool {
        cacheManager.isOffline(shareId: shareId, relativePath: relativePath)
    }

    // MARK: - Cache

    func clearCache(for shareId: UUID, includeOffline: Bool = false) {
        // Safety: never clear cache while mounted — VFS write-back may have
        // pending uploads that would be lost.
        guard mountStatuses[shareId] != .mounted else {
            showError("Cannot clear cache while share is mounted. Unmount first.")
            return
        }
        do {
            try cacheManager.clearCache(for: shareId, protectOffline: !includeOffline)
        } catch {
            showError("Failed to clear cache: \(error.localizedDescription)")
        }
    }

    func refreshCacheStats() async {
        await cacheManager.refreshCache(shareIds: shareStore.shares.map(\.id))
    }

    // MARK: - Cleanup

    func cleanup() {
        AppLogger.shared.log("Cleanup: stopping all services")
        cacheWarmer.cancelAll()
        statusMonitor.stop()
        processManager.terminateAll()
    }

    // MARK: - Menu bar icon

    var menuBarIconName: String {
        if mountStatuses.values.contains(where: {
            if case .error = $0 { return true }
            return false
        }) {
            return "externaldrive.badge.exclamationmark"
        } else if mountStatuses.values.contains(where: { $0 == .mounted || $0 == .indexing }) {
            return "externaldrive.fill.badge.checkmark"
        } else {
            return "externaldrive"
        }
    }

    // MARK: - Cache Location

    /// Register custom cache paths from all shares that have one configured.
    private func syncCacheOverrides() {
        for share in shareStore.shares {
            cacheManager.registerCachePath(for: share.id, path: share.customCachePath)
        }
    }

    /// Change the cache location for an existing project.
    /// Moves existing cached files to the new location.
    func changeCacheLocation(shareId: UUID, newPath: String?) async throws {
        guard let share = shareStore.share(for: shareId) else { return }

        // Safety: must not be mounted
        guard mountStatuses[shareId] != .mounted else {
            throw CacheLocationError.mustUnmountFirst
        }

        let oldShareDir = cacheManager.cacheDir(for: shareId).deletingLastPathComponent() // up from /vfs to /{shareId}

        // Update config
        var updated = share
        updated.customCachePath = newPath
        shareStore.update(updated)

        // Register the new override
        cacheManager.registerCachePath(for: shareId, path: newPath)

        let newShareDir = cacheManager.cacheDir(for: shareId).deletingLastPathComponent()

        // Move files if old cache exists and paths differ
        if oldShareDir != newShareDir && FileManager.default.fileExists(atPath: oldShareDir.path) {
            try FileManager.default.createDirectory(
                at: newShareDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: oldShareDir, to: newShareDir)
        }

        // Refresh cache stats
        await cacheManager.refreshCache(shareIds: shareStore.shares.map(\.id))
    }

    // MARK: - Helpers

    func rebuildCommandBuilder() {
        let builder = RcloneCommandBuilder(rclonePath: rclonePath)
        processManager.updateCommandBuilder(builder)
    }

    private func showError(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

enum CacheLocationError: LocalizedError {
    case mustUnmountFirst

    var errorDescription: String? {
        switch self {
        case .mustUnmountFirst:
            return "Please disconnect the project before changing its cache location."
        }
    }
}
