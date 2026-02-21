import SwiftUI

/// A single project card in the grid
struct ProjectCardView: View {
    @EnvironmentObject var appState: AppState
    let share: SMBShareConfig
    let status: MountStatus

    @State private var isHovered = false

    private var warmStatus: WarmStatus {
        appState.warmStatuses[share.id] ?? .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: name + status dot
            HStack {
                Text(share.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                StatusDotView(status: status)
            }

            // Server info
            Text(share.host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Sync mode badge
            HStack(spacing: 6) {
                if share.syncMode == .keepLocal {
                    Label("Local", systemImage: "internaldrive")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MirageStyle.accent.opacity(0.12))
                        .foregroundStyle(MirageStyle.accent)
                        .clipShape(Capsule())
                } else {
                    Label("Stream", systemImage: "cloud")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                Spacer()
            }

            // Download progress / status
            downloadStatusView

            // Quick actions
            HStack(spacing: 8) {
                Button {
                    Task {
                        if status == .mounted {
                            await appState.unmount(shareId: share.id)
                        } else if status == .disconnected || isErrorStatus {
                            await appState.mount(shareId: share.id)
                        }
                    }
                } label: {
                    Label(
                        status == .mounted ? Term.disconnect : Term.connect,
                        systemImage: status == .mounted ? "stop.circle" : "play.circle"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(status == .mounting || status == .unmounting)

                if status == .mounted {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: share.mountPoint))
                    } label: {
                        Label(Term.openInFinder, systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()
            }
        }
        .padding(MirageStyle.cardPadding)
        .background(
            RoundedRectangle(cornerRadius: MirageStyle.cardCornerRadius)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MirageStyle.cardCornerRadius)
                .strokeBorder(
                    status == .mounted ? MirageStyle.connected.opacity(0.3) : Color.clear,
                    lineWidth: 1
                )
        )
        .shadow(
            color: .black.opacity(0.08),
            radius: MirageStyle.cardShadowRadius,
            y: MirageStyle.cardShadowY
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var downloadStatusView: some View {
        switch warmStatus {
        case .warming(let done, let total) where total > 0:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(total))
                    .controlSize(.small)
                Text("Downloading \(done) of \(total) files...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .upToDate(let count, let size):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
                Text("\(count) files (\(size.formattedByteCount)) on this Mac")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .partial(let cached, let total, let size):
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                    Text("\(cached) of \(total) files (\(size.formattedByteCount))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text("Not enough storage for remaining files")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        case .error(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption2)
                Text(msg)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        default:
            // Idle or warming with 0 total — show cached size if any
            let files = appState.cacheManager.cachedFiles[share.id] ?? []
            let totalSize = files.reduce(UInt64(0)) { $0 + $1.size }
            if totalSize > 0 {
                Text("\(totalSize.formattedByteCount) cached")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("No local files")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var isErrorStatus: Bool {
        if case .error = status { return true }
        return false
    }
}
