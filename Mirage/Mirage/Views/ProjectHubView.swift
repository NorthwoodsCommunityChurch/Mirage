import SwiftUI
import UniformTypeIdentifiers

/// Main dashboard view — card grid of projects
struct ProjectHubView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedProject: SMBShareConfig?
    @State private var isDragTargeted = false
    @State private var isDetecting = false

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
            if isDetecting {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Detecting network share...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
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
            DispatchQueue.main.async { isDetecting = true }
            AppLogger.shared.log("Drop detected, starting SMB detection for: \(url.path)")
            // Run blocking filesystem I/O on a background thread
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try SMBShareDetector.detect(from: url) }
                DispatchQueue.main.async {
                    isDetecting = false
                    switch result {
                    case .success(let info):
                        AppLogger.shared.log("SMB detection succeeded: \(info.host)/\(info.shareName)")
                        appState.dropInfo = info
                        appState.showAddShare = true
                    case .failure(let error):
                        AppLogger.shared.log("SMB detection failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        return true
    }
}
