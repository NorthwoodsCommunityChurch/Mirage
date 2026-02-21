import SwiftUI

/// Full-window translucent overlay shown when dragging a file over the hub
struct DropOverlayView: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(MirageStyle.accent)

                Text("Drop to add project")
                    .font(.title3)
                    .fontWeight(.medium)
            }
        }
        .allowsHitTesting(false)
    }
}
