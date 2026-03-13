import Foundation
import Combine

@MainActor
final class StatusMonitor: ObservableObject {
    @Published var mountStatuses: [UUID: MountStatus] = [:]

    private var timer: Timer?
    private let pollInterval: TimeInterval = 10

    private weak var processManager: RcloneProcessManager?
    private weak var cacheManager: CacheManager?
    private var shareIds: [UUID] = []

    func start(
        processManager: RcloneProcessManager,
        cacheManager: CacheManager,
        shareIds: [UUID]
    ) {
        self.processManager = processManager
        self.cacheManager = cacheManager
        self.shareIds = shareIds

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.poll()
            }
        }
        // No immediate poll — initialSetup() already ran refreshCache() before starting the monitor.
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateShareIds(_ ids: [UUID]) {
        self.shareIds = ids
    }

    private func poll() async {
        guard let processManager, let cacheManager else { return }

        var newStatuses: [UUID: MountStatus] = [:]

        for shareId in shareIds {
            if processManager.isRunning(shareId: shareId) {
                // Preserve .indexing state — it will be cleared by AppState when indexing finishes
                let current = mountStatuses[shareId]
                if current == .indexing {
                    newStatuses[shareId] = .indexing
                } else {
                    newStatuses[shareId] = .mounted
                }
            } else if let error = processManager.lastError(shareId: shareId) {
                newStatuses[shareId] = .error(error)
            } else {
                // Preserve mounting/unmounting status if set, otherwise disconnected
                let current = mountStatuses[shareId]
                switch current {
                case .mounting, .unmounting:
                    newStatuses[shareId] = current ?? .disconnected
                default:
                    newStatuses[shareId] = .disconnected
                }
            }
        }

        mountStatuses = newStatuses

        // Refresh cache stats
        await cacheManager.refreshCache(shareIds: shareIds)
    }
}
