import AppKit
import Combine
import SwiftUI

// MARK: - App Coordinator & Entry Point

@MainActor
final class AppLaunchCoordinator: NSObject, NSApplicationDelegate {
    let switcherService = AccountSwitcherService()
    private var panelController: MenuBarPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        switcherService.bootstrapOnLaunch()
        panelController = MenuBarPanelController(service: switcherService)
    }
}

/// macOS Menu Bar app providing 1-click Antigravity account switching and per-model usage tracking.
@main
struct AGYAutoChangerLauncher {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppLaunchCoordinator()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - Floating Top-Anchored Panel Controller

private final class FloatingPopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SizingHostingView<Content: View>: NSHostingView<Content> {
    var onFittingSizeChange: ((NSSize) -> Void)?
    private var lastReportedSize: NSSize = .zero

    override func layout() {
        super.layout()
        let size = fittingSize
        guard size.width > 1, size.height > 1 else { return }
        if abs(size.width - lastReportedSize.width) > 0.5 || abs(size.height - lastReportedSize.height) > 0.5 {
            lastReportedSize = size
            onFittingSizeChange?(size)
        }
    }
}

@MainActor
private final class MenuBarPanelController: NSObject {
    private let service: AccountSwitcherService
    private let layoutState = PopoverLayoutState()
    private let statusItem: NSStatusItem
    private let panel: FloatingPopoverPanel
    private let effectView: NSVisualEffectView
    private let hostingView: SizingHostingView<MenuBarPopoverView>

    private var cancellables: Set<AnyCancellable> = []
    private var globalMouseMonitor: Any?
    private var localKeyMonitor: Any?
    private var resignActiveObserver: NSObjectProtocol?
    private var lastOpenedAt: Date = .distantPast
    private var lastExternalDismissAt: Date = .distantPast
    private var anchoredTopY: CGFloat?
    private var anchoredOriginX: CGFloat?

    init(service: AccountSwitcherService) {
        self.service = service
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let rootView = MenuBarPopoverView(service: service, layoutState: layoutState)
        self.hostingView = SizingHostingView(rootView: rootView)
        self.hostingView.sizingOptions = [.intrinsicContentSize]

        self.effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: AppConfig.uiPopoverIdealWidth, height: 320))
        self.effectView.material = .popover
        self.effectView.blendingMode = .behindWindow
        self.effectView.state = .active
        self.effectView.maskImage = Self.roundedCornerMaskImage(cornerRadius: 12)
        self.effectView.wantsLayer = true
        self.effectView.layer?.cornerRadius = 12
        self.effectView.layer?.masksToBounds = true

        self.panel = FloatingPopoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConfig.uiPopoverIdealWidth, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        hostingView.frame = effectView.bounds
        hostingView.autoresizingMask = [.width, .height]
        effectView.addSubview(hostingView)
        panel.contentView = effectView

        hostingView.onFittingSizeChange = { [weak self] newSize in
            guard let self, self.panel.isVisible else { return }
            self.repositionPanel(to: newSize)
        }

