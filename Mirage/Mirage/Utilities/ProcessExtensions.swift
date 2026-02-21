import Foundation

extension Process {
    /// Runs a process asynchronously and returns the output and exit status.
    @discardableResult
    static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) async throws -> (output: String, error: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outputData, encoding: .utf8) ?? ""
                let error = String(data: errorData, encoding: .utf8) ?? ""
                continuation.resume(returning: (output, error, proc.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
