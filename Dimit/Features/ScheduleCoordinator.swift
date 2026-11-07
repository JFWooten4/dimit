import AppKit
import Combine
import Foundation

/// The driver for `ScheduleEngine` — ARCHITECTURE.md §3: "wakes once per
/// minute (tolerance 30s) and during a ramp every 10s, sets
/// AppState.warmthK/brightness ... so a manual slider move pauses the
/// schedule until the next phase boundary."
///
/// `calendar`/`now` are injectable so tests can pin exactly what "today"
/// and "the current instant" are — the same reason `PWMSafeCoordinator`
/// injects its delays, applied here to time itself rather than to a retry
/// interval. The real Timer that drives production ticking is *not*
/// unit-tested (there is nothing to fake it against without a much bigger
/// injection surface than this cycle's scope justifies); `evaluateNow()`
/// is the tested entry point, called both by the timer and directly by
/// `ScheduleCoordinatorTests`.
@MainActor
final class ScheduleCoordinator: NSObject {
    private let appState: AppState
    private let calendar: () -> Calendar
    private let now: () -> Date
    private let sessionClock: LoginSessionClock

    private var tickTimer: Timer?
    private var cachedPhases: [SchedulePhase] = []
    private var cachedPhasesDay: Date?
    private var cachedSessionStart: Date?

    /// Set to the active phase's `start` the moment a manual change is
    /// detected; cleared once `now` has moved into a *later* phase than
    /// that one. While set, `evaluateNow()` writes nothing.
    private(set) var pausedAtPhaseStart: Date?

    /// Guards the write path that must NOT be mistaken for a manual
    /// override: this coordinator's own writes to `isOn`/`warmthK`/
    /// `brightness`/`activePreset`.
    ///
    /// This depends on the Combine subscription below staying fully
    /// synchronous — `sink` runs inline with the property write that
    /// triggered it, so this flag is still `true` for every one of this
    /// method's own writes and back to `false` before any *other* caller's
    /// write can run (Swift is single-threaded here; nothing preempts
    /// `evaluateNow()` mid-execution). If `.receive(on:)`, `.debounce`, or
    /// `.throttle` is ever added to that subscription, this guard breaks —
    /// the sink would fire after the flag has already reset, and every
    /// schedule tick would look like a fresh manual override, permanently
    /// pausing itself after one write. Don't add one without redesigning
    /// this alongside it.
    private var isApplyingScheduleTick = false

    private var cancellables = Set<AnyCancellable>()

