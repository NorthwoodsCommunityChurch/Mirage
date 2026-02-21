import SwiftUI

/// First-run setup — installs sync engine without showing technical details
struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var installer = RcloneInstaller()
    @State private var customPath = ""
    @State private var isChecking = false
    @State private var showManualSection = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 40))
                    .foregroundStyle(MirageStyle.accent.opacity(0.6))

                Text(Term.settingUp)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(Term.settingUpDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                autoInstallSection

                Divider()
                    .padding(.horizontal, 40)

                manualSection
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var autoInstallSection: some View {
        VStack(spacing: 10) {
            switch installer.state {
            case .idle:
                Button {
                    Task { await installer.downloadAndInstall() }
                } label: {
                    Label("Set Up Mirage", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(MirageStyle.accent)
                .controlSize(.large)

            case .downloading:
                ProgressView()
                    .controlSize(.small)
                Text("Downloading...")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("Setting things up... you may be prompted for your password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .done(let version):
                Label("Ready to go!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(version)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Get Started") {
                    appState.rclonePath = installer.installPath
                    checkSetup()
                }
                .buttonStyle(.borderedProminent)
                .tint(MirageStyle.accent)

            case .failed(let message):
                Label("Setup failed", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                Button("Retry") {
                    Task { await installer.downloadAndInstall() }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation { showManualSection.toggle() }
            } label: {
                HStack {
                    Text("Already have the sync engine?")
                        .font(.callout)
                    Image(systemName: showManualSection ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            if showManualSection {
                HStack {
                    TextField("Path", text: $customPath, prompt: Text("/usr/local/bin/rclone"))
                        .textFieldStyle(.roundedBorder)

                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
                        if panel.runModal() == .OK, let url = panel.url {
                            customPath = url.path
                        }
                    }
                }
                .frame(maxWidth: 380)

                HStack(spacing: 8) {
                    Button("Use This Path") {
                        checkSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MirageStyle.accent)
                    .disabled(customPath.isEmpty || isChecking)

                    if isChecking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func checkSetup() {
        isChecking = true
        if !customPath.isEmpty {
            appState.rclonePath = customPath
        }
        Task {
            await appState.initialSetup()
            isChecking = false
        }
    }
}
