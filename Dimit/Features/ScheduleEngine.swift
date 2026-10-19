import Foundation

/// Automatic preset schedules plus an optional, continuous daily bell curve.
enum ScheduleMode: String, Codable, CaseIterable {
    case manual
    case sunsetToSunrise
    case fixedTimes
    case bellCurve
}

/// A wall-clock time, timezone-agnostic — interpreted against whatever
/// `Calendar` the caller supplies (always the user's own local calendar in
/// practice, since "bedtime" only makes sense as *their* clock time).
struct TimeOfDay: Codable, Equatable {
    var hour: Int
    var minute: Int

    static let defaultBedtime = TimeOfDay(hour: 22, minute: 30)

    init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Same `decodeIfPresent`-per-field reasoning as `ScheduleConfig`'s own
    /// decoder just below. Two fields today, but "this type is small and
    /// won't grow" is exactly the assumption that was wrong twice already
    /// in this codebase (`fallbackMode`, then three more C4 fields) — the
    /// custom decoder is cheap enough that there's no reason to bet against
    /// it a third time.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? TimeOfDay.defaultBedtime.hour
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? TimeOfDay.defaultBedtime.minute
    }
}

/// Everything the schedule needs to know, persisted as one unit.
/// `location` is deliberately optional and separate from `selectedCityID`:
/// the coordinate is what the math needs, the city id is only so Settings
/// can show which bundled city (if any) produced it, and "manual lat/lon"
/// (CLAUDE.md §3.8) or a CoreLocation fix both set `location` with no city
/// id at all.
struct ScheduleConfig: Codable, Equatable {
    var mode: ScheduleMode
    var location: Coordinate?
    var selectedCityID: String?
    var bedtime: TimeOfDay
    var fixedDayStart: TimeOfDay
    var fixedEveningStart: TimeOfDay
    /// CLAUDE.md §3.8: "linear ramp over a user-set duration (default 20 min)."
    var rampMinutes: Int
    var peakTime: TimeOfDay = TimeOfDay(hour: 13, minute: 0)
    var lowBrightness: Double = 0.4
    var peakBrightness: Double = 1.0

    static let defaults = ScheduleConfig(
        mode: .manual,
        location: nil,
        selectedCityID: nil,
        bedtime: .defaultBedtime,
        fixedDayStart: TimeOfDay(hour: 7, minute: 0),
        fixedEveningStart: TimeOfDay(hour: 18, minute: 0),
        rampMinutes: 20
    )

    init(
        mode: ScheduleMode, location: Coordinate?, selectedCityID: String?,
        bedtime: TimeOfDay, fixedDayStart: TimeOfDay, fixedEveningStart: TimeOfDay, rampMinutes: Int
    ) {
        self.mode = mode
        self.location = location
        self.selectedCityID = selectedCityID
        self.bedtime = bedtime
        self.fixedDayStart = fixedDayStart
        self.fixedEveningStart = fixedEveningStart
        self.rampMinutes = rampMinutes
    }

    /// A hand-written decoder for the same reason `PersistedState` has one
    /// (see that type's doc comment): Swift's synthesized `Decodable`
    /// throws `keyNotFound` for a missing key regardless of a declared
    /// default, and `Persistence`'s outer `decodeIfPresent(ScheduleConfig
    /// .self, forKey:)` only protects against the *key itself* being
    /// absent — it does nothing once decoding has started and a field
    /// *inside* this struct turns out to be missing. Without this,
    /// whichever future cycle adds a field here (a schedule feature is
    /// likely to grow one) reintroduces exactly the "one new key wipes
    /// every existing user's entire saved state" bug this codebase has
    /// already hit and fixed twice (`fallbackMode` in C3, C4's trio).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Self.defaults
        mode = try container.decodeIfPresent(ScheduleMode.self, forKey: .mode) ?? fallback.mode
        location = try container.decodeIfPresent(Coordinate.self, forKey: .location)
        selectedCityID = try container.decodeIfPresent(String.self, forKey: .selectedCityID)
        bedtime = try container.decodeIfPresent(TimeOfDay.self, forKey: .bedtime) ?? fallback.bedtime
        fixedDayStart = try container.decodeIfPresent(TimeOfDay.self, forKey: .fixedDayStart) ?? fallback.fixedDayStart
        fixedEveningStart = try container.decodeIfPresent(TimeOfDay.self, forKey: .fixedEveningStart) ?? fallback.fixedEveningStart
        rampMinutes = try container.decodeIfPresent(Int.self, forKey: .rampMinutes) ?? fallback.rampMinutes
        peakTime = try container.decodeIfPresent(TimeOfDay.self, forKey: .peakTime) ?? fallback.peakTime
        lowBrightness = try container.decodeIfPresent(Double.self, forKey: .lowBrightness) ?? fallback.lowBrightness
        peakBrightness = try container.decodeIfPresent(Double.self, forKey: .peakBrightness) ?? fallback.peakBrightness
    }
}

