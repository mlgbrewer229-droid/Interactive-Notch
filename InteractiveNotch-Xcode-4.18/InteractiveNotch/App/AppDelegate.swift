import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: NotchPanelController?
    private var hotKeyController: GlobalHotKeyController?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let viewModel = NotchViewModel(
            mediaSession: MediaRemoteSessionProvider(),
            volumeController: SystemVolumeController(),
            batteryMonitor: BatteryMonitor(),
            timerManager: PersistentTimerManager(),
            calendarProvider: EventKitCalendarProvider(),
            weatherProvider: LocalWeatherProvider(),
            mirrorCamera: MirrorCameraController(),
            dashboardStore: DashboardConfigurationStore(),
            spectrumProvider: SystemAudioSpectrumProvider()
        )
        let panelController = NotchPanelController(viewModel: viewModel)
        self.panelController = panelController
        hotKeyController = GlobalHotKeyController { [weak panelController] in
            panelController?.showManagementMenu()
        }
        panelController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.stop()
    }
}
