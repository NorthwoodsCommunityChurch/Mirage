import Foundation

@MainActor
final class ShareStore: ObservableObject {
    @Published var shares: [SMBShareConfig] = []

    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("MountCache", isDirectory: true)
        self.fileURL = appDir.appendingPathComponent("shares.json")

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            shares = try decoder.decode([SMBShareConfig].self, from: data)
        } catch {
            print("Failed to load shares: \(error)")
        }
    }

    func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(shares)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save shares: \(error)")
        }
    }

    func add(_ share: SMBShareConfig) {
        shares.append(share)
        save()
    }

    func update(_ share: SMBShareConfig) {
        guard let index = shares.firstIndex(where: { $0.id == share.id }) else { return }
        shares[index] = share
        save()
    }

    func remove(id: UUID) {
        guard let share = shares.first(where: { $0.id == id }) else { return }
        // Clean up Keychain password
        try? KeychainHelper.deletePassword(for: share.rcloneRemoteName)
        shares.removeAll { $0.id == id }
        save()
    }

    func share(for id: UUID) -> SMBShareConfig? {
        shares.first { $0.id == id }
    }

    // MARK: - Password helpers

    func storePassword(_ password: String, for share: SMBShareConfig) throws {
        try KeychainHelper.storePassword(password, for: share.rcloneRemoteName)
    }

    func retrievePassword(for share: SMBShareConfig) -> String? {
        try? KeychainHelper.retrievePassword(for: share.rcloneRemoteName)
    }
}