    init(
        appState: AppState,
        calendar: @escaping () -> Calendar = { .current },
        now: @escaping () -> Date = { Date() },
        sessionClock: LoginSessionClock = .shared
    ) {
        self.appState = appState
        self.calendar = calendar
        self.now = now
        self.sessionClock = sessionClock
        super.init()

        // NSWorkspace's center (not NotificationCenter.default) reports
        // real system sleep/wake. Screen savers and lock/unlock are ignored.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep(_:)),
                              name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake(_:)),
                              name: NSWorkspace.didWakeNotification, object: nil)

        // isOn/warmthK/brightness are exactly the fields this coordinator
        // itself writes (see evaluateNow()) — anything else changing on
        // AppState (pwmSafe, ddcEnabled, locale, ...) has nothing to do
        // with the schedule and must not pause it. Deliberately NOT
        // `appState.objectWillChange`, which fires for all of those too.
        Publishers.Merge3(
            appState.$isOn.dropFirst().map { _ in () },
            appState.$warmthK.dropFirst().map { _ in () },
            appState.$brightness.dropFirst().map { _ in () }
        )
        .sink { [weak self] in self?.handleExternalValueChange() }
        .store(in: &cancellables)

        // `.receive(on: .main)` is not optional here: `@Published` fires
        // from `willSet`, before the new value is actually stored, and
        // `handleConfigChanged()` reads `appState.scheduleConfig` itself
        // rather than the value this publisher carries — a synchronous
        // sink would see the *previous* config. `DisplayCoordinator` hit
        // this exact class of bug already (see its own doc comment) and
        // fixed it the same way. Missing it here was confirmed to break
        // the feature's most basic case: switching from Manual to a real
        // mode in Settings silently did nothing until a second, unrelated
        // config change happened to also fire this subscription.
        appState.$scheduleConfig
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleConfigChanged() }
            .store(in: &cancellables)

        recomputePhases()
        evaluateNow()
        scheduleNextTick()
    }

    /// Invalidates the timer and drops the Combine subscriptions —
    /// AppDelegate calls this from `applicationWillTerminate`, before its
    /// own gamma-restore calls. Without it, a tick already queued on the
    /// run loop could fire *after* the restore and re-apply a tinted
    /// state on the way out, which CLAUDE.md §1.8's "on quit, the display
    /// must return to normal colours" doesn't allow an exception for.
    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        cancellables.removeAll()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.removeObserver(self, name: NSWorkspace.willSleepNotification, object: nil)
        workspace.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        sessionClock.willSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        handleWake()
    }

    /// Shared with tests so wake behavior can be verified without putting
    /// the machine to sleep or synthesizing AppKit notifications.
    func handleWake() {
        if sessionClock.didWake() {
            cachedSessionStart = nil
            pausedAtPhaseStart = nil
        }
        evaluateNow()
        scheduleNextTick()
    }

    /// Computes the schedule's target for right now and writes it — unless
    /// paused by a manual override that hasn't yet crossed a phase
    /// boundary, or the mode is `.manual`, or there is nothing to write
    /// (before the schedule's first phase, or no location configured yet).
    func evaluateNow() {
        ensurePhasesAreCurrent()
        guard appState.scheduleConfig.mode != .manual else { return }

        guard let active = ScheduleEngine.activePhase(at: now(), phases: cachedPhases) else { return }
        if let pausedAt = pausedAtPhaseStart {
            guard active.start > pausedAt else { return } // still within the overridden phase
            pausedAtPhaseStart = nil // crossed into a new phase since the override — resume
        }

        guard let target = ScheduleEngine.target(at: now(), phases: cachedPhases, values: appState.values(for:)) else { return }

        isApplyingScheduleTick = true
        appState.isOn = target.isOn
        appState.warmthK = target.warmthK
        appState.brightness = target.brightness
        // Last and unconditional, same pattern `AppState.apply(preset:)`
        // already uses: `warmthK`/`brightness`'s own `didSet` just cleared
        // `activePreset` above (nothing matches an interpolated value, or
        // the neutral off-state, and that's correct) — but once a ramp has
        // fully landed on a real preset's exact values, this re-highlights
        // it, so the popover's DAY/EVENING/NIGHT picker doesn't sit
        // permanently blank the whole time the schedule is driving it.
        if let settledPreset = target.settledPreset {
            appState.activePreset = settledPreset
        }
        isApplyingScheduleTick = false
    }

    private func handleExternalValueChange() {
        guard !isApplyingScheduleTick else { return }
        guard appState.scheduleConfig.mode != .manual else { return }
        // Record what phase we were in *at the moment of the override* —
        // not just "paused forever." The next tick that finds we've moved
        // into a later phase than this one resumes automatically.
        pausedAtPhaseStart = ScheduleEngine.activePhase(at: now(), phases: cachedPhases)?.start
    }

    private func handleConfigChanged() {
        cachedPhasesDay = nil // force a recompute even if the calendar day hasn't rolled over
        cachedSessionStart = nil
        pausedAtPhaseStart = nil // a new mode/location/bedtime invalidates any prior override
        evaluateNow()
        scheduleNextTick() // ramp status (and manual<->automatic) may have just changed
    }

    private var isLoginAnchored: Bool {
        let mode = appState.scheduleConfig.mode
        return appState.scheduleConfig.timeBasis == .login && (mode == .bellCurve || mode == .fixedTimes)
    }

    private func ensurePhasesAreCurrent() {
        if isLoginAnchored {
            let start = sessionClock.start
            guard cachedSessionStart != start else { return }
            cachedSessionStart = start
            cachedPhasesDay = nil
        } else {
            let today = calendar().startOfDay(for: now())
            guard cachedPhasesDay != today || cachedSessionStart != nil else { return }
            cachedPhasesDay = today
            cachedSessionStart = nil
        }
        recomputePhases()
    }

    private func recomputePhases() {
        if isLoginAnchored {
            cachedPhases = ScheduleEngine.phases(
                forSessionStartingAt: sessionClock.start,
                mode: appState.scheduleConfig.mode,
                config: appState.scheduleConfig
            )
        } else {
            cachedPhases = ScheduleEngine.phases(
                coveringDayOf: now(), mode: appState.scheduleConfig.mode,
                config: appState.scheduleConfig, calendar: calendar()
            )
        }
    }

    private func isCurrentlyRamping() -> Bool {
        guard let active = ScheduleEngine.activePhase(at: now(), phases: cachedPhases), active.rampMinutes > 0 else { return false }
        let rampEnd = active.start.addingTimeInterval(Double(active.rampMinutes) * 60)
        return now() < rampEnd
    }

    private func scheduleNextTick() {
        tickTimer?.invalidate()
        tickTimer = nil
        // No timer at all in Manual mode — CLAUDE.md §8's idle-CPU budget
        // shouldn't pay for a repeating wakeup nobody asked for, and Manual
        // is the default every fresh install starts in.
        guard appState.scheduleConfig.mode != .manual else { return }

        let interval: TimeInterval = isCurrentlyRamping() ? 10 : 60
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.evaluateNow()
            self.scheduleNextTick()
        }
        // 30s tolerance off a ramp (ARCHITECTURE.md §3: "keeps energy impact
        // nil"); tighter during a ramp, where CLAUDE.md's 20-minute default
        // duration means a lazy timer would visibly stair-step instead of
        // gliding.
        timer.tolerance = interval >= 60 ? 30 : 1
        // `.common`, not `.default`: a `.default`-mode timer stops firing
        // while a menu is open or a window is being dragged — exactly the
        // bug an independent C4 review found in PWMSafeCoordinator's drift
        // poll (still open as of C5, docs/QA.md). Using `.common` here from
        // the start avoids repeating that finding in a second coordinator.
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }
}
