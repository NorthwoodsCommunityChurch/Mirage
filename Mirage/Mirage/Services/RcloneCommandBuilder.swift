import Foundation

struct RcloneCommandBuilder {
    let rclonePath: String
    let cacheBaseDir: String
    let logBaseDir: String

    init(
        rclonePath: String = "/usr/local/bin/rclone",
        cacheBaseDir: String? = nil,
        logBaseDir: String? = nil
    ) {
        self.rclonePath = rclonePath

        if let cacheBaseDir {
            self.cacheBaseDir = cacheBaseDir
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            self.cacheBaseDir = caches.appendingPathComponent("MountCache").path
        }

        if let logBaseDir {
            self.logBaseDir = logBaseDir
        } else {
            let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Logs/MountCache")
            self.logBaseDir = logs.path
        }
    }

    // MARK: - Config commands

    func createRemoteArguments(
        name: String,
        host: String,
        username: String,
        password: String,
        domain: String = "WORKGROUP"
    ) -> [String] {
        [
            "config", "create", name, "smb",
            "host=\(host)",
            "user=\(username)",
            "pass=\(password)",
            "domain=\(domain)",
        ]
    }

    func deleteRemoteArguments(name: String) -> [String] {
        ["config", "delete", name]
    }

    func listSharesArguments(remoteName: String) -> [String] {
        ["lsd", "\(remoteName):", "--format", "p"]
    }

    func listRemotesArguments() -> [String] {
        ["listremotes"]
    }

    func versionArguments() -> [String] {
        ["version"]
    }

    // MARK: - Mount command

    func mountArguments(share: SMBShareConfig, maxCacheSizeGB: Int? = nil) -> [String] {
        let cacheDir = cacheDirPath(for: share.id, customBase: share.customCachePath)
        let nfsCacheDir = nfsCacheDirPath(for: share.id, customBase: share.customCachePath)
        let logFile = logFilePath(for: share.rcloneRemoteName)

        var args = [
            "nfsmount",
            share.remotePath,
            share.mountPoint,
            "--vfs-cache-mode", share.cacheMode.rawValue,
            "--vfs-cache-max-age", formatDuration(share.cacheMaxAge),
            "--vfs-write-back", formatDuration(share.writeBack),
            "--vfs-cache-poll-interval", formatDuration(share.cachePollInterval),
            "--cache-dir", cacheDir,
            "--nfs-cache-type", "disk",
            "--nfs-cache-dir", nfsCacheDir,
            "--volname", share.volumeName,
            "--log-file", logFile,
            "--log-level", "INFO",
        ]

        // Let rclone enforce the user's storage limit for all folders.
        if let gb = maxCacheSizeGB, gb > 0 {
            args += ["--vfs-cache-max-size", "\(gb)G"]
        }

        return args
    }

    // MARK: - Paths

    func cacheDirPath(for shareId: UUID) -> String {
        "\(cacheBaseDir)/\(shareId.uuidString)/vfs"
    }

    func cacheDirPath(for shareId: UUID, customBase: String?) -> String {
        let base = customBase ?? cacheBaseDir
        return "\(base)/\(shareId.uuidString)/vfs"
    }

    func nfsCacheDirPath(for shareId: UUID) -> String {
        "\(cacheBaseDir)/\(shareId.uuidString)/nfs-handles"
    }

    func nfsCacheDirPath(for shareId: UUID, customBase: String?) -> String {
        let base = customBase ?? cacheBaseDir
        return "\(base)/\(shareId.uuidString)/nfs-handles"
    }

    func logFilePath(for remoteName: String) -> String {
        "\(logBaseDir)/\(remoteName).log"
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds)
        if totalSeconds >= 3600 && totalSeconds % 3600 == 0 {
            return "\(totalSeconds / 3600)h"
        } else if totalSeconds >= 60 && totalSeconds % 60 == 0 {
            return "\(totalSeconds / 60)m"
        } else {
            return "\(totalSeconds)s"
        }
    }
}
