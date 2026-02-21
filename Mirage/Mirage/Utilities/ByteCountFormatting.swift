import Foundation

extension UInt64 {
    /// Formats a byte count into a human-readable string (e.g., "2.3 GB").
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}

extension Int64 {
    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