        configureStatusButton()
        bindStatusLabel()
    }

    private static func roundedCornerMaskImage(cornerRadius: CGFloat) -> NSImage {
        let side = (cornerRadius * 2) + 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius + 1, left: cornerRadius + 1, bottom: cornerRadius + 1, right: cornerRadius + 1)
        image.resizingMode = .stretch
        return image
    }

    deinit {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
    }

    private func configureStatusButton() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseDown])
        updateStatusButtonAppearance()
    }

    private func bindStatusLabel() {
        service.$accounts
            .combineLatest(service.$switchPhase)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.updateStatusButtonAppearance()
            }
            .store(in: &cancellables)
    }

    private func updateStatusButtonAppearance() {
        guard let button = statusItem.button else { return }
        let symbolName = service.switchPhase.isInProgress
            ? "arrow.triangle.2.circlepath"
            : "bolt.horizontal.circle.fill"
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "AGY Account Switcher")
        image?.isTemplate = true
        button.image = image

        let shortTitle = service.accounts.first(where: { $0.isActive })?.menuBarShortName ?? "AGY"
        button.title = " \(shortTitle)"
        button.font = .menuBarFont(ofSize: 0)
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else {
            if Date().timeIntervalSince(lastExternalDismissAt) < 0.25 {
                return
            }
            openPanel()
        }
    }

    private func openPanel() {
        let screen = targetScreen()
        layoutState.updateScreenVisibleHeight(screen.visibleFrame.height)
        anchoredTopY = computeAnchorTopY(on: screen)
        anchoredOriginX = nil

        hostingView.layoutSubtreeIfNeeded()
        repositionPanel(to: hostingView.fittingSize, screen: screen)

        lastOpenedAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        startDismissMonitors()

        // Re-sync after initial SwiftUI preference pass settles measured body height,
        // then trigger background refresh so the popover opens with zero click delay.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.panel.isVisible {
                self.hostingView.layoutSubtreeIfNeeded()
                self.repositionPanel(to: self.hostingView.fittingSize)
            }
            self.service.refreshLiveStateAndUsage(readKeychainSecret: false)
        }
    }

    private func closePanel() {
        stopDismissMonitors()
        anchoredTopY = nil
        anchoredOriginX = nil
        panel.orderOut(nil)
    }

    private func targetScreen() -> NSScreen {
        statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func computeAnchorTopY(on screen: NSScreen) -> CGFloat {
        let menuBarBottomY = screen.visibleFrame.maxY
        if let buttonFrame = statusItem.button?.window?.frame,
           buttonFrame.minY >= menuBarBottomY - 8,
           buttonFrame.minY <= screen.frame.maxY {
            return min(menuBarBottomY - 4, buttonFrame.minY - 4)
        }
        return menuBarBottomY - 4
    }

    private func repositionPanel(to fittingSize: NSSize, screen explicitScreen: NSScreen? = nil) {
        let screen = explicitScreen ?? targetScreen()
        let visibleFrame = screen.visibleFrame
        layoutState.updateScreenVisibleHeight(visibleFrame.height)

        let width = min(AppConfig.uiPopoverMaxWidth, max(AppConfig.uiPopoverMinWidth, ceil(fittingSize.width)))
        let maxHeight = max(360, floor(visibleFrame.height * AppConfig.uiPopoverMaxScreenFraction))
        let height = min(maxHeight, max(120, ceil(fittingSize.height)))

        let topY = anchoredTopY ?? computeAnchorTopY(on: screen)
        anchoredTopY = topY
        let originY = max(visibleFrame.minY + 4, topY - height)

        let minX = visibleFrame.minX + 8
        let maxX = max(minX, visibleFrame.maxX - width - 8)
        let originX: CGFloat
        if let lockedX = anchoredOriginX {
            originX = min(maxX, max(minX, lockedX))
        } else {
            let desiredX: CGFloat
            if let buttonWindow = statusItem.button?.window,
               buttonWindow.frame.maxX > visibleFrame.minX,
               buttonWindow.frame.minX < visibleFrame.maxX {
                desiredX = buttonWindow.frame.midX - (width / 2)
            } else {
                desiredX = visibleFrame.maxX - width - 12
            }
            let clamped = min(maxX, max(minX, round(desiredX)))
            anchoredOriginX = clamped
            originX = clamped
        }

        let targetFrame = NSRect(x: originX, y: originY, width: width, height: height)
        if abs(panel.frame.origin.x - targetFrame.origin.x) > 0.5
            || abs(panel.frame.origin.y - targetFrame.origin.y) > 0.5
            || abs(panel.frame.size.width - targetFrame.size.width) > 0.5
            || abs(panel.frame.size.height - targetFrame.size.height) > 0.5 {
            panel.setFrame(targetFrame, display: true)
            panel.invalidateShadow()
        }
    }

    private func startDismissMonitors() {
        stopDismissMonitors()

        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, NSApp.modalWindow == nil else { return }
                self.lastExternalDismissAt = Date()
                self.closePanel()
            }
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.panel.isVisible, NSApp.modalWindow == nil else { return }
            if Date().timeIntervalSince(self.lastOpenedAt) < 0.15 { return }
            let screenPoint = NSEvent.mouseLocation
            if self.panel.frame.contains(screenPoint) { return }
            if let buttonFrame = self.statusItem.button?.window?.frame, buttonFrame.contains(screenPoint) {
                return
            }
            self.lastExternalDismissAt = Date()
            self.closePanel()
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.closePanel()
                return nil
            }
            return event
        }
    }

    private func stopDismissMonitors() {
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
            self.resignActiveObserver = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
    }
}
