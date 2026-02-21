import SwiftUI
import UniformTypeIdentifiers

/// Full-window empty state when no projects exist
struct EmptyHubView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDragTargeted = false
    @State private var dropError: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "shippingbox")
                .font(.system(size: 56))
                .foregroundStyle(MirageStyle.accent.opacity(0.6))

            VStack(spacing: 8) {
                Text("Welcome to Mirage")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Drop a folder from your server to get started,\nor add one manually.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Drop zone
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.title2)
                    .foregroundStyle(isDragTargeted ? MirageStyle.accent : .secondary)

                Text("Drop a network folder here")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 320)
            .frame(height: 120)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2, dash: [8]),
                        antialiased: true
                    )
                    .foregroundStyle(isDragTargeted ? MirageStyle.accent : Color.secondary.opacity(0.3))
            )
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDragTargeted ? MirageStyle.accent.opacity(0.05) : Color.clear)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
                handleDrop(providers)
            }

            if let error = dropError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(Term.addProject) {
                appState.dropInfo = nil
                appState.showAddShare = true
            }
            .buttonStyle(.borderedProminent)
            .tint(MirageStyle.accent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            DispatchQueue.main.async {
                do {
                    let info = try SMBShareDetector.detect(from: url)
                    dropError = nil
                    appState.dropInfo = info
                    appState.showAddShare = true
                } catch {
                    dropError = error.localizedDescription
                }
            }
        }
        return true
    }
}
