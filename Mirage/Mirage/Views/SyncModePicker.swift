import SwiftUI

/// Two side-by-side cards for choosing between Stream and Keep Local.
struct SyncModePicker: View {
    @Binding var selection: Bool  // false = stream, true = keepLocal

    var body: some View {
        HStack(spacing: 10) {
            SyncModeCard(
                icon: "cloud",
                title: "Stream",
                description: "Files load from the server as you open them.",
                isSelected: !selection
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { selection = false }
            }

            SyncModeCard(
                icon: "arrow.down.circle",
                title: "Keep on this Mac",
                description: "All files download and stay up to date locally.",
                isSelected: selection
            ) {
                withAnimation(.easeInOut(duration: 0.15)) { selection = true }
            }
        }
    }
}

private struct SyncModeCard: View {
    let icon: String
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(isSelected ? MirageStyle.accent : .secondary)

                Text(title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? MirageStyle.accent.opacity(0.08) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? MirageStyle.accent : Color.secondary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
