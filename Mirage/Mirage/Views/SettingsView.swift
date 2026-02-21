import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            AdvancedSettingsTab()
                .tabItem {
                    Label("Advanced", systemImage: "wrench")
                }
        }
        .frame(width: 450, height: 380)
    }
}

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState

    private let storageSizeOptions = [5, 10, 25, 50, 100, 200, 500]

    var body: some View {
        Form {
            Section(Term.localStorage) {
                Picker("Maximum Local Storage", selection: $appState.globalMaxCacheGB) {
                    ForEach(storageSizeOptions, id: \.self) { gb in
                        Text("\(gb) GB").tag(gb)
                    }
                }

                Text("Files are stored locally as you access them. The oldest files are removed when the limit is reached.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Currently using:")
                        Spacer()
                        Text(appState.cacheManager.totalCacheSize.formattedByteCount)
                            .monospacedDigit()
                    }

                    if appState.cacheManager.offlineFileSize > 0 {
                        HStack {
                            Text("Kept local:")
                            Spacer()
                            Text(appState.cacheManager.offlineFileSize.formattedByteCount)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                Button(Term.freeUpSpace) {
                    try? appState.cacheManager.clearAllCaches()
                }
                .foregroundStyle(.red)
            }

            Section("Startup") {
                Toggle(Term.autoConnect, isOn: $appState.autoMountOnLaunch)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

struct AdvancedSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var installer = RcloneInstaller()
    @State private var rclonePath: String = ""
    @State private var reportKey: String = ""

    var body: some View {
        Form {
            Section("Sync Engine") {
                HStack {
                    TextField("Path", text: $rclonePath)
                        .textFieldStyle(.roundedBorder)
                        .onAppear {
                            rclonePath = appState.rclonePath
                            Task { await installer.checkForUpdate(rclonePath: appState.rclonePath) }
                        }
                        .onSubmit { appState.rclonePath = rclonePath }

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
                        if panel.runModal() == .OK, let url = panel.url {
                            rclonePath = url.path
                            appState.rclonePath = url.path
                        }
                    }
                }

                if let version = appState.rcloneVersion {
                    HStack {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if installer.updateAvailable, let latest = installer.latestVersion {
                            Text("\(latest) available")
                                .font(.caption)
                                .foregroundStyle(.orange)

                            Button("Update") {
                                Task {
                                    await installer.downloadAndInstall()
                                    if case .done = installer.state {
                                        await appState.initialSetup()
                                    }
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(installer.state == .downloading || installer.state == .installing)
                        } else {
                            Button("Check for Update") {
                                Task { await installer.checkForUpdate(rclonePath: appState.rclonePath) }
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                    }

                    if case .downloading = installer.state {
                        HStack {
                            ProgressView().controlSize(.mini)
                            Text("Downloading...").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if case .installing = installer.state {
                        HStack {
                            ProgressView().controlSize(.mini)
                            Text("Installing...").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if case .failed(let msg) = installer.state {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                } else {
                    Text("Sync engine not found at this path")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Volume Location") {
                HStack {
                    Text(appState.volumeLocation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Change...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.directoryURL = URL(fileURLWithPath: appState.volumeLocation)
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.volumeLocation = url.path
                        }
                    }
                }

                Text("New projects will appear as folders inside this directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Crash Reporting") {
                HStack {
                    SecureField("Report Key", text: $reportKey)
                        .textFieldStyle(.roundedBorder)
                        .onAppear { reportKey = UserDefaults.standard.string(forKey: "crashReportKey") ?? "" }
                        .onSubmit { saveCrashReportKey() }
                        .onChange(of: reportKey) { saveCrashReportKey() }

                    if !reportKey.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Text("If provided, crash reports are sent directly to the developers. Ask your admin for this key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Locations") {
                HStack {
                    Text("Local file cache")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(appState.cacheManager.cacheBaseDir)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }

                let logDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Logs/MountCache")
                HStack {
                    Text("Log files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.open(logDir)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func saveCrashReportKey() {
        let trimmed = reportKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "crashReportKey")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "crashReportKey")
        }
    }
}
