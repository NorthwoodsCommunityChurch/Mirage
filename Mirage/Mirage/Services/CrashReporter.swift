import Foundation
import AppKit

/// Installs signal/exception handlers to capture crash info, and on next launch
/// offers to open a pre-filled GitHub issue with diagnostics.
final class CrashReporter {
    static let shared = CrashReporter()

    private static let crashFileURL: URL = {
        let appSupport = FileManager.default.safeURL(for: .applicationSupportDirectory)
        return appSupport
            .appendingPathComponent("MountCache")
            .appendingPathComponent("crash-report.json")
    }()

    private init() {}

    // MARK: - Install handlers (call early in AppDelegate)

    func install() {
        AppLogger.shared.log("CrashReporter: installing signal and exception handlers")

        // Signal handlers
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            signal(sig, crashSignalHandler)
        }

        // ObjC uncaught exception handler
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.writeExceptionReport(exception)
            // Re-raise so the process actually terminates
            NSSetUncaughtExceptionHandler(nil)
        }
    }

    // MARK: - Check for pending crash report (call on next launch)

    var hasPendingReport: Bool {
        FileManager.default.fileExists(atPath: Self.crashFileURL.path)
    }

    /// Show the crash report prompt. Call from the main thread after app window appears.
    func promptIfNeeded() {
        guard hasPendingReport else { return }

        var token = UserDefaults.standard.string(forKey: "crashReportKey") ?? ""

        let alert = NSAlert()
        alert.messageText = "Mirage crashed unexpectedly"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Send Report")
        alert.addButton(withTitle: "Don't Send")

        if token.isEmpty {
            alert.informativeText = "Would you like to send a crash report? Enter the report key from your admin to send directly."

            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "Paste report key here"
            alert.accessoryView = field
        } else {
            alert.informativeText = "Would you like to send a crash report? This sends diagnostic information directly to the developers."
        }

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // If they entered a key in the field, save it
            if let field = alert.accessoryView as? NSSecureTextField {
                let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !entered.isEmpty {
                    token = entered
                    UserDefaults.standard.set(entered, forKey: "crashReportKey")
                }
            }
            submitCrashReport(token: token)
        }

        // Clean up crash file either way
        try? FileManager.default.removeItem(at: Self.crashFileURL)
    }

    // MARK: - Submit crash report

    private static let repoAPI = "https://api.github.com/repos/NorthwoodsCommunityChurch/Mirage/issues"

    private func submitCrashReport(token: String) {
        let body = buildIssueBody()

        if token.isEmpty {
            // No report key — clipboard + browser fallback
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)

            var components = URLComponents(string: "https://github.com/NorthwoodsCommunityChurch/Mirage/issues/new")!
            components.queryItems = [
                URLQueryItem(name: "title", value: "Crash Report"),
                URLQueryItem(name: "labels", value: "bug,crash"),
            ]
            if let url = components.url {
                NSWorkspace.shared.open(url)
            }

            let info = NSAlert()
            info.messageText = "Report copied to clipboard"
            info.informativeText = "Paste the report into the GitHub issue that just opened."
            info.alertStyle = .informational
            info.addButton(withTitle: "OK")
            info.runModal()
            return
        }

        // Has report key — submit directly via GitHub API
        let url = URL(string: Self.repoAPI)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let payload: [String: Any] = [
            "title": "Crash Report",
            "body": body,
            "labels": ["bug", "crash"],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        request.httpBody = jsonData

        // Send synchronously on a background queue to avoid main thread deadlock.
        // DispatchSemaphore.wait() on the main thread can block URLSession callbacks.
        var success = false
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let config = URLSessionConfiguration.default
            let session = URLSession(configuration: config, delegate: RedirectFollower(), delegateQueue: nil)
            let sem = DispatchSemaphore(value: 0)
            session.dataTask(with: request) { _, response, _ in
                if let httpResponse = response as? HTTPURLResponse,
                   (200...201).contains(httpResponse.statusCode) {
                    success = true
                }
                sem.signal()
            }.resume()
            sem.wait()
            group.leave()
        }
        group.wait()

        let resultAlert = NSAlert()
        if success {
            resultAlert.messageText = "Report sent"
            resultAlert.informativeText = "Thank you! The crash report has been submitted."
            resultAlert.alertStyle = .informational
        } else {
            resultAlert.messageText = "Report failed to send"
            resultAlert.informativeText = "The crash report couldn't be submitted. The report has been copied to your clipboard if you'd like to submit it manually."
            resultAlert.alertStyle = .warning
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(body, forType: .string)
        }
        resultAlert.addButton(withTitle: "OK")
        resultAlert.runModal()
    }

    private func buildIssueBody() -> String {
        var sections: [String] = []

        // 1. Crash report
        if let data = try? Data(contentsOf: Self.crashFileURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            let signal = json["signal"] as? String ?? "Unknown"
            let time = json["timestamp"] as? String ?? "Unknown"
            let appVersion = json["appVersion"] as? String ?? "Unknown"
            let buildNumber = json["buildNumber"] as? String ?? "?"
            let stackTrace = json["stackTrace"] as? String ?? "Not available"
            let exceptionInfo = json["exception"] as? String

            sections.append("""
            ## Crash Report
            - **Signal:** \(signal)
            - **Time:** \(time)
            - **App Version:** \(appVersion) (build \(buildNumber))
            \(exceptionInfo.map { "- **Exception:** \($0)" } ?? "")

            ## Stack Trace
            ```
            \(stackTrace)
            ```
            """)
        } else {
            sections.append("## Crash Report\nCrash file could not be read.")
        }

        // 2. System info
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = getMacModel()
        let chip = getChipName()
        let ram = ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)
        let diskSpace = getAvailableDiskSpace()

        sections.append("""
        ## System Info
        - **macOS:** \(osVersion)
        - **Mac Model:** \(model)
        - **Chip:** \(chip)
        - **RAM:** \(ram) GB
        - **Disk Space Available:** \(diskSpace)
        """)

        // 3. Activity log
        let activityLog = AppLogger.shared.lastLines(100)
        if !activityLog.isEmpty {
            sections.append("""
            ## Activity Log (last 100 lines)
            ```
            \(activityLog)
            ```
            """)
        }

        // 4. rclone logs
        let rcloneLogs = collectRcloneLogs()
        if !rcloneLogs.isEmpty {
            sections.append("""
            ## rclone Logs (last 50 lines per share)
            ```
            \(rcloneLogs)
            ```
            """)
        }

        // 5. App state
        let appStateInfo = collectAppState()
        if !appStateInfo.isEmpty {
            sections.append("""
            ## App State
            \(appStateInfo)
            """)
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - System info helpers

    private func getMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func getChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var brand = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
        return String(cString: brand)
    }

    private func getAvailableDiskSpace() -> String {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        if let free = attrs?[.systemFreeSize] as? Int64 {
            return "\(free / (1024 * 1024 * 1024)) GB"
        }
        return "Unknown"
    }

    private func collectRcloneLogs() -> String {
        let logDir = FileManager.default.safeURL(for: .libraryDirectory)
            .appendingPathComponent("Logs/MountCache")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: nil
        ) else { return "" }

        var output: [String] = []
        for file in files where file.pathExtension == "log" && file.lastPathComponent != "mirage-activity.log" {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            let tail = lines.suffix(50)
            if !tail.isEmpty {
                output.append("--- \(file.lastPathComponent) ---")
                output.append(contentsOf: tail)
            }
        }
        return output.joined(separator: "\n")
    }

    private func collectAppState() -> String {
        var info: [String] = []

        // Read shares.json
        let appSupport = FileManager.default.safeURL(for: .applicationSupportDirectory)
        let sharesFile = appSupport.appendingPathComponent("MountCache/shares.json")
        if let data = try? Data(contentsOf: sharesFile),
           let shares = try? JSONDecoder().decode([ShareSummary].self, from: data) {
            info.append("- **Shares configured:** \(shares.count)")
            let mountedCount = shares.filter { $0.autoMount }.count
            info.append("- **Auto-mount enabled:** \(mountedCount)")
        }

        // rclone version
        let rclonePath = UserDefaults.standard.string(forKey: "rclonePath") ?? "/usr/local/bin/rclone"
        if FileManager.default.fileExists(atPath: rclonePath) {
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: rclonePath)
            process.arguments = ["version"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) {
                let firstLine = output.components(separatedBy: "\n").first ?? ""
                info.append("- **rclone:** \(firstLine)")
            }
        }

        return info.joined(separator: "\n")
    }

    // MARK: - Write crash file (called from signal/exception handler)

    /// Write crash info from a signal handler. Uses only signal-safe operations where possible.
    fileprivate static func writeSignalReport(signal: Int32) {
        let signalName: String
        switch signal {
        case SIGSEGV: signalName = "SIGSEGV"
        case SIGABRT: signalName = "SIGABRT"
        case SIGBUS:  signalName = "SIGBUS"
        case SIGFPE:  signalName = "SIGFPE"
        case SIGILL:  signalName = "SIGILL"
        case SIGTRAP: signalName = "SIGTRAP"
        default:      signalName = "Signal \(signal)"
        }

        // Thread.callStackSymbols is not signal-safe, but it's the best we can do
        // without a dedicated crash reporting library. In practice it usually works.
        let stack = Thread.callStackSymbols.joined(separator: "\n")

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let json: [String: Any] = [
            "signal": signalName,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "appVersion": version,
            "buildNumber": build,
            "stackTrace": stack,
        ]

        writeCrashJSON(json)

        // Reset handler and re-raise so the default handler fires
        Darwin.signal(signal, SIG_DFL)
        Darwin.raise(signal)
    }

    fileprivate static func writeExceptionReport(_ exception: NSException) {
        let stack = exception.callStackSymbols.joined(separator: "\n")
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let json: [String: Any] = [
            "signal": "NSException",
            "exception": "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "appVersion": version,
            "buildNumber": build,
            "stackTrace": stack,
        ]

        writeCrashJSON(json)
    }

    private static func writeCrashJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else { return }

        // Ensure directory exists
        let dir = crashFileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Write using POSIX for maximum safety
        let path = crashFileURL.path
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { buf in
            if let ptr = buf.baseAddress {
                _ = Darwin.write(fd, ptr, buf.count)
            }
        }
        close(fd)
    }
}

// Minimal struct just for decoding share count in crash reports
private struct ShareSummary: Decodable {
    let autoMount: Bool
}

// MARK: - URLSession redirect follower

/// URLSession doesn't follow redirects for POST by default.
/// GitHub returns 307 for org repo renames — we need to follow them.
private class RedirectFollower: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Follow the redirect, preserving the original method and body
        var redirected = request
        redirected.httpMethod = task.originalRequest?.httpMethod
        redirected.httpBody = task.originalRequest?.httpBody
        // Preserve auth header
        if let auth = task.originalRequest?.value(forHTTPHeaderField: "Authorization") {
            redirected.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        if let contentType = task.originalRequest?.value(forHTTPHeaderField: "Content-Type") {
            redirected.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        completionHandler(redirected)
    }
}

// MARK: - C signal handler (must be a top-level function)

private func crashSignalHandler(signal: Int32) {
    CrashReporter.writeSignalReport(signal: signal)
}
