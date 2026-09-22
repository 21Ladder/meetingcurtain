import Foundation
import Observation
import MeetingCurtainCore

/// User settings, persisted in UserDefaults. Changing a property saves it and reports the key to `onChange`.
@MainActor @Observable
final class Preferences {
    enum Key: String {
        case leadMinutes, includeAllDay, skipDeclined, playSound, soundName, lockScreenAlerts, launchAtLogin, calendarChoices
    }

    static let defaultSound = "Glass"
    static let sounds = ["Glass", "Hero", "Ping", "Submarine", "Funk", "Sosumi", "Blow", "Bottle", "Purr", "Tink"]
    static let leadRange = 0...30

    @ObservationIgnored var onChange: ((Key) -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    var leadMinutes: Int { didSet { save(leadMinutes, .leadMinutes) } }
    var includeAllDay: Bool { didSet { save(includeAllDay, .includeAllDay) } }
    var skipDeclined: Bool { didSet { save(skipDeclined, .skipDeclined) } }
    var playSound: Bool { didSet { save(playSound, .playSound) } }
    var soundName: String { didSet { save(soundName, .soundName) } }
    var lockScreenAlerts: Bool { didSet { save(lockScreenAlerts, .lockScreenAlerts) } }
    var launchAtLogin: Bool { didSet { save(launchAtLogin, .launchAtLogin) } }
    var calendarSelection: CalendarSelection { didSet { save(calendarSelection.choices, .calendarChoices) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.leadMinutes.rawValue: 2,
            Key.includeAllDay.rawValue: false,
            Key.skipDeclined.rawValue: false,
            Key.playSound.rawValue: true,
            Key.soundName.rawValue: Self.defaultSound,
            Key.lockScreenAlerts.rawValue: true,
            Key.launchAtLogin.rawValue: true,
        ])
        let lead = defaults.integer(forKey: Key.leadMinutes.rawValue)
        leadMinutes = min(max(lead, Self.leadRange.lowerBound), Self.leadRange.upperBound)
        includeAllDay = defaults.bool(forKey: Key.includeAllDay.rawValue)
        skipDeclined = defaults.bool(forKey: Key.skipDeclined.rawValue)
        playSound = defaults.bool(forKey: Key.playSound.rawValue)
        let sound = defaults.string(forKey: Key.soundName.rawValue) ?? ""
        soundName = Self.sounds.contains(sound) ? sound : Self.defaultSound
        lockScreenAlerts = defaults.bool(forKey: Key.lockScreenAlerts.rawValue)
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin.rawValue)
        calendarSelection = CalendarSelection(
            choices: defaults.dictionary(forKey: Key.calendarChoices.rawValue) as? [String: Bool] ?? [:]
        )
    }

    var policy: CurtainPolicy {
        CurtainPolicy(
            leadTime: TimeInterval(leadMinutes * 60),
            includeAllDay: includeAllDay,
            skipDeclined: skipDeclined
        )
    }

    private func save(_ value: some Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
        onChange?(key)
    }
}
