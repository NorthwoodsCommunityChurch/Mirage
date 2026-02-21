import Foundation

extension FileManager {
    /// Calculates the total allocated size of a directory and its contents recursively.
    func allocatedSizeOfDirectory(at url: URL) throws -> UInt64 {
        let enumerator = self.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        )

        var totalSize: UInt64 = 0

        while let fileURL = enumerator?.nextObject() as? URL {
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .isRegularFileKey
            ])
            guard resourceValues.isRegularFile == true else { continue }
            totalSize += UInt64(resourceValues.totalFileAllocatedSize ?? 0)
        }

        return totalSize
    }
}