/// One anchor point in a day's schedule: "starting at `start`, ramp toward
/// `preset` over `rampMinutes`." ARCHITECTURE.md §3's sketch.
struct SchedulePhase: Equatable {
    let preset: PresetID
    let start: Date
    let rampMinutes: Int
    var brightnessOverride: Double? = nil
    var smoothRamp: Bool = false
}

/// A pure function over time, plus the small amount of state
/// (`ScheduleConfig`) that shapes it — ARCHITECTURE.md §3. No I/O, no
/// timers, no CoreLocation: those live in `ScheduleCoordinator`, which
/// calls this and nothing else calls the sun/clock APIs directly.
enum ScheduleEngine {
    /// The day's phases, anchored to `day`'s own date (sunrise/sunset are
    /// computed for that specific calendar day). Empty for `.manual`, and
    /// empty for `.sunsetToSunrise` with no location configured yet or with
    /// a location where the sun doesn't rise/set that day (polar day/night)
    /// — never a guess in either case.
    static func phases(for day: Date, mode: ScheduleMode, config: ScheduleConfig, calendar: Calendar) -> [SchedulePhase] {
        switch mode {
        case .manual:
            return []

        case .bellCurve:
            guard let times = bellTimes(on: day, config: config, calendar: calendar) else { return [] }
            let low = config.lowBrightness.clamped(to: Config.minBrightness...Config.maxBrightness)
            let peak = config.peakBrightness.clamped(to: low...Config.maxBrightness)
            // Each half of the curve is a cosine fade, with zero slope at
            // wake-up, peak and bedtime. Hold the low value overnight.
            return [
                SchedulePhase(preset: .day, start: times.wake,
                              rampMinutes: Int(times.peak.timeIntervalSince(times.wake) / 60),
                              brightnessOverride: peak, smoothRamp: true),
                SchedulePhase(preset: .night, start: times.peak,
                              rampMinutes: Int(times.bed.timeIntervalSince(times.peak) / 60),
                              brightnessOverride: low, smoothRamp: true),
                SchedulePhase(preset: .night, start: times.bed, rampMinutes: 0,
                              brightnessOverride: low, smoothRamp: true),
            ]

        case .sunsetToSunrise:
            guard let location = config.location,
                  let sunrise = SolarCalculator.sunrise(for: day, at: location, timeZone: calendar.timeZone),
                  let sunset = SolarCalculator.sunset(for: day, at: location, timeZone: calendar.timeZone)
            else { return [] }
            // The mode's own name promises a full cycle: warm from sunset,
            // back to neutral at sunrise. CLAUDE.md §3.8's prose spells out
            // only the sunset->EVENING and bedtime->NIGHT transitions
            // explicitly; the sunrise->DAY transition is this cycle's
            // reading of what "Sunset->Sunrise" as a mode name implies,
            // documented here since the source doc doesn't spell it out.
            return chronological([
                SchedulePhase(preset: .day, start: sunrise, rampMinutes: config.rampMinutes),
                SchedulePhase(preset: .evening, start: sunset, rampMinutes: config.rampMinutes),
                SchedulePhase(preset: .night, start: clockTime(config.bedtime, on: day, calendar: calendar), rampMinutes: config.rampMinutes),
            ])

        case .fixedTimes:
            return chronological([
                SchedulePhase(preset: .day, start: clockTime(config.fixedDayStart, on: day, calendar: calendar), rampMinutes: config.rampMinutes),
                SchedulePhase(preset: .evening, start: clockTime(config.fixedEveningStart, on: day, calendar: calendar), rampMinutes: config.rampMinutes),
                SchedulePhase(preset: .night, start: clockTime(config.bedtime, on: day, calendar: calendar), rampMinutes: config.rampMinutes),
            ])
        }
    }

