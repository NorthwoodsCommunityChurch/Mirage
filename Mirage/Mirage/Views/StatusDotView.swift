import SwiftUI

/// Animated status indicator dot
struct StatusDotView: View {
    let status: MountStatus
    var size: CGFloat = 10

    @State private var isPulsing = false

    private var shouldPulse: Bool {
        status == .mounting || status == .indexing || status == .unmounting
    }

    var body: some View {
        Circle()
            .fill(MirageStyle.statusColor(for: status))
            .frame(width: size, height: size)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onChange(of: status) { _, _ in
                isPulsing = shouldPulse
            }
            .onAppear {
                isPulsing = shouldPulse
            }
    }
}
