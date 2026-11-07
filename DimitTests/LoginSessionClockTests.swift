import XCTest
@testable import Dimit

@MainActor
final class LoginSessionClockTests: XCTestCase {
    private final class TestClock {
        var current: Date
        init(_ start: Date) { current = start }
        func now() -> Date { current }
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "test.login.\(UUID().uuidString)")!
    }

    func test_shortSleepAndScreenSaverDoNotRestartTheClock() {
        let time = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = defaults()
        let clock = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        let initial = clock.start

        // No system sleep notification is issued by a screen saver.
        time.current = initial.addingTimeInterval(5 * 3600)
        XCTAssertEqual(clock.start, initial)

        clock.willSleep()
        time.current = time.current.addingTimeInterval(2 * 3600)
        XCTAssertFalse(clock.didWake(), "exactly two hours is not over the threshold")
        XCTAssertEqual(clock.start, initial)

        // Relaunching Dimit within the same login session keeps its start.
        let reopened = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        XCTAssertEqual(reopened.start, initial)
    }

    func test_sleepLongerThanTwoHoursRestartsAtWakeAndPersists() {
        let time = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = defaults()
        let clock = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        clock.willSleep()
        time.current = time.current.addingTimeInterval(2 * 3600 + 1)
        XCTAssertTrue(clock.didWake())
        XCTAssertEqual(clock.start, time.current)
        let reopened = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        XCTAssertEqual(reopened.start, time.current)
    }

    func test_pendingSleepIsReconciledAfterAppRelaunch() {
        let time = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = defaults()
        let clock = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        clock.willSleep()
        time.current = time.current.addingTimeInterval(3 * 3600)
        let reopened = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        XCTAssertEqual(reopened.start, time.current)
    }

    func test_relaunchAfterShortSleepClearsPendingSleepMarker() {
        let time = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = defaults()
        let original = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        let start = original.start
        original.willSleep()
        time.current = time.current.addingTimeInterval(30 * 60)
        let reopened = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        XCTAssertEqual(reopened.start, start)

        // A subsequent real sleep starts its own interval, not one that
        // accidentally includes the prior 30 minutes.
        reopened.willSleep()
        time.current = time.current.addingTimeInterval(105 * 60)
        XCTAssertFalse(reopened.didWake())
        XCTAssertEqual(reopened.start, start)
    }

    func test_newSecurityLoginSessionStartsFreshEvenWithoutReboot() {
        let time = TestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let store = defaults()
        let original = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-1" })
        time.current = time.current.addingTimeInterval(3600)
        let newLogin = LoginSessionClock(defaults: store, now: time.now, sessionID: { "login-2" })
        XCTAssertNotEqual(newLogin.start, original.start)
        XCTAssertEqual(newLogin.start, time.current)
    }
}
