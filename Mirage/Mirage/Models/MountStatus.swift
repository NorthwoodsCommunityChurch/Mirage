import Foundation

enum MountStatus: Equatable {
    case disconnected
    case mounting
    case indexing       // mount is live, rclone is building its directory cache
    case mounted
    case error(String)
    case unmounting

    var displayName: String {
        switch self {
        case .disconnected: return "Offline"
        case .mounting: return "Mounting..."
        case .indexing: return "Indexing..."
        case .mounted: return "Mounted"
        case .error: return "Error"
        case .unmounting: return "Unmounting..."
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected: return "externaldrive"
        case .mounting: return "externaldrive.badge.timemachine"
        case .indexing: return "externaldrive.badge.timemachine"
        case .mounted: return "externaldrive.fill.badge.checkmark"
        case .error: return "externaldrive.badge.exclamationmark"
        case .unmounting: return "externaldrive.badge.minus"
        }
    }

    var isActive: Bool {
        switch self {
        case .mounting, .indexing, .mounted, .unmounting: return true
        default: return false
        }
    }
}
