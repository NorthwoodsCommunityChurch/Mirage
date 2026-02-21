import SwiftUI

enum MirageStyle {
    // Brand accent — Northwoods blue
    static let accent = Color(red: 0.008, green: 0.322, blue: 0.541) // #02528A

    // Status colors
    static let connected = Color.green
    static let syncing = Color.blue
    static let disconnected = Color.gray
    static let error = Color.red

    // Card styling
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let cardShadowRadius: CGFloat = 2
    static let cardShadowY: CGFloat = 1

    // Spacing
    static let gridSpacing: CGFloat = 16
    static let sectionSpacing: CGFloat = 20

    // Status color mapping
    static func statusColor(for status: MountStatus) -> Color {
        switch status {
        case .mounted: return connected
        case .mounting, .indexing, .unmounting: return syncing
        case .error: return error
        case .disconnected: return disconnected
        }
    }
}
