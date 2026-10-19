import XCTest
@testable import Dimit

final class ScheduleEngineTests: XCTestCase {
    private let tashkent = Coordinate(latitude: 41.2995, longitude: 69.2401)
    private var tz: TimeZone { TimeZone(identifier: "Asia/Tashkent")! }
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
        return calendar.date(from: c)!
    }

    private struct HourMinute: Equatable, CustomStringConvertible {
        let hour: Int
        let minute: Int
        var description: String { String(format: "%02d:%02d", hour, minute) }
    }
    private func hm(_ d: Date) -> HourMinute {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        return HourMinute(hour: c.hour!, minute: c.minute!)
    }

    private func values(for preset: PresetID) -> PresetValues { preset.defaultValues }

    private func sunsetToSunriseConfig(rampMinutes: Int = 20) -> ScheduleConfig {
        var c = ScheduleConfig.defaults
        c.mode = .sunsetToSunrise
        c.location = tashkent
        c.rampMinutes = rampMinutes
        c.bedtime = TimeOfDay(hour: 22, minute: 30)
        return c
    }

    // MARK: - phases(for:)

    func test_manualMode_hasNoPhases() {
        let config = ScheduleConfig.defaults // .manual
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .manual, config: config, calendar: calendar)
        XCTAssertTrue(phases.isEmpty)
    }

    func test_sunsetToSunrise_withNoLocationConfigured_hasNoPhases() {
        var config = ScheduleConfig.defaults
        config.mode = .sunsetToSunrise
        config.location = nil
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        XCTAssertTrue(phases.isEmpty, "no location means nothing to compute — must not crash or guess")
    }

    // CLAUDE.md §3.8: "linear ramp ... from DAY preset to EVENING at sunset
    // and to NIGHT at bedtime." Plus a third, implied by the mode's own name
    // "Sunset->Sunrise": back to DAY at sunrise. Documented here since
    // CLAUDE.md's prose only spells out two of the three transitions.
    func test_sunsetToSunrise_producesThreePhases_atSunrise_sunset_andBedtime() {
        let config = sunsetToSunriseConfig()
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        XCTAssertEqual(phases.count, 3)

        let sunrisePhase = phases.first { $0.preset == .day }
        let sunsetPhase = phases.first { $0.preset == .evening }
        let bedtimePhase = phases.first { $0.preset == .night }
        XCTAssertNotNil(sunrisePhase); XCTAssertNotNil(sunsetPhase); XCTAssertNotNil(bedtimePhase)

        // Cross-check against SolarCalculatorTests' own verified Tashkent reference.
        XCTAssertEqual(hm(sunrisePhase!.start).hour, 5)
        XCTAssertEqual(hm(sunsetPhase!.start).hour, 18)
        XCTAssertEqual(hm(bedtimePhase!.start), HourMinute(hour: 22, minute: 30))
        XCTAssertEqual(sunrisePhase!.rampMinutes, 20)
    }

    func test_fixedTimes_usesConfiguredClockTimes_notSolarComputation() {
        var config = ScheduleConfig.defaults
        config.mode = .fixedTimes
        config.fixedDayStart = TimeOfDay(hour: 7, minute: 0)
        config.fixedEveningStart = TimeOfDay(hour: 19, minute: 30)
        config.bedtime = TimeOfDay(hour: 23, minute: 0)

        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .fixedTimes, config: config, calendar: calendar)
        XCTAssertEqual(phases.count, 3)
        XCTAssertEqual(hm(phases.first { $0.preset == .day }!.start), HourMinute(hour: 7, minute: 0))
        XCTAssertEqual(hm(phases.first { $0.preset == .evening }!.start), HourMinute(hour: 19, minute: 30))
        XCTAssertEqual(hm(phases.first { $0.preset == .night }!.start), HourMinute(hour: 23, minute: 0))
    }

    func test_fixedTimes_ignoresLocation_evenIfSomehowSet() {
        var config = ScheduleConfig.defaults
        config.mode = .fixedTimes
        config.location = tashkent // should simply be irrelevant to this mode
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .fixedTimes, config: config, calendar: calendar)
        XCTAssertEqual(phases.count, 3, "fixed mode must not silently fail just because a location happens to be set")
    }

    // MARK: - target(at:phases:values:)

    func test_target_beforeAnyPhaseInTheWindow_returnsNil_soCallerLeavesStateAlone() {
        // No phases at all (manual mode) is the simplest way to hit "no
        // active phase" without constructing a contrived pre-dawn instant.
        let result = ScheduleEngine.target(at: date(2026, 9, 8, 3, 0), phases: [], values: values)
        XCTAssertNil(result)
    }

    func test_target_wellAfterAPhaseStarts_returnsThatPresetsExactValues_andReportsItSettled() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        // Bedtime is 22:30; 22:31 is one minute in, well past a 20-min ramp is NOT true yet —
        // use a time well past the ramp's end instead.
        let target = try! XCTUnwrap(ScheduleEngine.target(at: date(2026, 9, 8, 23, 0), phases: phases, values: values))
        XCTAssertEqual(target.warmthK, PresetID.night.defaultValues.warmthK)
        XCTAssertEqual(target.brightness, PresetID.night.defaultValues.brightness)
        XCTAssertTrue(target.isOn)
        XCTAssertEqual(target.settledPreset, .night)
    }

    func test_target_duringARamp_interpolatesLinearly_andReportsNoSettledPreset() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        let bedtimePhase = phases.first { $0.preset == .night }!

        let midRamp = bedtimePhase.start.addingTimeInterval(10 * 60) // 10 of 20 minutes in
        let target = try! XCTUnwrap(ScheduleEngine.target(at: midRamp, phases: phases, values: values))

        let evening = PresetID.evening.defaultValues
        let night = PresetID.night.defaultValues
        XCTAssertEqual(target.warmthK, (evening.warmthK + night.warmthK) / 2, accuracy: 1.0)
        XCTAssertEqual(target.brightness, (evening.brightness + night.brightness) / 2, accuracy: 0.01)
        XCTAssertTrue(target.isOn)
        XCTAssertNil(target.settledPreset, "no single preset is 'active' mid-interpolation")
    }

    func test_target_atTheExactStartOfARamp_equalsThePreviousPhasesValues() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        let bedtimePhase = phases.first { $0.preset == .night }!
        let target = try! XCTUnwrap(ScheduleEngine.target(at: bedtimePhase.start, phases: phases, values: values))
        XCTAssertEqual(target.warmthK, PresetID.evening.defaultValues.warmthK, "at t=0 of the ramp, nothing has changed yet")
        XCTAssertEqual(target.brightness, PresetID.evening.defaultValues.brightness)
    }

    func test_target_zeroRampMinutes_jumpsInstantlyRatherThanDivideByZero() {
        let config = sunsetToSunriseConfig(rampMinutes: 0)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        let bedtimePhase = phases.first { $0.preset == .night }!
        let target = try! XCTUnwrap(ScheduleEngine.target(at: bedtimePhase.start, phases: phases, values: values))
        XCTAssertEqual(target.warmthK, PresetID.night.defaultValues.warmthK)
        XCTAssertEqual(target.brightness, PresetID.night.defaultValues.brightness)
    }

    // The whole reason `target` takes a `values` closure instead of reading
    // `PresetID.defaultValues` itself: a user who has customized EVENING in
    // Settings (C4) must get their own EVENING from the schedule, not the
    // factory default. An earlier review of C4 flagged `PresetID.warmthK`/
    // `.brightness` as exactly this footgun for whichever cycle built
    // scheduling — this test is the guard against reintroducing it.
    func test_target_usesInjectedValues_notHardcodedDefaults() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        let customEvening = PresetValues(warmthK: 3300, brightness: 0.65)
        let customValues: (PresetID) -> PresetValues = { preset in
            preset == .evening ? customEvening : preset.defaultValues
        }
        let sunsetPhase = phases.first { $0.preset == .evening }!
        let target = try! XCTUnwrap(ScheduleEngine.target(
            at: sunsetPhase.start.addingTimeInterval(21 * 60), // past the 20-min ramp
            phases: phases, values: customValues
        ))
        XCTAssertEqual(target.warmthK, customEvening.warmthK)
        XCTAssertEqual(target.brightness, customEvening.brightness)
    }

    // MARK: - isOn: the schedule's own "off" state (fixes a real product bug)

    // An earlier version had every mode return only warmth/brightness,
    // leaving ON/OFF entirely to the user. An independent review found the
    // real consequence: once turned on, a non-manual schedule could never
    // reach anything that looked like "off" again — even its sunrise
    // transition just kept isOn=true at DAY preset's 4000K forever. These
    // pin the fix: the schedule's own "day" phase now means genuinely off.
    func test_target_atTheDayPhase_settledMeansOff_notThePresetDayValues() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        let sunrisePhase = phases.first { $0.preset == .day }!
        let target = try! XCTUnwrap(ScheduleEngine.target(at: sunrisePhase.start.addingTimeInterval(21 * 60), phases: phases, values: values))

        XCTAssertFalse(target.isOn, "the schedule's own day phase must be able to turn the filter off")
        XCTAssertEqual(target.warmthK, Config.maxWarmthK, "neutral, not PresetID.day's own 4000K")
        XCTAssertEqual(target.brightness, Config.maxBrightness)
        XCTAssertNil(target.settledPreset, "no preset is 'active' while off")
    }

    func test_target_rampingIntoTheDayPhase_staysOnUntilTheRampCompletes() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        let sunrisePhase = phases.first { $0.preset == .day }!

        let midRamp = try! XCTUnwrap(ScheduleEngine.target(at: sunrisePhase.start.addingTimeInterval(10 * 60), phases: phases, values: values))
        XCTAssertTrue(midRamp.isOn, "fading out is still visibly tinted for most of the ramp")

        let afterRamp = try! XCTUnwrap(ScheduleEngine.target(at: sunrisePhase.start.addingTimeInterval(21 * 60), phases: phases, values: values))
        XCTAssertFalse(afterRamp.isOn)
    }

    func test_target_eveningAndNightPhases_areOn() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(for: date(2026, 9, 8), mode: .sunsetToSunrise, config: config, calendar: calendar)
        for preset in [PresetID.evening, .night] {
            let phase = phases.first { $0.preset == preset }!
            let target = try! XCTUnwrap(ScheduleEngine.target(at: phase.start.addingTimeInterval(21 * 60), phases: phases, values: values))
            XCTAssertTrue(target.isOn, "\(preset) must be on once settled")
        }
    }

    // MARK: - Phase ordering (an independent review's line-by-line pass)

    // London, midsummer: sunset ≈21:19, well past an ordinary 21:00
    // bedtime. Before the fix, comparing raw start times let EVENING
    // (21:19) permanently outrank a NIGHT phase that had already begun 19
    // minutes earlier, for the rest of the night.
    func test_bedtimeEarlierThanSunset_stillLetsNightWin_onceBothHaveStarted() {
        var config = ScheduleConfig.defaults
        config.mode = .sunsetToSunrise
        config.location = try! XCTUnwrap(CityList.city(id: "london")).coordinate
        config.bedtime = TimeOfDay(hour: 21, minute: 0)
        config.rampMinutes = 20

        let london = TimeZone(identifier: "Europe/London")!
        var londonCalendar = Calendar(identifier: .gregorian)
        londonCalendar.timeZone = london
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 21; c.timeZone = london
        let midsummer = londonCalendar.date(from: c)!

        let phases = ScheduleEngine.phases(for: midsummer, mode: .sunsetToSunrise, config: config, calendar: londonCalendar)
        let evening = phases.first { $0.preset == .evening }!
        let night = phases.first { $0.preset == .night }!
        XCTAssertGreaterThan(night.start, evening.start, "night's actual (possibly nudged) start must sort after evening's")

        let target = try! XCTUnwrap(ScheduleEngine.target(
            at: evening.start.addingTimeInterval(60 * 60), phases: phases, values: values
        ))
        XCTAssertEqual(target.warmthK, PresetID.night.defaultValues.warmthK, "well after both, NIGHT must win, not EVENING")
    }

    // Tromsø, above the Arctic Circle, on a day the sun rises again after
    // polar night: yesterday contributes zero phases, so the 2-day merge
    // collapses to just today's 3, and sunrise lands at index 0 with no
    // earlier phase to ramp from.
    func test_firstSunriseAfterPolarNight_ramps_ratherThanCollapsing() throws {
        var config = ScheduleConfig.defaults
        config.mode = .sunsetToSunrise
        config.location = Coordinate(latitude: 69.6, longitude: 18.9)
        config.rampMinutes = 20

        let tz = TimeZone(identifier: "Europe/Oslo")!
        var tromsoCalendar = Calendar(identifier: .gregorian)
        tromsoCalendar.timeZone = tz
        var c = DateComponents(); c.year = 2026; c.month = 1; c.day = 21; c.timeZone = tz // near the first post-polar-night sunrise
        let day = tromsoCalendar.date(from: c)!

        let phases = ScheduleEngine.phases(for: day, mode: .sunsetToSunrise, config: config, calendar: tromsoCalendar)
        guard let sunrise = phases.first(where: { $0.preset == .day }) else {
            throw XCTSkip("sun did not rise on the chosen date; adjust the fixture day")
        }
        let midRamp = try! XCTUnwrap(ScheduleEngine.target(
            at: sunrise.start.addingTimeInterval(10 * 60), phases: phases, values: values
        ))
        // With no earlier phase, the "previous" state is defined as
        // already-off/neutral — so this specific degenerate case is a flat
        // neutral ramp (a real fade needs a real starting point to fade
        // from), not the wrong-value jump the original bug produced. The
        // one thing that must never happen is landing on some OTHER
        // preset's values by accident.
        XCTAssertEqual(midRamp.warmthK, Config.maxWarmthK)
        XCTAssertEqual(midRamp.brightness, Config.maxBrightness)
    }

    // MARK: - Day-boundary wraparound (the reason phases cover 2 days)

    func test_phasesCoveringDayOf_mergesYesterdayAndToday_soPastMidnightStillFindsLastNightsPhase() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let justAfterMidnight = date(2026, 9, 9, 0, 30) // between yesterday's bedtime and today's sunrise
        let phases = ScheduleEngine.phases(coveringDayOf: justAfterMidnight, mode: .sunsetToSunrise, config: config, calendar: calendar)
        let target = try! XCTUnwrap(ScheduleEngine.target(at: justAfterMidnight, phases: phases, values: values))
        XCTAssertEqual(target.warmthK, PresetID.night.defaultValues.warmthK, "00:30 is well after yesterday's 22:30 bedtime and well before today's ~05:56 sunrise")
        XCTAssertTrue(target.isOn)
    }

    func test_phasesCoveringDayOf_atSunrise_turnsOff() {
        let config = sunsetToSunriseConfig(rampMinutes: 20)
        let phases = ScheduleEngine.phases(coveringDayOf: date(2026, 9, 8, 12, 0), mode: .sunsetToSunrise, config: config, calendar: calendar)
        let midMorning = date(2026, 9, 8, 8, 0) // well after sunrise (~05:56), well before sunset
        let target = try! XCTUnwrap(ScheduleEngine.target(at: midMorning, phases: phases, values: values))
        XCTAssertFalse(target.isOn)
        XCTAssertEqual(target.warmthK, Config.maxWarmthK)
    }

    private func bellConfig() -> ScheduleConfig {
        var config = ScheduleConfig.defaults
        config.mode = .bellCurve
        config.fixedDayStart = TimeOfDay(hour: 6, minute: 0)
        config.peakTime = TimeOfDay(hour: 12, minute: 0)
        config.bedtime = TimeOfDay(hour: 22, minute: 0)
        config.lowBrightness = 0.2
        config.peakBrightness = 0.8
        return config
    }

    private func bellTarget(_ now: Date, config: ScheduleConfig) throws -> ScheduleEngine.Resolution {
        let phases = ScheduleEngine.phases(coveringDayOf: now, mode: .bellCurve, config: config, calendar: calendar)
        return try XCTUnwrap(ScheduleEngine.target(at: now, phases: phases, values: values))
    }

    func test_bellCurve_startsDim_peaksAtChosenBrightness_andHoldsDimOvernight() throws {
        let config = bellConfig()
        for hour in [0, 5, 6, 22, 23] {
            let target = try bellTarget(date(2026, 9, 8, hour), config: config)
            XCTAssertEqual(target.brightness, 0.2, accuracy: 0.000001)
            XCTAssertTrue(target.isOn, "dimming must stay active, including at the daytime peak")
            XCTAssertNil(target.settledPreset, "curve values must not claim to be a preset")
        }
        let peak = try bellTarget(date(2026, 9, 8, 12), config: config)
        XCTAssertEqual(peak.brightness, 0.8, accuracy: 0.000001)
        XCTAssertEqual(peak.warmthK, Config.maxWarmthK)
        XCTAssertTrue(peak.isOn)
        XCTAssertEqual(try bellTarget(date(2026, 9, 8, 9), config: config).brightness, 0.5, accuracy: 0.000001)
        XCTAssertEqual(try bellTarget(date(2026, 9, 8, 17), config: config).brightness, 0.5, accuracy: 0.000001)
    }

    func test_bellCurve_easesAtBoundaries_andNeverJumpsOrExceedsItsRange() throws {
        let config = bellConfig()
        var last = try bellTarget(date(2026, 9, 8), config: config).brightness
        for minute in 1...1440 {
            let now = date(2026, 9, 8).addingTimeInterval(Double(minute) * 60)
            let current = try bellTarget(now, config: config).brightness
            XCTAssertTrue((0.2...0.8).contains(current))
            XCTAssertLessThan(abs(current - last), 0.003)
            if minute > 360 && minute <= 720 { XCTAssertGreaterThanOrEqual(current, last) }
            if minute > 720 && minute <= 1320 { XCTAssertLessThanOrEqual(current, last) }
            last = current
        }
        let firstMinute = try bellTarget(date(2026, 9, 8, 6, 1), config: config).brightness
        XCTAssertLessThan(firstMinute - 0.2, 0.00002, "ease in gently instead of a linear start")
    }

    func test_bellCurve_supportsBedtimeAndPeakAfterMidnight() throws {
        var config = bellConfig()
        config.fixedDayStart = TimeOfDay(hour: 18, minute: 0)
        config.peakTime = TimeOfDay(hour: 0, minute: 0)
        config.bedtime = TimeOfDay(hour: 6, minute: 0)
        XCTAssertEqual(try bellTarget(date(2026, 9, 9, 0), config: config).brightness, 0.8, accuracy: 0.000001)
        XCTAssertEqual(try bellTarget(date(2026, 9, 9, 3), config: config).brightness, 0.5, accuracy: 0.000001)
        XCTAssertEqual(try bellTarget(date(2026, 9, 9, 12), config: config).brightness, 0.2, accuracy: 0.000001)
    }

    func test_bellCurve_invalidPeakHasNoTarget_andBrightnessIsClamped() throws {
        var config = bellConfig()
        config.peakTime = config.bedtime
        XCTAssertTrue(ScheduleEngine.phases(for: date(2026, 9, 8), mode: .bellCurve, config: config, calendar: calendar).isEmpty)
        config.bedtime = config.fixedDayStart
        XCTAssertNil(ScheduleEngine.bellTimes(on: date(2026, 9, 8), config: config, calendar: calendar))
        config.bedtime = TimeOfDay(hour: 22, minute: 0)
        config.peakTime = TimeOfDay(hour: 12, minute: 0)
        config.lowBrightness = -1
        config.peakBrightness = 2
        XCTAssertEqual(try bellTarget(date(2026, 9, 8, 6), config: config).brightness, Config.minBrightness)
        XCTAssertEqual(try bellTarget(date(2026, 9, 8, 12), config: config).brightness, Config.maxBrightness)
    }

    func test_bellCurve_usesCustomizedNightWarmth() throws {
        let config = bellConfig()
        let now = date(2026, 9, 8, 9)
        let phases = ScheduleEngine.phases(coveringDayOf: now, mode: .bellCurve, config: config, calendar: calendar)
        let target = try XCTUnwrap(ScheduleEngine.target(at: now, phases: phases) { _ in
            PresetValues(warmthK: 1500, brightness: 0.7)
        })
        XCTAssertEqual(target.warmthK, 4000, accuracy: 0.000001)
        XCTAssertEqual(target.brightness, 0.5, accuracy: 0.000001)
    }

    func test_bellCurve_configRoundTrips_andOldSchedulesKeepTheirValues() throws {
        let original = bellConfig()
        XCTAssertEqual(try JSONDecoder().decode(ScheduleConfig.self, from: JSONEncoder().encode(original)), original)
        let oldJSON = Data(#"{"mode":"fixedTimes","rampMinutes":45,"fixedDayStart":{"hour":8,"minute":15}}"#.utf8)
        let old = try JSONDecoder().decode(ScheduleConfig.self, from: oldJSON)
        XCTAssertEqual(old.mode, .fixedTimes)
        XCTAssertEqual(old.rampMinutes, 45)
        XCTAssertEqual(old.fixedDayStart, TimeOfDay(hour: 8, minute: 15))
        XCTAssertEqual(old.peakTime, ScheduleConfig.defaults.peakTime)
        XCTAssertEqual(old.lowBrightness, ScheduleConfig.defaults.lowBrightness)
        XCTAssertEqual(old.peakBrightness, ScheduleConfig.defaults.peakBrightness)
    }


    func test_bellCurve_overnightSchedule_remainsContinuousAcrossDaylightSavingChanges() throws {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        var config = bellConfig()
        config.fixedDayStart = TimeOfDay(hour: 18, minute: 0)
        config.peakTime = TimeOfDay(hour: 0, minute: 0)
        config.bedtime = TimeOfDay(hour: 6, minute: 0)
        for (month, day) in [(3, 8), (11, 1)] {
            let midnight = try XCTUnwrap(localCalendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            var previous = 0.8
            let bed = try XCTUnwrap(localCalendar.date(bySettingHour: 6, minute: 0, second: 0, of: midnight))
            for offset in stride(from: 0.0, through: bed.timeIntervalSince(midnight), by: 60) {
                let now = midnight.addingTimeInterval(offset)
                let phases = ScheduleEngine.phases(coveringDayOf: now, mode: .bellCurve, config: config, calendar: localCalendar)
                let target = try XCTUnwrap(ScheduleEngine.target(at: now, phases: phases, values: values))
                XCTAssertLessThanOrEqual(target.brightness, previous + 0.000001)
                XCTAssertLessThan(abs(target.brightness - previous), 0.004)
                previous = target.brightness
            }
            XCTAssertEqual(previous, 0.2, accuracy: 0.000001)
        }
    }

}