    /// Resolve clock times relative to wake-up, including schedules whose
    /// bedtime (or peak) falls after midnight. Invalid ordering has no target.
    static func bellTimes(on day: Date, config: ScheduleConfig, calendar: Calendar) -> (wake: Date, peak: Date, bed: Date)? {
        guard config.bedtime != config.fixedDayStart else { return nil }
        let wake = clockTime(config.fixedDayStart, on: day, calendar: calendar)
        func followingWake(_ time: TimeOfDay) -> Date {
            let sameDay = clockTime(time, on: day, calendar: calendar)
            guard sameDay <= wake else { return sameDay }
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            return clockTime(time, on: nextDay, calendar: calendar)
        }
        let peak = followingWake(config.peakTime)
        let bed = followingWake(config.bedtime)
        guard wake < peak, peak < bed else { return nil }
        return (wake, peak, bed)
    }

    /// Enforces `day.start < evening.start < night.start`, nudging a
    /// later phase forward by one second past the one before it wherever
    /// the caller's configured times (or, for `.sunsetToSunrise`, a
    /// bedtime set earlier than sunset) would otherwise put them out of
    /// order. `phases`/`target` pick the active phase by comparing raw
    /// start times, so an inverted pair silently breaks the whole
    /// day→evening→night progression rather than merely looking odd — an
    /// independent review found exactly this with a real, unremarkable
    /// configuration: a 21:00 bedtime at a high-latitude city where
    /// midsummer sunset falls at 21:19. From 21:19 onward, EVENING (the
    /// later raw start time) silently and permanently outranked the NIGHT
    /// phase that had already begun 19 minutes earlier, for the rest of
    /// the night. Callers always pass phases already in [day, evening,
    /// night] order, matching how the two call sites above construct them.
    private static func chronological(_ phases: [SchedulePhase]) -> [SchedulePhase] {
        var result: [SchedulePhase] = []
        var minimumStart: Date?
        for phase in phases {
            var start = phase.start
            if let minimumStart, start <= minimumStart {
                start = minimumStart.addingTimeInterval(1)
            }
            result.append(SchedulePhase(preset: phase.preset, start: start, rampMinutes: phase.rampMinutes))
            minimumStart = start
        }
        return result
    }

    /// `phases(for:)` for one calendar day, merged with the day before it
    /// and sorted — what a caller actually wants for evaluating "now,"
    /// since a query shortly after midnight needs to see last night's
    /// bedtime phase (started before midnight) rather than finding nothing
    /// until today's own first phase begins. Two days is always enough:
    /// every phase's ramp completes within hours, never past a second
    /// midnight.
    static func phases(coveringDayOf now: Date, mode: ScheduleMode, config: ScheduleConfig, calendar: Calendar) -> [SchedulePhase] {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return (phases(for: yesterday, mode: mode, config: config, calendar: calendar)
            + phases(for: today, mode: mode, config: config, calendar: calendar))
            .sorted { $0.start < $1.start }
    }

    /// The phase in effect at `now` — the most recent one whose `start` has
    /// already passed. `nil` only if `now` precedes every phase supplied
    /// (or `phases` is empty), which in practice means "the schedule has
    /// nothing to say yet." Shared by `target(at:phases:values:)` and by
    /// `ScheduleCoordinator`, which needs it on its own to detect when a
    /// manual override has been superseded by a new phase boundary.
    static func activePhase(at now: Date, phases: [SchedulePhase]) -> SchedulePhase? {
        phases.sorted { $0.start < $1.start }.last { $0.start <= now }
    }

    /// What the schedule wants applied right now, or `nil` if it has
    /// nothing to say (no phases at all, or `now` precedes every phase in
    /// the supplied list) — the caller's cue to leave `AppState` exactly as
    /// it is rather than snapping to some default.
    struct Resolution: Equatable {
        var isOn: Bool
        var warmthK: Double
        var brightness: Double
        /// The preset these values exactly equal, so the caller can
        /// highlight it (matching what `AppState.apply(preset:)` already
        /// does for a manual tap) — set only once a ramp has fully
        /// completed and landed on a real preset's values; `nil` mid-ramp,
        /// since no single preset is "active" during an interpolation, and
        /// `nil` while `isOn` is false.
        var settledPreset: PresetID?
    }

