import Foundation
import Security

/// A single timeline per macOS security login session. Security session IDs
/// change on logout/restart, unlike a process ID or the calendar date.
/// Persist the anchor immediately so quitting/relaunching Dimit, screen
/// savers and short sleeps cannot silently restart the curve.
@MainActor
final class LoginSessionClock {
    static let shared = LoginSessionClock()
    static let sleepResetInterval: TimeInterval = 2 * 60 * 60

    private struct Snapshot: Codable {
        var sessionID: String
        var startedAt: Date
        var asleepSince: Date?
    }

    private let defaults: UserDefaults
    private let now: () -> Date
    private let key = "loginScheduleSession.v1"
    private var snapshot: Snapshot

    var start: Date { snapshot.startedAt }

    init(
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() },
        sessionID: @escaping () -> String? = {
            var id: SecuritySessionId = 0
            guard SessionGetInfo(callerSecuritySession, &id, nil) == errSecSuccess else { return nil }
            return String(id)
        }
    ) {
        self.defaults = defaults
        self.now = now
        let current = now()
        // On an unavailable security session ID, deliberately start fresh
        // instead of carrying an anchor from a previous login by mistake.
        let identifier = sessionID() ?? UUID().uuidString
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(Snapshot.self, from: data),
           stored.sessionID == identifier, stored.startedAt <= current {
            if let sleepStart = stored.asleepSince,
               current.timeIntervalSince(sleepStart) > Self.sleepResetInterval {
                snapshot = Snapshot(sessionID: identifier, startedAt: current, asleepSince: nil)
            } else {
                snapshot = stored
            }
        } else {
            snapshot = Snapshot(sessionID: identifier, startedAt: current, asleepSince: nil)
        }
        save()
    }

    func willSleep() {
        guard snapshot.asleepSince == nil else { return }
        snapshot.asleepSince = now()
        save()
    }

    /// A two-hour sleep keeps the original timer; only a *longer* one
    /// creates a new timeline at wake. Locking or starting a screen saver
    /// does not issue a system sleep notification, so neither resets it.
    @discardableResult
    func didWake() -> Bool {
        guard let sleptAt = snapshot.asleepSince else { return false }
        let awakeAt = now()
        let sleepLength = awakeAt.timeIntervalSince(sleptAt)
        let mustRestart = sleepLength > Self.sleepResetInterval || sleepLength < 0
        snapshot.asleepSince = nil
        if mustRestart { snapshot.startedAt = awakeAt }
        save()
        return mustRestart
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}
