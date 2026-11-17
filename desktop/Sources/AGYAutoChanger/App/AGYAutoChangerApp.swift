import AppKit
import SwiftUI

// MARK: - App Entry Point

@MainActor
final class AppLaunchCoordinator: NSObject, NSApplicationDelegate, ObservableObject {
    let switcherService = AccountSwitcherService()

    func applicationDidFinishLaunching(_ notification: Notification) {
        switcherService.bootstrapOnLaunch()
    }
}

/// macOS Menu Bar app providing 1-click Antigravity account switching and per-model usage tracking.
@main
struct AGYAutoChangerApp: App {
    @NSApplicationDelegateAdaptor(AppLaunchCoordinator.self) private var launchCoordinator

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(service: launchCoordinator.switcherService)
                .onAppear {
                    launchCoordinator.switcherService.refreshLiveStateAndUsage()
                }
        } label: {
            MenuBarLabelView(service: launchCoordinator.switcherService)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabelView: View {
    @ObservedObject var service: AccountSwitcherService

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: service.switchPhase.isInProgress ? "arrow.triangle.2.circlepath" : "bolt.horizontal.circle.fill")
            if let active = service.accounts.first(where: { $0.isActive }) {
                Text(active.menuBarShortName)
            } else {
                Text("AGY")
            }
        }
    }
}
