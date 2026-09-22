import AppKit

// Developer aid: render the curtain to a PNG without showing any window.
if let index = CommandLine.arguments.firstIndex(of: "--render-curtain"), index + 1 < CommandLine.arguments.count {
    let variant = index + 2 < CommandLine.arguments.count ? CommandLine.arguments[index + 2] : "single"
    CurtainSnapshot.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), variant: variant)
    exit(0)
}

// Launch Services keeps a single instance, but running the binary directly bypasses that.
// In that case, ask the running copy to open its settings and quit. Only the younger copy quits, so
// two copies starting at the same moment don't both exit.
let me = NSRunningApplication.current
func launchOrder(_ app: NSRunningApplication) -> (Date, pid_t) { (app.launchDate ?? .distantFuture, app.processIdentifier) }
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? appID)
       .contains(where: { launchOrder($0) < launchOrder(me) }) {
    DistributedNotificationCenter.default().postNotificationName(
        AppDelegate.openSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true
    )
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
