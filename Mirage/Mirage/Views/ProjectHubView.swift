import SwiftUI
import UniformTypeIdentifiers

/// Main dashboard view — card grid of projects
struct ProjectHubView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedProject: SMBShareConfig?
    @State private var isDragTargeted = false

    var body: some View {
        Group {
            if !appState.rcloneValid {
                OnboardingView()
            } else if appState.shares.isEmpty {
                EmptyHubView()
            } else {
                hubContent
            }
        }
        .sheet(isPresented: $appState.showAddShare) {
            AddProjectView(prefill: appState.dropInfo)
                .environmentObject(appState)
        }
        .sheet(item: $selectedProject) { project in
            ProjectDetailView(
                share: project,
                status: appState.mountStatuses[project.id] ?? .disconnected
            )
            .environmentObject(appState)
        }
    }

    private var hubContent: some View {
        VStack(spacing: 0) {
            // Toolbar area
            HStack {
                Text("Mirage")
                    .font(.title2)
                    .fontWeight(.bold)

                Spacer()

                Button {
                    appState.dropInfo = nil
                    appState.showAddShare = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(Term.addProject)
            }
            .padding(.horizontal, MirageStyle.gridSpacing)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Card grid
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240, maximum: 320))],
                    spacing: MirageStyle.gridSpacing
                ) {
                    ForEach(appState.shares) { share in
                        ProjectCardView(
                            share: share,
                            status: appState.mountStatuses[share.id] ?? .disconnected
                        )
                        .onTapGesture { selectedProject = share }
                    }
                }
                .padding(MirageStyle.gridSpacing)
            }

            // Bottom storage bar
            Divider()
            StorageOverviewBar()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .overlay {
            if isDragTargeted {
                DropOverlayView()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }
            DispatchQueue.main.async {
                if let info = try? SMBShareDetector.detect(from: url) {
                    appState.dropInfo = info
                    appState.showAddShare = true
                }
            }
        }
        return true
    }
}
