import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let openSettingsNotification = Notification.Name("\(appID).openSettings")
    private static let firstRunKey = "completedFirstRun"

    private var monitor: MeetingMonitor?
    private var statusMenu: StatusMenuController?
    private var settings: SettingsWindowController?
    private var openSettingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app has no windows most of the time; make sure macOS never quits it for being "unused".
        ProcessInfo.processInfo.disableAutomaticTermination("Waiting for the next meeting")

        let prefs = Preferences()
        let monitor = MeetingMonitor(prefs: prefs)
        let settings = SettingsWindowController {
            SettingsView(prefs: prefs, health: monitor.health, monitor: monitor)
        }
        settings.onFocus = {
            monitor.invalidateNotificationStatus()
            monitor.requestSelfCheck(force: true)
        }
        let statusMenu = StatusMenuController(monitor: monitor) { settings.show() }

        prefs.onChange = { [weak monitor] key in monitor?.preferencesChanged(key) }
        monitor.onChange = { [weak statusMenu] in statusMenu?.updateIcon() }
        monitor.onCritical = { [weak settings] in settings?.show() }

        self.monitor = monitor
        self.settings = settings
        self.statusMenu = statusMenu

        openSettingsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.openSettingsNotification, object: nil, queue: .main
        ) { [weak settings] _ in
            MainActor.assumeIsolated { settings?.show() }
        }

        Task {
            await monitor.start()
            // Show the checklist on first launch, or when the curtain can't work (e.g. no calendar access).
            if !UserDefaults.standard.bool(forKey: Self.firstRunKey) {
                UserDefaults.standard.set(true, forKey: Self.firstRunKey)
                settings.show()
            } else if monitor.health.overall == .critical {
                // Right after login the calendar database may still be starting up.
                monitor.confirmCritical()
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) shows its settings, since it has no main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settings?.show()
        return false
    }
}
