import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Mirage")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Project list
            if appState.shares.isEmpty {
                VStack(spacing: 8) {
                    Text("No projects set up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(Term.addProject) {
                        openMainWindow()
                        appState.dropInfo = nil
                        appState.showAddShare = true
                    }
                    .buttonStyle(.borderless)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                VStack(spacing: 0) {
                    ForEach(appState.shares) { share in
                        MenuBarProjectRow(
                            share: share,
                            status: appState.mountStatuses[share.id] ?? .disconnected
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            // Storage
            StorageMiniView()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            // Actions
            HStack(spacing: 0) {
                Button(Term.connectAll) {
                    Task { await appState.mountAll() }
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 20)

                Button(Term.disconnectAll) {
                    Task { await appState.unmountAll() }
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)

            Divider()

            HStack(spacing: 0) {
                Button("Open Mirage") {
                    openMainWindow()
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 20)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
        }
        .frame(width: 280)
    }

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }
}

struct MenuBarProjectRow: View {
    @EnvironmentObject var appState: AppState

    let share: SMBShareConfig
    let status: MountStatus

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(MirageStyle.statusColor(for: status))
                .frame(width: 8, height: 8)

            Text(share.displayName)
                .lineLimit(1)

            if share.syncMode == .keepLocal {
                Image(systemName: "internaldrive")
                    .font(.caption2)
                    .foregroundStyle(MirageStyle.accent)
            }

            Spacer()

            Text(Term.status(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task {
                    if status == .mounted || status == .indexing {
                        await appState.unmount(shareId: share.id)
                    } else if status == .disconnected {
                        await appState.mount(shareId: share.id)
                    }
                }
            } label: {
                Image(systemName: (status == .mounted || status == .indexing) ? "eject" : "play.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(status != .mounted && status != .indexing && status != .disconnected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct StorageMiniView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(Term.localStorage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(appState.cacheManager.totalCacheSize.formattedByteCount) / \(globalMax)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * percent))
                }
            }
            .frame(height: 4)
        }
    }

    private var percent: CGFloat {
        CGFloat(appState.cacheManager.usagePercent)
    }

    private var barColor: Color {
        percent > 0.9 ? .red : percent > 0.7 ? .orange : MirageStyle.accent
    }

    private var globalMax: String {
        (UInt64(appState.globalMaxCacheGB) * 1_073_741_824).formattedByteCount
    }
}
