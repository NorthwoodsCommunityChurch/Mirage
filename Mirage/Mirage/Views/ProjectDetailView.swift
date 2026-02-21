import SwiftUI

/// Detail sheet for a single project — progressive disclosure pattern
struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let share: SMBShareConfig
    let status: MountStatus

    @State private var editedCacheMode: VFSCacheMode
    @State private var editedAutoMount: Bool
    @State private var editedCacheMaxAgeHours: Double
    @State private var editedWriteBackSeconds: Double
    @State private var editedSyncMode: ProjectSyncMode
    @State private var showAdvanced = false
    @State private var showRemoveConfirmation = false
    @State private var isMovingCache = false
    @State private var moveError: String?

    init(share: SMBShareConfig, status: MountStatus) {
        self.share = share
        self.status = status
        _editedCacheMode = State(initialValue: share.cacheMode)
        _editedAutoMount = State(initialValue: share.autoMount)
        _editedCacheMaxAgeHours = State(initialValue: share.cacheMaxAge / 3600)
        _editedWriteBackSeconds = State(initialValue: share.writeBack)
        _editedSyncMode = State(initialValue: share.syncMode)
    }

    private var warmStatus: WarmStatus {
        appState.warmStatuses[share.id] ?? .idle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MirageStyle.sectionSpacing) {
                heroSection
                Divider()
                syncModeSection
                Divider()
                localFilesSection
                Divider()
                storageSection
                advancedSection
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            actionsBar
        }
        .frame(width: 520, height: 480)
        .onChange(of: editedCacheMode) { _, newValue in saveSettings(cacheMode: newValue) }
        .onChange(of: editedAutoMount) { _, newValue in saveSettings(autoMount: newValue) }
        .onChange(of: editedCacheMaxAgeHours) { _, newValue in saveSettings(cacheMaxAgeHours: newValue) }
        .onChange(of: editedWriteBackSeconds) { _, newValue in saveSettings(writeBackSeconds: newValue) }
        .confirmationDialog(Term.removeProject, isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                Task {
                    await appState.removeShare(id: share.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove \"\(share.displayName)\"? This will disconnect and delete all local files.")
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                StatusDotView(status: status, size: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(share.displayName)
                        .font(.title)
                        .fontWeight(.bold)

                    Text("\(share.host) / \(share.shareName)\(share.subfolder.isEmpty ? "" : "/\(share.subfolder)")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // Status pill
            Text(Term.status(for: status))
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(MirageStyle.statusColor(for: status).opacity(0.15))
                .foregroundStyle(MirageStyle.statusColor(for: status))
                .clipShape(Capsule())

            if case .error(let msg) = status {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Sync Mode Toggle

    private var syncModeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SyncModePicker(selection: Binding(
                get: { editedSyncMode == .keepLocal },
                set: { newValue in
                    editedSyncMode = newValue ? .keepLocal : .stream
                    Task {
                        if newValue {
                            await appState.enableKeepLocal(shareId: share.id)
                        } else {
                            appState.disableKeepLocal(shareId: share.id)
                        }
                    }
                }
            ))

            // Warm progress (only when Keep Local)
            if editedSyncMode == .keepLocal {
                switch warmStatus {
                case .scanning:
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning files...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .warming(let done, let total, let bytesDown, let bytesTotal):
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: bytesTotal > 0 ? Double(bytesDown) : Double(done),
                                     total: bytesTotal > 0 ? Double(bytesTotal) : max(1, Double(total)))
                            .controlSize(.small)
                        HStack {
                            Text("Downloading \(done) of \(total) files")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Spacer()
                            if bytesTotal > 0 {
                                Text("\(bytesDown.formattedByteCount) of \(bytesTotal.formattedByteCount)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                case .upToDate(let count, let size):
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text("\(count) files (\(size.formattedByteCount)) up to date")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .partial(let cached, let total, let size):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                            Text("\(cached) of \(total) files (\(size.formattedByteCount))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("Not enough storage for remaining files. Increase the cache limit in Settings or free up space.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                case .error(let msg):
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Local Files

    private var localFilesSection: some View {
        let offlinePaths = Array(appState.cacheManager.offlinePathsFor(shareId: share.id)).sorted()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("On This Mac")
                    .font(.headline)

                Spacer()

                if share.syncMode != .keepLocal {
                    Button("Keep Files Local...") {
                        addOfflineItems(directories: false)
                    }
                    .controlSize(.small)
                    .disabled(status != .mounted)

                    Button("Keep Folder Local...") {
                        addOfflineItems(directories: true)
                    }
                    .controlSize(.small)
                    .disabled(status != .mounted)
                }
            }

            if share.syncMode == .keepLocal {
                Text("All files are kept on this Mac automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("These files stay on your Mac even when you're offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if offlinePaths.isEmpty && share.syncMode != .keepLocal {
                Text("No files kept locally yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else if !offlinePaths.isEmpty && share.syncMode != .keepLocal {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(offlinePaths, id: \.self) { path in
                            HStack {
                                Image(systemName: path.hasSuffix("/") ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)

                                Text(path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Button {
                                    appState.unmarkOffline(shareId: share.id, relativePath: path)
                                } label: {
                                    Image(systemName: "cloud.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Switch to streaming")
                            }
                            .padding(.vertical, 3)

                            if path != offlinePaths.last {
                                Divider()
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 120)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func addOfflineItems(directories: Bool) {
        let mountURL = URL(fileURLWithPath: share.mountPoint)
        let delegate = MountPointPanelDelegate(mountPointURL: mountURL)

        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = true
        panel.directoryURL = mountURL
        panel.delegate = delegate
        panel.message = directories
            ? "Select folders to keep on this Mac"
            : "Select files to keep on this Mac"

        guard panel.runModal() == .OK else { return }

        let mountPrefix = share.mountPoint.hasSuffix("/") ? share.mountPoint : share.mountPoint + "/"

        for url in panel.urls {
            let fullPath = url.path
            guard fullPath.hasPrefix(mountPrefix) else { continue }

            var relativePath = String(fullPath.dropFirst(mountPrefix.count))
            if directories && !relativePath.hasSuffix("/") {
                relativePath += "/"
            }

            appState.markOffline(shareId: share.id, relativePath: relativePath)
        }
    }

    // MARK: - Cache Location

    private func changeCacheLocation() {
        if share.customCachePath != nil {
            // Currently on a custom path — offer revert or new location
            let alert = NSAlert()
            alert.messageText = "Change Cache Location"
            alert.informativeText = "Currently stored at: \(share.customCachePath!)"
            alert.addButton(withTitle: "Choose New Location...")
            alert.addButton(withTitle: "Use Default (Local Disk)")
            alert.addButton(withTitle: "Cancel")

            let response = alert.runModal()
            switch response {
            case .alertFirstButtonReturn:
                pickNewCacheLocation()
            case .alertSecondButtonReturn:
                moveToPath(nil)
            default:
                break
            }
        } else {
            pickNewCacheLocation()
        }
    }

    private func pickNewCacheLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.message = "Choose where to store cached files for this project"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        moveToPath(url.path)
    }

    private func moveToPath(_ newPath: String?) {
        isMovingCache = true
        moveError = nil

        Task {
            do {
                try await appState.changeCacheLocation(shareId: share.id, newPath: newPath)
            } catch {
                moveError = error.localizedDescription
            }
            isMovingCache = false
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Term.localStorage)
                .font(.headline)

            ProjectStorageBar(shareId: share.id)

            // Cache location
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cache Location")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(share.customCachePath ?? "Default (local disk)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if isMovingCache {
                    ProgressView()
                        .controlSize(.small)
                    Text("Moving files...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Change...") {
                        changeCacheLocation()
                    }
                    .controlSize(.small)
                    .disabled(status == .mounted || status == .mounting || status == .unmounting)
                }
            }

            if let moveError {
                Text(moveError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            let cachedFiles = appState.cacheManager.cachedFiles[share.id] ?? []
            let totalSize = cachedFiles.reduce(UInt64(0)) { $0 + $1.size }
            let offlineSize = cachedFiles.filter(\.isOffline).reduce(UInt64(0)) { $0 + $1.size }

            if totalSize > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloaded: \(totalSize.formattedByteCount)")
                            .font(.caption)
                        if offlineSize > 0 {
                            Text("Kept local: \(offlineSize.formattedByteCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(Term.freeUpSpace) {
                        appState.clearCache(for: share.id)
                    }
                    .controlSize(.small)
                    .disabled(status == .mounted)
                }
            }
        }
    }

    // MARK: - Advanced (progressive disclosure)

    private var advancedSection: some View {
        DisclosureGroup("Show Advanced", isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                // Sync mode picker
                Picker("Sync Mode", selection: $editedCacheMode) {
                    ForEach(VFSCacheMode.allCases) { mode in
                        Text(Term.syncModeName(for: mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(editedSyncMode == .keepLocal) // Locked to .full when Keep Local

                Text(Term.syncModeDescription(for: editedCacheMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Keep files for
                HStack {
                    Text(Term.keepFilesFor)
                    Spacer()
                    Slider(value: $editedCacheMaxAgeHours, in: 1...168, step: 1)
                        .frame(width: 180)
                    Text("\(Int(editedCacheMaxAgeHours))h")
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }

                // Save delay
                HStack {
                    Text(Term.saveDelay)
                    Spacer()
                    Slider(value: $editedWriteBackSeconds, in: 0...60, step: 5)
                        .frame(width: 180)
                    Text("\(Int(editedWriteBackSeconds))s")
                        .frame(width: 40, alignment: .trailing)
                        .monospacedDigit()
                }

                Toggle(Term.autoConnect, isOn: $editedAutoMount)

                // Connection details
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Server:").foregroundStyle(.secondary).font(.caption)
                        Text(share.host).font(.caption)
                    }
                    GridRow {
                        Text("Folder:").foregroundStyle(.secondary).font(.caption)
                        Text(share.shareName + (share.subfolder.isEmpty ? "" : "/\(share.subfolder)")).font(.caption)
                    }
                    GridRow {
                        Text("User:").foregroundStyle(.secondary).font(.caption)
                        Text(share.username).font(.caption)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        HStack(spacing: 12) {
            if status == .mounted {
                Button(Term.disconnect) {
                    Task { await appState.unmount(shareId: share.id) }
                }
                .buttonStyle(.bordered)

                Button(Term.openInFinder) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: share.mountPoint))
                }
                .buttonStyle(.borderedProminent)
                .tint(MirageStyle.accent)
            } else if status == .mounting || status == .unmounting {
                ProgressView().controlSize(.small)
                Text(Term.status(for: status))
            } else {
                Button(Term.connect) {
                    Task { await appState.mount(shareId: share.id) }
                }
                .buttonStyle(.borderedProminent)
                .tint(MirageStyle.accent)
            }

            Spacer()

            Button(Term.removeProject, role: .destructive) {
                showRemoveConfirmation = true
            }
            .buttonStyle(.bordered)
            .tint(.red)

            Button("Close") {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .background(.bar)
    }

    // MARK: - Save helpers

    private func saveSettings(
        cacheMode: VFSCacheMode? = nil,
        autoMount: Bool? = nil,
        cacheMaxAgeHours: Double? = nil,
        writeBackSeconds: Double? = nil
    ) {
        var updated = share
        if let cacheMode { updated.cacheMode = cacheMode }
        if let autoMount { updated.autoMount = autoMount }
        if let hours = cacheMaxAgeHours { updated.cacheMaxAge = hours * 3600 }
        if let seconds = writeBackSeconds { updated.writeBack = seconds }
        appState.updateShare(updated)
    }
}

// MARK: - NSOpenPanel delegate to restrict browsing to the mount point

private class MountPointPanelDelegate: NSObject, NSOpenSavePanelDelegate {
    let mountPointURL: URL

    init(mountPointURL: URL) {
        self.mountPointURL = mountPointURL
        super.init()
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        url.path.hasPrefix(mountPointURL.path)
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard url.path.hasPrefix(mountPointURL.path) else {
            throw NSError(
                domain: "Mirage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Please select items from the connected project."]
            )
        }
    }
}
