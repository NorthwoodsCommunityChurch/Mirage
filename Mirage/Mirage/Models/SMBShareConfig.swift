import Foundation

/// How a project handles local file storage
enum ProjectSyncMode: String, Codable, CaseIterable {
    case stream      // Mount only — files cache as accessed, evicted normally
    case keepLocal   // Mount + cache warmer — all files downloaded, protected from eviction
}

struct SMBShareConfig: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var host: String
    var shareName: String
    var subfolder: String
    var username: String
    var rcloneRemoteName: String
    var cacheMode: VFSCacheMode
    var cacheMaxAge: TimeInterval
    var writeBack: TimeInterval
    var cachePollInterval: TimeInterval
    var mountPoint: String
    var autoMount: Bool
    var volumeName: String
    var dateAdded: Date
    var lastMounted: Date?
    var syncMode: ProjectSyncMode
    var customCachePath: String? // nil = default ~/Library/Caches/MountCache

    enum CodingKeys: String, CodingKey {
        case id, displayName, host, shareName, subfolder, username
        case rcloneRemoteName, cacheMode, cacheMaxAge, writeBack
        case cachePollInterval, mountPoint, autoMount, volumeName
        case dateAdded, lastMounted, syncMode, customCachePath
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        host = try container.decode(String.self, forKey: .host)
        shareName = try container.decode(String.self, forKey: .shareName)
        subfolder = try container.decode(String.self, forKey: .subfolder)
        username = try container.decode(String.self, forKey: .username)
        rcloneRemoteName = try container.decode(String.self, forKey: .rcloneRemoteName)
        cacheMode = try container.decode(VFSCacheMode.self, forKey: .cacheMode)
        cacheMaxAge = try container.decode(TimeInterval.self, forKey: .cacheMaxAge)
        writeBack = try container.decode(TimeInterval.self, forKey: .writeBack)
        cachePollInterval = try container.decode(TimeInterval.self, forKey: .cachePollInterval)
        mountPoint = try container.decode(String.self, forKey: .mountPoint)
        autoMount = try container.decode(Bool.self, forKey: .autoMount)
        volumeName = try container.decode(String.self, forKey: .volumeName)
        dateAdded = try container.decode(Date.self, forKey: .dateAdded)
        lastMounted = try container.decodeIfPresent(Date.self, forKey: .lastMounted)
        // Default to .stream for configs saved before syncMode existed
        syncMode = try container.decodeIfPresent(ProjectSyncMode.self, forKey: .syncMode) ?? .stream
        customCachePath = try container.decodeIfPresent(String.self, forKey: .customCachePath)
    }

    init(
        id: UUID = UUID(),
        displayName: String,
        host: String,
        shareName: String,
        subfolder: String = "",
        username: String,
        cacheMode: VFSCacheMode = .full,
        cacheMaxAge: TimeInterval = 3600,
        writeBack: TimeInterval = 5,
        cachePollInterval: TimeInterval = 60,
        autoMount: Bool = true,
        volumeName: String? = nil,
        volumeBaseDir: String? = nil,
        syncMode: ProjectSyncMode = .stream,
        customCachePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.shareName = shareName
        self.subfolder = subfolder
        self.username = username
        self.rcloneRemoteName = "mountcache-\(id.uuidString.prefix(8).lowercased())"
        // Keep Local requires full cache mode so all reads are cached
        self.cacheMode = syncMode == .keepLocal ? .full : cacheMode
        self.cacheMaxAge = cacheMaxAge
        self.writeBack = writeBack
        self.cachePollInterval = cachePollInterval
        self.autoMount = autoMount
        self.syncMode = syncMode
        self.customCachePath = customCachePath

        let name = volumeName ?? displayName
        self.volumeName = name
        let baseDir = volumeBaseDir ?? "/Volumes"
        self.mountPoint = (baseDir as NSString).appendingPathComponent(name)
        self.dateAdded = Date()
        self.lastMounted = nil
    }

    /// The rclone remote path including share and subfolder
    var remotePath: String {
        if subfolder.isEmpty {
            return "\(rcloneRemoteName):\(shareName)"
        } else {
            let clean = subfolder.hasPrefix("/") ? String(subfolder.dropFirst()) : subfolder
            return "\(rcloneRemoteName):\(shareName)/\(clean)"
        }
    }
}
