import Foundation

struct SMBDropInfo {
    let host: String
    let shareName: String
    let subfolder: String
    let detectedUsername: String?
    let volumeName: String
}

enum SMBDetectionError: LocalizedError {
    case notNetworkVolume
    case notSMBVolume(String)
    case statfsFailed
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notNetworkVolume:
            return "The dropped item is not from a network volume."
        case .notSMBVolume(let fsType):
            return "The volume uses \(fsType), not SMB."
        case .statfsFailed:
            return "Could not determine volume information."
        case .parseFailed(let source):
            return "Could not parse SMB source: \(source)"
        }
    }
}

struct SMBShareDetector {
    /// Extracts SMB server info from a path on a mounted network share.
    static func detect(from url: URL) throws -> SMBDropInfo {
        AppLogger.shared.log("SMB detection started for: \(url.path)")
        // Check if it's a network volume
        let resourceValues = try url.resourceValues(forKeys: [
            .volumeIsLocalKey,
            .volumeURLKey,
            .volumeNameKey,
        ])

        guard resourceValues.volumeIsLocal == false else {
            throw SMBDetectionError.notNetworkVolume
        }

        let volumeName = resourceValues.volumeName ?? url.lastPathComponent

        // Use statfs to get mount source info
        var stat = statfs()
        guard statfs(url.path, &stat) == 0 else {
            throw SMBDetectionError.statfsFailed
        }

        // Extract filesystem type
        let fsType = withUnsafePointer(to: stat.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                String(cString: $0)
            }
        }

        guard fsType == "smbfs" else {
            throw SMBDetectionError.notSMBVolume(fsType)
        }

        // Extract mount source (e.g., "//user@server/share" or "//server/share")
        let mountSource = withUnsafePointer(to: stat.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }

        // Extract mount point
        let mountPoint = withUnsafePointer(to: stat.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }

        // Parse mount source: //[user@]host/share
        let parsed = try parseMountSource(mountSource)

        // Calculate subfolder (path relative to mount point)
        let filePath = url.path
        var subfolder = ""
        if filePath.hasPrefix(mountPoint) {
            subfolder = String(filePath.dropFirst(mountPoint.count))
            if subfolder.hasPrefix("/") {
                subfolder = String(subfolder.dropFirst())
            }
        }

        let decodedSubfolder = subfolder.removingPercentEncoding ?? subfolder
        let decodedVolumeName = volumeName.removingPercentEncoding ?? volumeName

        // Use the dragged folder's name as the default display name.
        // If a subfolder was detected, use its last component (e.g., "Music" from "Creative Arts/Music").
        // Otherwise fall back to the volume/share name.
        let defaultName: String
        if !decodedSubfolder.isEmpty {
            defaultName = (decodedSubfolder as NSString).lastPathComponent
        } else {
            defaultName = decodedVolumeName
        }

        return SMBDropInfo(
            host: parsed.host,
            shareName: parsed.share,
            subfolder: decodedSubfolder,
            detectedUsername: parsed.username,
            volumeName: defaultName
        )
    }

    private static func parseMountSource(_ source: String) throws -> (host: String, share: String, username: String?) {
        // Format: //[user@]host/share
        var working = source
        if working.hasPrefix("//") {
            working = String(working.dropFirst(2))
        }

        var username: String?

        // Check for user@host pattern
        if let atIndex = working.firstIndex(of: "@") {
            username = String(working[working.startIndex..<atIndex])
            working = String(working[working.index(after: atIndex)...])
        }

        // Split host/share
        guard let slashIndex = working.firstIndex(of: "/") else {
            throw SMBDetectionError.parseFailed(source)
        }

        let host = String(working[working.startIndex..<slashIndex])
        let shareRaw = String(working[working.index(after: slashIndex)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let share = shareRaw.removingPercentEncoding ?? shareRaw

        guard !host.isEmpty, !share.isEmpty else {
            throw SMBDetectionError.parseFailed(source)
        }

        return (host, share, username?.removingPercentEncoding ?? username)
    }
}
