import Foundation

@MainActor
final class RcloneInstaller: ObservableObject {
    enum InstallState: Equatable {
        case idle
        case downloading
        case installing
        case done(version: String)
        case failed(String)
    }

    @Published var state: InstallState = .idle
    @Published var latestVersion: String?
    @Published var installedVersion: String?
    @Published var updateAvailable = false

    private let installDir = "/usr/local/bin"
    private let binaryName = "rclone"

    var installPath: String { "\(installDir)/\(binaryName)" }

    /// Checks what the latest rclone release is via the GitHub API.
    func checkLatestVersion() async {
        do {
            let url = URL(string: "https://api.github.com/repos/rclone/rclone/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String {
                latestVersion = tagName // e.g., "v1.68.2"
            }
        } catch {
            // Non-fatal — we just won't show update info
        }
    }

    /// Checks the installed rclone version and compares with latest.
    func checkForUpdate(rclonePath: String) async {
        // Get installed version
        do {
            let result = try await Process.run(
                executableURL: URL(fileURLWithPath: rclonePath),
                arguments: ["version"]
            )
            if result.exitCode == 0 {
                // First line is like "rclone v1.68.2"
                let firstLine = result.output.components(separatedBy: "\n").first ?? ""
                if let versionPart = firstLine.split(separator: " ").last {
                    installedVersion = String(versionPart)
                }
            }
        } catch {
            installedVersion = nil
        }

        // Get latest version
        await checkLatestVersion()

        // Compare
        if let installed = installedVersion, let latest = latestVersion {
            updateAvailable = installed != latest
        }
    }

    /// Downloads and installs the latest rclone binary for macOS ARM64.
    func downloadAndInstall() async {
        state = .downloading

        do {
            // Determine architecture
            var sysinfo = utsname()
            uname(&sysinfo)
            let machine = withUnsafePointer(to: &sysinfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                    String(cString: $0)
                }
            }
            let arch = machine.contains("arm64") ? "arm64" : "amd64"

            // Get the latest version tag
            await checkLatestVersion()
            // Validate format (e.g. "v1.68.2") before embedding in shell paths.
            // The version string ends up inside an osascript-invoked shell command,
            // so rejecting unexpected characters prevents injection if the GitHub
            // API response were ever tampered with.
            guard let version = latestVersion,
                  version.range(of: #"^v\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else {
                state = .failed("Could not determine latest rclone version.")
                return
            }

            // Download URL: https://downloads.rclone.org/v1.68.2/rclone-v1.68.2-osx-arm64.zip
            let filename = "rclone-\(version)-osx-\(arch)"
            let downloadURL = URL(string: "https://downloads.rclone.org/\(version)/\(filename).zip")!

            // Download to a temp location
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mountcache-rclone-install-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let zipPath = tempDir.appendingPathComponent("\(filename).zip")

            let (downloadedURL, response) = try await URLSession.shared.download(for: URLRequest(url: downloadURL))

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                state = .failed("Download failed with HTTP \(httpResponse.statusCode)")
                return
            }

            // Move downloaded file to our temp dir
            try FileManager.default.moveItem(at: downloadedURL, to: zipPath)

            state = .installing

            // Unzip
            let unzipResult = try await Process.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-xk", zipPath.path, tempDir.path]
            )
            if unzipResult.exitCode != 0 {
                state = .failed("Failed to unzip: \(unzipResult.error)")
                return
            }

            // The extracted binary is at <tempDir>/<filename>/rclone
            let extractedBinary = tempDir
                .appendingPathComponent(filename)
                .appendingPathComponent("rclone")

            guard FileManager.default.fileExists(atPath: extractedBinary.path) else {
                state = .failed("rclone binary not found in downloaded archive.")
                return
            }

            // Ensure /usr/local/bin exists
            if !FileManager.default.fileExists(atPath: installDir) {
                let mkdirResult = try await Process.run(
                    executableURL: URL(fileURLWithPath: "/bin/mkdir"),
                    arguments: ["-p", installDir]
                )
                if mkdirResult.exitCode != 0 {
                    // May need sudo — try via AppleScript (POSIX-quoted for safety)
                    let escapedDir = installDir.replacingOccurrences(of: "'", with: "'\\''")
                    try await runPrivileged("mkdir -p '\(escapedDir)'")
                }
            }

            // Copy binary to /usr/local/bin/rclone
            // Try direct copy first, fall back to privileged if permission denied
            let destPath = "\(installDir)/\(binaryName)"
            do {
                if FileManager.default.fileExists(atPath: destPath) {
                    try FileManager.default.removeItem(atPath: destPath)
                }
                try FileManager.default.copyItem(at: extractedBinary, to: URL(fileURLWithPath: destPath))
            } catch {
                // Permission denied — use privileged helper (POSIX-quoted for safety)
                let escapedSrc = extractedBinary.path.replacingOccurrences(of: "'", with: "'\\''")
                let escapedDst = destPath.replacingOccurrences(of: "'", with: "'\\''")
                try await runPrivileged("cp '\(escapedSrc)' '\(escapedDst)'")
            }

            // Make executable
            _ = try await Process.run(
                executableURL: URL(fileURLWithPath: "/bin/chmod"),
                arguments: ["+x", destPath]
            )

            // Remove quarantine attribute
            _ = try? await Process.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/xattr"),
                arguments: ["-d", "com.apple.quarantine", destPath]
            )

            // Clean up temp
            try? FileManager.default.removeItem(at: tempDir)

            // Verify
            let verifyResult = try await Process.run(
                executableURL: URL(fileURLWithPath: destPath),
                arguments: ["version"]
            )

            if verifyResult.exitCode == 0 {
                let firstLine = verifyResult.output.components(separatedBy: "\n").first ?? ""
                state = .done(version: firstLine)
                installedVersion = latestVersion
                updateAvailable = false
            } else {
                state = .failed("Installed but verification failed: \(verifyResult.error)")
            }

        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Runs a command with elevated privileges via AppleScript authorization prompt.
    private func runPrivileged(_ command: String) async throws {
        let script = "do shell script \"\(command)\" with administrator privileges"
        let result = try await Process.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", script]
        )
        if result.exitCode != 0 {
            throw NSError(domain: "RcloneInstaller", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: result.error])
        }
    }
}
