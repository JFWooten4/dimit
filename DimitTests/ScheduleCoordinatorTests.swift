import XCTest
@testable import Dimit

/// The real production `ScheduleCoordinator` runs off a live `Timer` and
/// `Date()` — these tests inject both so every scenario is evaluated by
/// calling `evaluateNow()` directly at a chosen instant, never by waiting
/// on real wall-clock time. The Timer scheduling itself (interval choice,
/// tolerance, run-loop mode) has no fake to run against and is untested,
/// same disclosed limitation as `HotkeyManager`'s registration layer.
@MainActor
final class ScheduleCoordinatorTests: XCTestCase {
    private var tz: TimeZone { TimeZone(identifier: "Asia/Tashkent")! }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        c.timeZone = tz
        return calendar.date(from: c)!
    }

    private func freshState() -> AppState {
        AppState(persistence: Persistence(suiteName: "test.\(UUID().uuidString)"))
    }

    private func sunsetToSunriseConfig(rampMinutes: Int = 20) -> ScheduleConfig {
        var c = ScheduleConfig.defaults
        c.mode = .sunsetToSunrise
        c.location = Coordinate(latitude: 41.2995, longitude: 69.2401)
        c.rampMinutes = rampMinutes
        c.bedtime = TimeOfDay(hour: 22, minute: 30)
        return c
    }

    /// A mutable "clock" the test controls, so `now()` inside the
    /// coordinator advances only when the test says so.
    private final class TestClock {
        var current: Date
        init(_ start: Date) { current = start }
        func now() -> Date { current }
    }

    /// `ScheduleCoordinator`'s config-change handling is deliberately
    /// deferred one main-queue turn (`.receive(on: .main)`, fixing a real
    /// bug where reading `appState.scheduleConfig` synchronously inside
    /// the willSet-timed Combine callback saw the *previous* value). Any
    /// test that mutates `scheduleConfig` after constructing the
    /// coordinator, expecting to observe the reaction, must flush the main
    /// queue once first — otherwise it's asserting before that reaction
    /// has had a chance to run at all.
    private func flushMainQueue() {
        let expectation = expectation(description: "main queue flush")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - Basic driving

    func test_manualMode_writesNothing_evenWhenEvaluated() {
        let state = freshState()
        state.warmthK = 6500
        let clock = TestClock(date(2026, 9, 8, 20, 0))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()
        XCTAssertEqual(state.warmthK, 6500, "manual mode must never touch AppState")
    }

    func test_sunsetToSunrise_atBedtimePlusRampDuration_landsExactlyOnNight() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 12, 0)) // noon, before anything interesting
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)

        clock.current = date(2026, 9, 8, 23, 0) // well past 22:30 + 20 min ramp
        coordinator.evaluateNow()

        XCTAssertEqual(state.warmthK, PresetID.night.defaultValues.warmthK)
        XCTAssertEqual(state.brightness, PresetID.night.defaultValues.brightness)
    }

    func test_sunsetToSunrise_midRamp_writesAnInterpolatedValue() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 12, 0))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)

        clock.current = date(2026, 9, 8, 22, 40) // 10 of 20 minutes into the bedtime ramp
        coordinator.evaluateNow()

        let evening = PresetID.evening.defaultValues
        let night = PresetID.night.defaultValues
        XCTAssertEqual(state.warmthK, (evening.warmthK + night.warmthK) / 2, accuracy: 5)
        XCTAssertNotEqual(state.warmthK, night.warmthK, "must not have jumped straight to the target")
    }

    // MARK: - Manual override pauses the schedule (ARCHITECTURE.md §3)

    func test_manualSliderMove_pausesTheSchedule_untilTheNextPhaseBoundary() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 23, 0)) // settled into NIGHT already
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()
        XCTAssertEqual(state.warmthK, PresetID.night.defaultValues.warmthK)

        // The user drags the warmth slider by hand.
        state.warmthK = 3000
        XCTAssertNotNil(coordinator.pausedAtPhaseStart, "a manual change must register as an override")

        // Time passes, still within the same NIGHT phase — the schedule
        // must NOT stomp the user's manual value.
        clock.current = date(2026, 9, 9, 2, 0)
        coordinator.evaluateNow()
        XCTAssertEqual(state.warmthK, 3000, "schedule must stay paused inside the phase the user overrode")
    }

    func test_pausedSchedule_resumesAutomatically_onceANewPhaseBegins() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 23, 0))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()

        state.warmthK = 3000 // manual override during NIGHT
        XCTAssertNotNil(coordinator.pausedAtPhaseStart)

        // Cross into tomorrow's sunrise phase — a genuinely new boundary,
        // well past its own ramp so the schedule has settled into "off."
        clock.current = date(2026, 9, 9, 6, 30)
        coordinator.evaluateNow()

        XCTAssertNil(coordinator.pausedAtPhaseStart, "crossing a phase boundary must resume the schedule")
        XCTAssertFalse(state.isOn, "the schedule should be driving again, and sunrise means off")
    }

    // MARK: - isOn: the schedule's own off state (fixes a real product bug)

    // An independent review found that an earlier version never touched
    // `isOn` at all — once a user turned the filter on under a non-manual
    // schedule, nothing could ever turn it back off again, since even the
    // sunrise phase just kept isOn=true at a permanent tint. These pin the
    // fix end-to-end through the real coordinator, not just the pure engine.
    func test_schedule_turnsOffAtSunrise_onceSettled() {
        let state = freshState()
        state.isOn = true
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let sunrise = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: state.scheduleConfig, calendar: calendar)
            .first { $0.preset == .day }!
        let clock = TestClock(sunrise.start.addingTimeInterval(21 * 60)) // past the ramp
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()

        XCTAssertFalse(state.isOn)
        XCTAssertEqual(state.warmthK, Config.maxWarmthK)
    }

    func test_schedule_turnsOnAtSunset() {
        let state = freshState()
        state.isOn = false
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let sunset = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: state.scheduleConfig, calendar: calendar)
            .first { $0.preset == .evening }!
        let clock = TestClock(sunset.start.addingTimeInterval(21 * 60))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()

        XCTAssertTrue(state.isOn)
    }

    // Manually toggling the ON/OFF button is exactly as much of a manual
    // override as dragging a slider — both mean "not what the schedule
    // wanted," and both must pause it the same way.
    func test_manuallyTogglingOnOff_alsoPausesTheSchedule() {
        let state = freshState()
        state.isOn = true
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 23, 0)) // settled into NIGHT (on)
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()
        XCTAssertTrue(state.isOn)

        state.isOn = false // the user presses the ZAP button off, by hand
        XCTAssertNotNil(coordinator.pausedAtPhaseStart, "toggling isOn by hand must register as an override too")

        clock.current = date(2026, 9, 9, 2, 0) // still inside the same NIGHT phase
        coordinator.evaluateNow()
        XCTAssertFalse(state.isOn, "schedule must not turn it back on while paused inside the phase the user overrode")
    }

    func test_settledPreset_reHighlightsInThePopoverPicker_onceARampCompletes() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let bedtime = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: state.scheduleConfig, calendar: calendar)
            .first { $0.preset == .night }!
        let clock = TestClock(bedtime.start.addingTimeInterval(21 * 60)) // past the ramp, landed exactly on NIGHT
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()

        XCTAssertEqual(state.activePreset, .night, "the popover's segmented picker must not sit permanently blank while the schedule drives it")
    }

    func test_activePreset_staysNil_midRamp() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let bedtime = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: state.scheduleConfig, calendar: calendar)
            .first { $0.preset == .night }!
        let clock = TestClock(bedtime.start.addingTimeInterval(10 * 60)) // mid-ramp
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()

        XCTAssertNil(state.activePreset, "no preset is 'active' while interpolated values match none of them")
    }

    // The coordinator's own writes must never be mistaken for a manual
    // override — otherwise the schedule would immediately pause itself on
    // every single tick it ever performs.
    func test_theCoordinatorsOwnWrites_doNotTriggerAPause() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 23, 0))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)

        coordinator.evaluateNow() // the schedule itself writes warmthK/brightness here
        XCTAssertNil(coordinator.pausedAtPhaseStart, "the schedule's own write must not look like a user override")
    }

    // MARK: - Live mode switch (the most severe finding of the C5 review)

    // `@Published` fires from `willSet`, before the new value is actually
    // stored. `handleConfigChanged()` reads `appState.scheduleConfig`
    // itself rather than the value the publisher carried, so without
    // `.receive(on: .main)` deferring that read to the next run-loop turn,
    // it would observe the *previous* config — the exact bug class
    // `DisplayCoordinator` already had to fix for itself (see its own doc
    // comment). An independent review reproduced this directly: switching
    // live from Manual to Sunset->Sunrise silently did nothing until a
    // second, unrelated config change happened to also fire the
    // subscription. This test drives the coordinator the same way the
    // real Settings UI does — one live mutation of `appState.scheduleConfig`
    // after construction, with no follow-up change and no direct
    // `evaluateNow()` call — specifically so it cannot pass by accident the
    // way every other test in this file (which set `scheduleConfig` before
    // constructing the coordinator) does.
    func test_switchingLiveFromManualToSunsetToSunrise_engagesImmediately() {
        let state = freshState() // starts in the default .manual mode
        let clock = TestClock(date(2026, 9, 8, 23, 0)) // well past today's bedtime
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        withExtendedLifetime(coordinator) {}

        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20) // the one live mutation
        flushMainQueue()

        XCTAssertEqual(state.warmthK, PresetID.night.defaultValues.warmthK, "the schedule must engage from this one change alone")
    }

    // MARK: - Config changes

    func test_changingScheduleConfig_clearsAnExistingPause() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 23, 0))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()
        state.warmthK = 3000
        XCTAssertNotNil(coordinator.pausedAtPhaseStart)

        state.scheduleConfig.rampMinutes = 30 // any config change
        flushMainQueue()

        XCTAssertNil(coordinator.pausedAtPhaseStart, "a deliberate config change should not leave a stale pause behind")
    }

    func test_switchingToManualMode_stopsWritingEvenIfPreviouslyActive() {
        let state = freshState()
        state.scheduleConfig = sunsetToSunriseConfig(rampMinutes: 20)
        let clock = TestClock(date(2026, 9, 8, 23, 0))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        coordinator.evaluateNow()
        XCTAssertEqual(state.warmthK, PresetID.night.defaultValues.warmthK)

        state.scheduleConfig.mode = .manual
        state.warmthK = 5000 // now a perfectly normal manual change
        clock.current = date(2026, 9, 9, 6, 30) // would have been a new phase, if schedule were active
        coordinator.evaluateNow()

        XCTAssertEqual(state.warmthK, 5000, "manual mode must leave whatever the user set alone")
    }

    func test_bellCurve_keepsDimmingEnabled_andResumesManualOverrideAtPeak() {
        let state = freshState()
        var config = ScheduleConfig.defaults
        config.mode = .bellCurve
        config.fixedDayStart = TimeOfDay(hour: 6, minute: 0)
        config.peakTime = TimeOfDay(hour: 12, minute: 0)
        config.bedtime = TimeOfDay(hour: 22, minute: 0)
        config.lowBrightness = 0.2
        config.peakBrightness = 0.8
        state.scheduleConfig = config
        let clock = TestClock(date(2026, 9, 8, 6))
        let coordinator = ScheduleCoordinator(appState: state, calendar: { self.calendar }, now: clock.now)
        defer { coordinator.stop() }
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.brightness, 0.2, accuracy: 0.000001)
        clock.current = date(2026, 9, 8, 9)
        coordinator.evaluateNow()
        XCTAssertEqual(state.brightness, 0.5, accuracy: 0.000001)
        state.brightness = 0.3
        clock.current = date(2026, 9, 8, 10)
        coordinator.evaluateNow()
        XCTAssertEqual(state.brightness, 0.3, accuracy: 0.000001)
        clock.current = date(2026, 9, 8, 12)
        coordinator.evaluateNow()
        XCTAssertTrue(state.isOn)
        XCTAssertEqual(state.brightness, 0.8, accuracy: 0.000001)
        XCTAssertNil(coordinator.pausedAtPhaseStart)
    }

}
