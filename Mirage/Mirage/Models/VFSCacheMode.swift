import Foundation

enum VFSCacheMode: String, Codable, CaseIterable, Identifiable {
    case off = "off"
    case minimal = "minimal"
    case writes = "writes"
    case full = "full"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .writes: return "Writes"
        case .full: return "Full"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "No caching. All reads/writes go directly to the remote."
        case .minimal:
            return "Only files opened for both read and write are cached."
        case .writes:
            return "All written files are cached. Reads stream from remote."
        case .full:
            return "All reads and writes are cached locally. Best compatibility."
        }
    }
}