    /// `values` looks up the *effective* (possibly user-overridden, C4)
    /// values for a preset, never `PresetID.defaultValues` directly: a
    /// user who customized EVENING must get their own EVENING from the
    /// schedule, not the factory one.
    ///
    /// In preset schedules, the `.day` phase is the schedule's own "off": once its ramp
    /// completes, `isOn` is `false` and the values are neutral —
    /// `PresetID.day`'s actual values (4000K/100%, a mild warm daytime
    /// preset, not neutral 6500K) stay reachable only as a manual preset
    /// button, never as what an automatic schedule settles on. An earlier
    /// version had every mode return only warmth/brightness, keeping
    /// ON/OFF as the user's alone; an independent review pointed out the
    /// real consequence: once a user turned the filter on and let a
    /// non-manual schedule run, there was no state it could ever reach
    /// that looked like "off" again, since even its own "back to DAY"
    /// phase left `isOn` untouched at a permanent, unexplained 4000K tint.
    /// A schedule literally named "Sunset→Sunrise" that can never actually
    /// stop at sunrise defeats the one thing its name promises. Bell-curve
    /// phases override brightness and keep dimming enabled even at the peak.
    static func target(at now: Date, phases: [SchedulePhase], values: (PresetID) -> PresetValues) -> Resolution? {
        let sorted = phases.sorted { $0.start < $1.start }
        guard let activeIndex = sorted.lastIndex(where: { $0.start <= now }) else { return nil }

        let active = sorted[activeIndex]
        let isOffPhase = active.preset == .day && active.brightnessOverride == nil
        let targetValues = phaseValues(active, values: values)

        let rampEnd = active.start.addingTimeInterval(Double(active.rampMinutes) * 60)
        if active.rampMinutes <= 0 || now >= rampEnd {
            return Resolution(
                isOn: !isOffPhase,
                warmthK: targetValues.warmthK,
                brightness: targetValues.brightness,
                settledPreset: isOffPhase || active.brightnessOverride != nil ? nil : active.preset
            )
        }

        // Mid-ramp: still "on" regardless of which direction the ramp runs
        // — fading out is still visibly tinted for most of its duration,
        // same as fading in. No earlier phase (activeIndex == 0, only
        // reachable with a deliberately short/synthetic phase list — every
        // real 2-day window this engine generates always starts with an
        // off/.day phase) assumes "off," for the same reason `target`
        // itself treats "nothing configured yet" as off rather than
        // guessing a preset.
        let previousValues: PresetValues = activeIndex > 0
            ? phaseValues(sorted[activeIndex - 1], values: values)
            : PresetValues(warmthK: Config.maxWarmthK, brightness: Config.maxBrightness)
        let duration = rampEnd.timeIntervalSince(active.start)
        let progress = duration > 0 ? (now.timeIntervalSince(active.start) / duration).clamped(to: 0...1) : 1.0
        let fraction = active.smoothRamp ? (1 - cos(.pi * progress)) / 2 : progress

        return Resolution(
            isOn: true,
            warmthK: previousValues.warmthK + (targetValues.warmthK - previousValues.warmthK) * fraction,
            brightness: previousValues.brightness + (targetValues.brightness - previousValues.brightness) * fraction,
            settledPreset: nil
        )
    }

    /// A phase's real target values — `.day` means the schedule's "off"
    /// (neutral, not `PresetID.day`'s own 4000K/100%); `.evening`/`.night`
    /// mean the user's effective (possibly customized) values for that
    /// preset. The one place both `target`'s active- and previous-phase
    /// lookups apply this override, so they can't drift apart the way an
    /// earlier draft of this function did (the active phase correctly
    /// resolved to neutral, the previous-phase lookup didn't).
    private static func phaseValues(_ phase: SchedulePhase, values: (PresetID) -> PresetValues) -> PresetValues {
        var result = phase.preset == .day
            ? PresetValues(warmthK: Config.maxWarmthK, brightness: Config.maxBrightness)
            : values(phase.preset)
        if let brightness = phase.brightnessOverride { result.brightness = brightness }
        return result
    }

    private static func clockTime(_ time: TimeOfDay, on day: Date, calendar: Calendar) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day) ?? day
    }
}
