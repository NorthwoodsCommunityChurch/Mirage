import SwiftUI
import Sparkle

@main
struct MirageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    private let updaterController: SPUStandardUpdaterController

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        Window("Mirage", id: "main") {
            ProjectHubView()
                .frame(minWidth: 600, idealWidth: 720, minHeight: 440, idealHeight: 540)
                .environmentObject(appState)
                .onAppear {
                    appDelegate.appState = appState
                    Task { await appState.initialSetup() }
                    // Check for crash report from previous session.
                    // Delay briefly so the window is fully visible before showing the alert.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        CrashReporter.shared.promptIfNeeded()
                    }
                }
                .alert("Error", isPresented: $appState.showAlert) {
                    Button("OK") {}
                } message: {
                    Text(appState.alertMessage ?? "An unknown error occurred.")
                }
        }
        .defaultSize(width: 720, height: 540)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandMenu("Projects") {
                Button("Add Folder...") {
                    appState.dropInfo = nil
                    appState.showAddShare = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("Connect All") {
                    Task { await appState.mountAll() }
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])

                Button("Disconnect All") {
                    Task { await appState.unmountAll() }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.menuBarIconName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates...") { updater.checkForUpdates() }
            .disabled(!viewModel.canCheckForUpdates)
    }
}

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
