import Foundation
import HiFiGuardCore
import OSLog
import ServiceManagement

let log = Logger(subsystem: "com.saif.hifiguard", category: "app")

enum Preferences {
    private static let guardKey = "guardEnabled"
    private static let antiDuckKey = "antiDuckEnabled"
    private static let volumesKey = "appVolumes"
    private static let loginSetUpKey = "didSetUpLoginItem"

    static var isGuardOn: Bool {
        get { UserDefaults.standard.object(forKey: guardKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: guardKey) }
    }

    static var isAntiDuckOn: Bool {
        get { UserDefaults.standard.object(forKey: antiDuckKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: antiDuckKey) }
    }

    /// Per-app settings keyed by bundle ID. Apps back at 100% are dropped so the
    /// list only holds real choices.
    static var volumes: [String: AppVolume] {
        get {
            guard let data = UserDefaults.standard.data(forKey: volumesKey) else { return [:] }
            do {
                return try JSONDecoder().decode([String: AppVolume].self, from: data)
            } catch {
                log.error("Discarding unreadable saved volumes: \(error.localizedDescription, privacy: .public)")
                return [:]
            }
        }
        set {
            do {
                let kept = newValue.filter { $0.value.needsTap }
                UserDefaults.standard.set(try JSONEncoder().encode(kept), forKey: volumesKey)
            } catch {
                log.error("Couldn't save volumes: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static var didSetUpLoginItem: Bool {
        get { UserDefaults.standard.bool(forKey: loginSetUpKey) }
        set { UserDefaults.standard.set(newValue, forKey: loginSetUpKey) }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// The app is meant to live in the menu bar all the time, so it opens at login by
    /// default. Done once, so turning it off afterwards sticks.
    static func enableOnFirstLaunch() {
        guard !Preferences.didSetUpLoginItem else { return }
        do {
            try setEnabled(true)
            log.notice("Registered as a login item")
        } catch {
            log.error("Could not register as a login item: \(error.localizedDescription, privacy: .public)")
        }
        Preferences.didSetUpLoginItem = true
    }
}
