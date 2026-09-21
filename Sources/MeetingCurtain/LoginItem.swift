import ServiceManagement

/// "Open at Login" through the system's login item list (System Settings → General → Login Items).
@MainActor
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Registers or unregisters the app. Returns false when the system refused.
    @discardableResult
    static func apply(enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled, service.status != .requiresApproval {
                try service.register()
                log.notice("Registered login item")
            } else if !enabled, service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
                log.notice("Unregistered login item")
            }
            return true
        } catch {
            log.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
