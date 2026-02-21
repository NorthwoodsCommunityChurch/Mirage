import SwiftUI

/// Per-project mini storage bar
struct ProjectStorageBar: View {
    @EnvironmentObject var appState: AppState
    let shareId: UUID

    private var files: [CachedFile] {
        appState.cacheManager.cachedFiles[shareId] ?? []
    }

    private var totalSize: UInt64 {
        files.reduce(UInt64(0)) { $0 + $1.size }
    }

    private var maxCache: UInt64 {
        appState.cacheManager.maxCacheSize
    }

    private var isOverLimit: Bool {
        totalSize > maxCache
    }

    private var percent: CGFloat {
        guard maxCache > 0 else { return 0 }
        return min(1.0, CGFloat(totalSize) / CGFloat(maxCache))
    }

    var body: some View {
        if totalSize > 0 {
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(barColor.opacity(0.6))
                            .frame(width: max(2, geo.size.width * percent))
                    }
                }
                .frame(height: 4)

                Text(totalSize.formattedByteCount)
                    .font(.caption2)
                    .foregroundStyle(isOverLimit ? .red : .secondary)
                    .monospacedDigit()

                if isOverLimit {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("This folder uses more space than your storage limit.")
                }
            }
        } else {
            Text("No local files")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var barColor: Color {
        isOverLimit ? .red : MirageStyle.accent
    }
}
