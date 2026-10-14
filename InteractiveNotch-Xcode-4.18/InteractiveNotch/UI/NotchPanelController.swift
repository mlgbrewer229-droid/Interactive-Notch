import AppKit
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class NotchPanelController: NSObject, NSMenuDelegate {
    private let logger = Logger(subsystem: "local.InteractiveNotch", category: "Panel")
    private let geometryProvider: NotchGeometryProvider
    private let interactionController: NotchInteractionController
    private let viewModel: NotchViewModel
    private let panel: NotchPanel
    private let hostingView: TrackingHostingView<NotchView>

    private var geometry: NotchGeometry?
    private var observers: [NSObjectProtocol] = []
    private var contextMenu: NSMenu?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pointerPollTimer: Timer?
    private var pointerWasInside = false
    private var lastSpaceKeepAlive = Date.distantPast
    private var lastGeometryAvailable: Bool?
    private var dashboardNotchArmed = false
    private var returnHomeArmed = false
    private var settingsEntryTask: DispatchWorkItem?
    private var settingsEntryHoldActive = false

    init(
        geometryProvider: NotchGeometryProvider = NotchGeometryProvider(),
        interactionController: NotchInteractionController? = nil,
        viewModel: NotchViewModel
    ) {
        self.geometryProvider = geometryProvider
        self.interactionController = interactionController ?? NotchInteractionController()
        self.viewModel = viewModel
        panel = NotchPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostingView = TrackingHostingView(rootView: NotchView(model: viewModel))
        super.init()
        configurePanel()
        configureInteraction()
        installObservers()
    }

    func start() {
        viewModel.start()
        recalculateGeometry()
        installPointerMonitors()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.handlePointerLocation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerPollTimer = timer
        handlePointerLocation()
    }

    func stop() {
        settingsEntryTask?.cancel()
        settingsEntryTask = nil
        settingsEntryHoldActive = false
        viewModel.setInteractionHold(.settingsNavigation, active: false)
        removePointerMonitors()
        pointerPollTimer?.invalidate()
        pointerPollTimer = nil
        interactionController.reset()
        viewModel.stop()
        panel.orderOut(nil)
    }

    func showManagementMenu() {
        guard geometry != nil else { return }
        interactionController.forceExpanded()
        viewModel.setInteractionHold(.contextMenu, active: true)
        panel.ignoresMouseEvents = false

        let menu = makeManagementMenu()
        contextMenu = menu
        menu.delegate = self
        let point = NSPoint(x: panel.contentView?.bounds.midX ?? 0, y: panel.contentView?.bounds.maxY ?? 0)
        menu.popUp(positioning: nil, at: point, in: panel.contentView)
    }

    func menuDidClose(_ menu: NSMenu) {
        contextMenu = nil
        viewModel.setInteractionHold(.contextMenu, active: false)
        handlePointerLocation(forceTransition: true)
    }

    private func configurePanel() {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // Sit one level above the display shield used by many menu-extra
        // overlays, while remaining below the system cursor level.
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel() + 1))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.sharingType = .none
        panel.contentView = hostingView
    }

    private func configureInteraction() {
        hostingView.onRightClick = { [weak self] in self?.showManagementMenu() }
        interactionController.onExpansionChanged = { [weak self] expanded in
            guard let self else { return }
            if expanded {
                self.viewModel.expandDashboard()
            } else {
                self.viewModel.collapseToActivity()
                self.panel.resignKey()
            }
            self.handlePointerLocation(forceTransition: true)
        }
        viewModel.onPresentationChanged = { [weak self] _ in
            guard let self else { return }
            self.panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel() + 1))
            self.panel.orderFrontRegardless()
            self.handlePointerLocation(forceTransition: true)
        }
        viewModel.onInteractionHoldChanged = { [weak self] held in
            guard let self else { return }
            self.interactionController.setInteractionHeld(held)
            if !held { self.handlePointerLocation(forceTransition: true) }
        }
    }

    private func installObservers() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recalculateGeometry() }
        })

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.viewModel.prepareForSleep() }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.viewModel.reconcileAfterWake()
                self?.recalculateGeometry()
            }
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keepVisibleThroughSpaceTransition()
                self?.recalculateGeometry()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.recalculateGeometry()
                }
            }
        })
    }

    private func recalculateGeometry() {
        geometry = geometryProvider.currentGeometry(fallback: geometry)
        if lastGeometryAvailable != (geometry != nil) {
            lastGeometryAvailable = geometry != nil
            logger.notice("built-in notch geometry available: \(self.geometry != nil)")
        }
        guard let geometry else {
            interactionController.reset()
            panel.orderOut(nil)
            return
        }
        viewModel.setNotchGeometry(width: geometry.notchFrame.width, height: geometry.notchFrame.height)
        panel.setFrame(geometry.maximumPanelFrame, display: true)
        panel.orderFrontRegardless()
        handlePointerLocation(forceTransition: true)
    }

    private func makeManagementMenu() -> NSMenu {
        let menu = NSMenu(title: "Interactive Notch")

        let widgetsItem = NSMenuItem(title: "Widgets & Settings…", action: #selector(openWidgetSettings(_:)), keyEquivalent: "")
        widgetsItem.target = self
        menu.addItem(widgetsItem)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let restartItem = NSMenuItem(title: "Restart Media Integration", action: #selector(restartMediaIntegration(_:)), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        let restartSpectrumItem = NSMenuItem(title: "Restart Audio Spectrum", action: #selector(restartAudioSpectrum(_:)), keyEquivalent: "")
        restartSpectrumItem.target = self
        menu.addItem(restartSpectrumItem)

        let audioSettingsItem = NSMenuItem(title: "System Audio Recording Settings…", action: #selector(openAudioCaptureSettings(_:)), keyEquivalent: "")
        audioSettingsItem.target = self
        menu.addItem(audioSettingsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Interactive Notch", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t change Launch at Login"
            alert.runModal()
        }
    }

    @objc private func restartMediaIntegration(_ sender: Any?) { viewModel.restartMediaIntegration() }
    @objc private func restartAudioSpectrum(_ sender: Any?) { viewModel.restartAudioSpectrum() }
    @objc private func openAudioCaptureSettings(_ sender: Any?) { viewModel.openAudioCaptureSettings() }
    @objc private func quit(_ sender: Any?) { NSApplication.shared.terminate(nil) }

    @objc private func openWidgetSettings(_ sender: Any?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settingsEntryTask?.cancel()
            self.settingsEntryHoldActive = true
            self.viewModel.setInteractionHold(.settingsNavigation, active: true)
            self.interactionController.forceExpanded()
            self.viewModel.openCustomize()
            let release = DispatchWorkItem { [weak self] in self?.releaseSettingsEntryHold() }
            self.settingsEntryTask = release
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: release)
        }
    }

    private func releaseSettingsEntryHold() {
        guard settingsEntryHoldActive else { return }
        settingsEntryHoldActive = false
        settingsEntryTask?.cancel()
        settingsEntryTask = nil
        viewModel.setInteractionHold(.settingsNavigation, active: false)
    }

    private func installPointerMonitors() {
        guard globalPointerMonitor == nil, localPointerMonitor == nil else { return }
        let movementMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .swipe, .gesture]
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: movementMask.union([.rightMouseDown, .leftMouseUp])
        ) { [weak self] event in
            Task { @MainActor in self?.handlePointerEvent(event) }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: movementMask.union([.leftMouseDown, .leftMouseUp])
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalPointerEvent(event) }
            return event
        }
    }

    private func removePointerMonitors() {
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
    }

    private func handlePointerEvent(_ event: NSEvent) {
        if event.type == .swipe || event.type == .gesture {
            keepVisibleThroughSpaceTransition()
        }
        if event.type == .rightMouseDown,
           geometry?.hoverFrame(for: viewModel.presentation, dashboardHeight: viewModel.dashboardHeight).contains(NSEvent.mouseLocation) == true {
            showManagementMenu()
            return
        }
        handlePointerLocation()
    }

    private func handleLocalPointerEvent(_ event: NSEvent) {
        if event.type == .swipe || event.type == .gesture {
            keepVisibleThroughSpaceTransition()
        }
        if event.type == .leftMouseDown,
           (viewModel.presentation.isExpanded || viewModel.presentation.isCompact),
           geometry?.surfaceFrame(for: viewModel.presentation, dashboardHeight: viewModel.dashboardHeight).contains(NSEvent.mouseLocation) == true {
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
        }
        handlePointerLocation()
    }

    private func handlePointerLocation(forceTransition: Bool = false) {
        guard let geometry else {
            panel.ignoresMouseEvents = true
            pointerWasInside = false
            return
        }

        let location = NSEvent.mouseLocation
        if viewModel.isSliderHeld && NSEvent.pressedMouseButtons & 1 == 0 {
            viewModel.finishInterruptedPointerDrag()
        }
        let inNotchZone = geometry.activationFrame.insetBy(dx: -10, dy: -8).contains(location)
        if viewModel.presentation == .dashboard {
            returnHomeArmed = false
            if !inNotchZone {
                dashboardNotchArmed = true
            } else if dashboardNotchArmed {
                dashboardNotchArmed = false
                viewModel.openCustomize()
            }
        } else if geometry.shouldReturnHome(at: location, presentation: viewModel.presentation) {
            dashboardNotchArmed = false
            if returnHomeArmed {
                returnHomeArmed = false
                viewModel.returnFromDetail()
            }
        } else if viewModel.presentation.isExpanded {
            dashboardNotchArmed = false
            returnHomeArmed = true
        } else {
            dashboardNotchArmed = false
            returnHomeArmed = false
        }
        let presentation = viewModel.presentation
        let isInside = geometry.containsPointer(location, presentation: presentation, dashboardHeight: viewModel.dashboardHeight)
        let insideVisibleSurface = geometry.surfaceFrame(for: presentation, dashboardHeight: viewModel.dashboardHeight).contains(location)
        if settingsEntryHoldActive && insideVisibleSurface && presentation == .customize {
            releaseSettingsEntryHold()
        }
        let hasVisibleInteractiveSurface = presentation.isExpanded || presentation.isCompact
        panel.ignoresMouseEvents = !(hasVisibleInteractiveSurface && (insideVisibleSurface || viewModel.hasInteractionHold))

        guard forceTransition || isInside != pointerWasInside else { return }
        pointerWasInside = isInside
        if isInside { interactionController.pointerEntered() } else { interactionController.pointerExited() }
    }

    private func keepVisibleThroughSpaceTransition() {
        guard Date().timeIntervalSince(lastSpaceKeepAlive) > 0.3 else { return }
        lastSpaceKeepAlive = Date()
        for step in 0...12 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.08) { [weak self] in
                guard let self, self.geometry != nil else { return }
                self.panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel() + 1))
                self.panel.orderFrontRegardless()
            }
        }
    }
}

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
