import Foundation

/// User-facing terminology for Mirage.
/// Maps internal/technical terms to creative-friendly language.
enum Term {
    // Entity names
    static let project = "Project"
    static let projects = "Projects"

    // Status
    static func status(for mountStatus: MountStatus) -> String {
        switch mountStatus {
        case .disconnected: return "Offline"
        case .mounting: return "Connecting..."
        case .indexing: return "Indexing files..."
        case .mounted: return "Connected"
        case .error: return "Connection Error"
        case .unmounting: return "Disconnecting..."
        }
    }

    // Actions
    static let connect = "Connect"
    static let disconnect = "Disconnect"
    static let connectAll = "Connect All"
    static let disconnectAll = "Disconnect All"
    static let addProject = "Add a Folder"
    static let removeProject = "Remove Project"
    static let openInFinder = "Open in Finder"

    // Storage
    static let localStorage = "Local Storage"
    static let keepLocal = "Keep on this Mac"
    static let streamFromServer = "Stream from server"
    static let freeUpSpace = "Free Up Space"

    // Sync mode descriptions
    static func syncModeDescription(for mode: VFSCacheMode) -> String {
        switch mode {
        case .off: return "Stream everything — nothing stored locally"
        case .minimal: return "Only files you edit are stored locally"
        case .writes: return "Your changes are stored locally. Other files stream."
        case .full: return "Everything you open is stored locally. Most reliable."
        }
    }

    static func syncModeName(for mode: VFSCacheMode) -> String {
        switch mode {
        case .off: return "Stream Only"
        case .minimal: return "Minimal"
        case .writes: return "Edits Only"
        case .full: return "Full Local"
        }
    }

    // Settings
    static let saveDelay = "Save Delay"
    static let keepFilesFor = "Keep files for"
    static let autoConnect = "Auto-connect on launch"

    // Onboarding
    static let settingUp = "Setting up Mirage"
    static let settingUpDetail = "Mirage needs a small download to connect to your server files."
}
