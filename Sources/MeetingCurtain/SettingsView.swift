import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var prefs: Preferences
    let health: HealthMonitor
    let monitor: MeetingMonitor

    var body: some View {
        Form {
            Section("Reminder") {
                Stepper(value: $prefs.leadMinutes, in: Preferences.leadRange) {
                    LabeledContent("Show the curtain") {
                        Text(prefs.leadMinutes == 0 ? "when the meeting starts" : "\(prefs.leadMinutes) min before")
                            .monospacedDigit()
                    }
                }
                Toggle("Skip events I declined", isOn: $prefs.skipDeclined)
                Toggle(isOn: $prefs.includeAllDay) {
                    Text("Include all-day events")
                    Text("Shown once at 9:00 on the day.")
                }
                LabeledContent("Preview") {
                    Button("Show Test Curtain") { monitor.showTestCurtain() }
                }
            }

            Section("Getting your attention") {
                Toggle("Play a sound", isOn: $prefs.playSound)
                Picker("Sound", selection: $prefs.soundName) {
                    ForEach(Preferences.sounds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!prefs.playSound)
                Toggle(isOn: $prefs.lockScreenAlerts) {
                    Text("Notify on the lock screen")
                    Text("When the Mac is locked the curtain can't be seen, so a notification is posted too.")
                }
            }

            Section("Startup") {
                Toggle(isOn: $prefs.launchAtLogin) {
                    Text("Launch at login")
                    Text("Starts with your Mac so reminders work right after you log in.")
                }
            }

            Section {
                ForEach(health.checks) { check in
                    CheckRow(check: check) { monitor.perform($0) }
                }
            } header: {
                HStack {
                    Text("Self-check")
                    Spacer()
                    if let lastRun = health.lastRun {
                        Text("Last run \(lastRun.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Button("Run Now") { Task { await monitor.runSelfCheck() } }
                        .controlSize(.small)
                }
            } footer: {
                Text("Runs by itself at launch, after waking up, every 15 minutes, and syncs Google 3 minutes before each curtain. Repairs the login item and calendar data automatically when it can.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 720)
    }
}

private struct CheckRow: View {
    let check: HealthCheck
    let perform: (HealthCheck.Fix) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: check.status.symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                Text(check.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let fix = check.fix {
                Button(fix.label) { perform(fix) }
            }
        }
    }

    private var color: Color {
        switch check.status {
        case .ok: .green
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Owns the settings window while it is open; closing it releases the window and its views.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeContent: () -> SettingsView
    var onShow: (() -> Void)?

    init(makeContent: @escaping () -> SettingsView) {
        self.makeContent = makeContent
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: makeContent()))
            window.title = "MeetingCurtain"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        onShow?()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.window = nil }
        }
    }
}
