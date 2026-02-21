import SwiftUI

/// Global storage usage bar shown at bottom of the hub
struct StorageOverviewBar: View {
    @EnvironmentObject var appState: AppState

    private var used: UInt64 { appState.cacheManager.totalCacheSize }
    private var limit: UInt64 { appState.cacheManager.maxCacheSize }
    private var isOverLimit: Bool { used > limit }
    private var percent: Double { min(1.0, appState.cacheManager.usagePercent) }

    var body: some View {
        HStack(spacing: 8) {
            Text(Term.localStorage)
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: max(0, geo.size.width * CGFloat(percent)))
                }
            }
            .frame(height: 6)

            Text(used.formattedByteCount)
                .font(.caption)
                .fontWeight(isOverLimit ? .semibold : .regular)
                .foregroundStyle(isOverLimit ? .red : .secondary)
                .monospacedDigit()

            if isOverLimit {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help("Local storage (\(used.formattedByteCount)) exceeds your \(limit.formattedByteCount) limit. Increase the limit in Settings or free up space.")
            }
        }
    }

    private var barColor: Color {
        if isOverLimit { return .red }
        if percent > 0.7 { return .orange }
        return MirageStyle.accent
    }
}
