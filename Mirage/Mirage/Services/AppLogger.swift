import Foundation

/// Rolling activity log for crash diagnostics.
/// Writes timestamped entries to ~/Library/Logs/MountCache/mirage-activity.log.
/// Thread-safe via a serial DispatchQueue. Uses POSIX file writes for signal safety.
final class AppLogger {
    static let shared = AppLogger()

    private let queue = DispatchQueue(label: "com.mirage.applogger")
    private let maxLines = 1000
    private let logURL: URL

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/MountCache")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        logURL = logs.appendingPathComponent("mirage-activity.log")
    }

    /// The file path for external readers (e.g., crash reporter).
    var logFilePath: String { logURL.path }

    /// Append a timestamped line to the activity log.
    func log(_ message: String) {
        let timestamp = ISO8601DateFormatter.shared.string(from: Date())
        let line = "[\(timestamp)] \(message)\n"

        queue.async { [logURL, maxLines] in
            // Append using POSIX for signal safety
            let cPath = logURL.path
            let fd = open(cPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            guard fd >= 0 else { return }
            line.utf8CString.withUnsafeBufferPointer { buf in
                // Don't write the null terminator
                let count = buf.count - 1
                if count > 0 {
                    _ = write(fd, buf.baseAddress!, count)
                }
            }
            close(fd)

            // Truncate if over max lines (do this less frequently to avoid overhead)
            AppLogger.truncateIfNeeded(path: cPath, maxLines: maxLines)
        }
    }

    /// Read the last N lines from the activity log.
    func lastLines(_ count: Int) -> String {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        let tail = lines.suffix(count)
        return tail.joined(separator: "\n")
    }

    private static func truncateIfNeeded(path: String, maxLines: Int) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else { return }

        let lines = text.components(separatedBy: "\n")
        if lines.count > maxLines + 200 { // Only truncate when well over limit to reduce I/O
            let kept = lines.suffix(maxLines).joined(separator: "\n")
            try? kept.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// Shared formatter to avoid creating one per log call
private extension ISO8601DateFormatter {
    static let shared: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
