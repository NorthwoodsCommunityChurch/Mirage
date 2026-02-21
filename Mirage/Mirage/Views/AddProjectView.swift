import SwiftUI

struct AddProjectView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let prefill: SMBDropInfo?

    // Connection fields
    @State private var host: String
    @State private var username: String
    @State private var password = ""
    @State private var shareName: String
    @State private var subfolder: String
    @State private var displayName: String

    // Settings
    @State private var autoMount = true
    @State private var keepLocal = false
    @State private var useCustomCachePath = false
    @State private var customCachePath = ""

    // State
    @State private var step = 1
    @State private var availableShares: [String] = []
    @State private var isTestingConnection = false
    @State private var isBrowsingShares = false
    @State private var isAddingProject = false
    @State private var connectionError: String?
    @State private var tempRemoteName: String?
    @State private var foundKeychainPassword = false

    init(prefill: SMBDropInfo? = nil) {
        self.prefill = prefill
        _host = State(initialValue: prefill?.host ?? "")
        _username = State(initialValue: prefill?.detectedUsername ?? "")
        _shareName = State(initialValue: prefill?.shareName ?? "")
        _subfolder = State(initialValue: prefill?.subfolder ?? "")
        _displayName = State(initialValue: prefill?.volumeName ?? "")
    }

    private var totalSteps: Int { prefill != nil ? 1 : 3 }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Step indicator (only for manual multi-step flow)
                if totalSteps > 1 {
                    HStack(spacing: 4) {
                        ForEach(1...totalSteps, id: \.self) { s in
                            Circle()
                                .fill(s <= step ? MirageStyle.accent : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                }

                Group {
                    currentStepView
                }
                .padding(20)

                Divider()

                // Navigation buttons
                HStack {
                    Button("Cancel") { cleanupAndDismiss() }
                        .keyboardShortcut(.cancelAction)

                    Spacer()

                    if step > 1 {
                        Button("Back") { step -= 1 }
                    }

                    if step < totalSteps {
                        Button("Next") { handleNext() }
                            .buttonStyle(.borderedProminent)
                            .tint(MirageStyle.accent)
                            .disabled(!canProceed)
                    } else {
                        Button("Add Folder") { addProject() }
                            .buttonStyle(.borderedProminent)
                            .tint(MirageStyle.accent)
                            .disabled(!canAdd)
                    }
                }
                .padding(16)
            }
            .disabled(isAddingProject)

            if isAddingProject {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Setting up your folder...")
                        .font(.headline)
                    Text("Connecting to server and preparing files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .frame(width: 480, height: prefill != nil ? (foundKeychainPassword ? 320 : 400) : 420)
        .onAppear {
            if let prefill, let detectedUser = prefill.detectedUsername {
                // Try to grab the password from macOS keychain
                if let systemPassword = KeychainHelper.lookupSystemSMBPassword(
                    host: prefill.host,
                    username: detectedUser
                ) {
                    password = systemPassword
                    foundKeychainPassword = true
                }
            }
        }
    }

    // MARK: - Step routing

    @ViewBuilder
    private var currentStepView: some View {
        if prefill != nil {
            // Single-step drag-drop flow
            prefillStep
        } else {
            switch step {
            case 1: manualConnectionStep
            case 2: manualShareSelectionStep
            case 3: manualConfirmStep
            default: EmptyView()
            }
        }
    }

    // MARK: - Drag-and-drop flow (single step)

    private var serverSummary: String {
        let folder = shareName + (subfolder.isEmpty ? "" : "/\(subfolder)")
        if username.isEmpty {
            return "\(host) / \(folder)"
        }
        return "\(host) / \(folder)  ·  \(username)"
    }

    private var prefillStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Folder name
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder Name")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("", text: $displayName, prompt: Text("My Folder"))
                    .textFieldStyle(.roundedBorder)
                Text(serverSummary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Password (only if not found in keychain)
            if !foundKeychainPassword {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Password")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Text("Mirage needs your password to maintain its own connection.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // Sync mode cards
            SyncModePicker(selection: $keepLocal)

            cacheLocationPicker

            if let error = connectionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - Manual flow

    private var manualConnectionStep: some View {
        Form {
            Section("Server Connection") {
                TextField("Server", text: $host, prompt: Text("192.168.1.100 or nas.local"))
                TextField("Username", text: $username, prompt: Text("admin"))
                SecureField("Password", text: $password)
            }

            if let error = connectionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var manualShareSelectionStep: some View {
        Form {
            Section("Select Folder") {
                if isBrowsingShares {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("Looking for folders...")
                    }
                } else if !availableShares.isEmpty {
                    Picker("Folder", selection: $shareName) {
                        ForEach(availableShares, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                } else {
                    TextField("Folder Name", text: $shareName, prompt: Text("Documents"))
                }
            }

            if !availableShares.isEmpty {
                Section {
                    Button("Refresh") { browseShares() }
                        .buttonStyle(.borderless)
                }
            }

            if let error = connectionError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { browseShares() }
    }

    private var manualConfirmStep: some View {
        Form {
            Section {
                TextField("Folder Name", text: $displayName)

                LabeledContent("Server", value: host)
                LabeledContent("Folder", value: shareName + (subfolder.isEmpty ? "" : "/\(subfolder)"))
                LabeledContent("User", value: username)
            }

            Section {
                SyncModePicker(selection: $keepLocal)
            }

            Section {
                cacheLocationPicker
            }

            Section {
                Toggle(Term.autoConnect, isOn: $autoMount)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Cache Location Picker

    private var cacheLocationPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Cache Location")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if useCustomCachePath {
                    Button("Use Default") {
                        useCustomCachePath = false
                        customCachePath = ""
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            if useCustomCachePath {
                HStack {
                    Text(customCachePath.isEmpty ? "No location selected" : customCachePath)
                        .font(.caption)
                        .foregroundStyle(customCachePath.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.message = "Choose where to store cached files for this project"
                        if panel.runModal() == .OK, let url = panel.url {
                            customCachePath = url.path
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                HStack {
                    Text("Default (local disk)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Use External Drive...") {
                        useCustomCachePath = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Logic

    private var canProceed: Bool {
        switch step {
        case 1: return !host.isEmpty && !username.isEmpty && !password.isEmpty
        case 2: return !shareName.isEmpty
        default: return true
        }
    }

    private var canAdd: Bool {
        if isAddingProject { return false }
        if displayName.isEmpty { return false }
        if password.isEmpty { return false }
        return true
    }

    private func handleNext() {
        switch step {
        case 1: testConnection()
        case 2:
            if displayName.isEmpty {
                displayName = shareName
            }
            step = 3
        default: break
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionError = nil

        let tempName = "mountcache-temp-\(UUID().uuidString.prefix(8).lowercased())"
        tempRemoteName = tempName

        Task {
            do {
                let builder = RcloneCommandBuilder(rclonePath: appState.rclonePath)
                let args = builder.createRemoteArguments(
                    name: tempName,
                    host: host,
                    username: username,
                    password: password
                )
                let result = try await Process.run(
                    executableURL: URL(fileURLWithPath: appState.rclonePath),
                    arguments: args
                )
                if result.exitCode == 0 {
                    step += 1
                } else {
                    connectionError = result.error
                }
            } catch {
                connectionError = error.localizedDescription
            }
            isTestingConnection = false
        }
    }

    private func browseShares() {
        guard let tempName = tempRemoteName else { return }
        isBrowsingShares = true
        connectionError = nil

        Task {
            do {
                let shares = try await appState.processManager.listShares(remoteName: tempName)
                availableShares = shares
                if shareName.isEmpty, let first = shares.first {
                    shareName = first
                }
            } catch {
                connectionError = error.localizedDescription
            }
            isBrowsingShares = false
        }
    }

    private func addProject() {
        isAddingProject = true

        let syncMode: ProjectSyncMode = keepLocal ? .keepLocal : .stream
        let cacheMode: VFSCacheMode = .full

        let config = SMBShareConfig(
            displayName: displayName,
            host: host,
            shareName: shareName,
            subfolder: subfolder,
            username: username,
            cacheMode: cacheMode,
            autoMount: autoMount,
            volumeName: displayName,
            volumeBaseDir: appState.volumeLocation,
            syncMode: syncMode,
            customCachePath: useCustomCachePath && !customCachePath.isEmpty ? customCachePath : nil
        )

        // Clean up temp remote
        if let tempName = tempRemoteName {
            Task { try? await appState.processManager.deleteRemote(name: tempName) }
        }

        Task {
            // Save config and credentials, then dismiss immediately.
            // Mounting happens in the background — the card shows "Connecting..."
            await appState.addShareAndDismiss(config, password: password)
            isAddingProject = false
            dismiss()
        }
    }

    private func cleanupAndDismiss() {
        if let tempName = tempRemoteName {
            Task { try? await appState.processManager.deleteRemote(name: tempName) }
        }
        dismiss()
    }
}
