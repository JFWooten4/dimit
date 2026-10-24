import XCTest
@testable import Dimit

@MainActor
final class AppStateTests: XCTestCase {
    private func freshState() -> AppState {
        // A random suite name per test = a clean UserDefaults every time,
        // so tests never see another test's leftover persisted state and
        // never touch the real app.dimit.mac suite.
        AppState(persistence: Persistence(suiteName: "test.\(UUID().uuidString)"))
    }

    func test_defaults_matchPersistedStateDefaults() {
        let state = freshState()
        XCTAssertEqual(state.isOn, PersistedState.defaults.isOn)
        XCTAssertEqual(state.warmthK, PersistedState.defaults.warmthK)
        XCTAssertEqual(state.brightness, PersistedState.defaults.brightness)
        XCTAssertEqual(state.pwmSafe, PersistedState.defaults.pwmSafe)
        XCTAssertNil(state.activePreset)
    }

    func test_applyPreset_setsWarmthBrightnessAndMarker() {
        let state = freshState()
        state.apply(preset: .evening)
        XCTAssertEqual(state.warmthK, PresetID.evening.warmthK)
        XCTAssertEqual(state.brightness, PresetID.evening.brightness)
        XCTAssertEqual(state.activePreset, .evening)
    }

    func test_movingWarmthSlider_afterAPreset_clearsThePresetMarker() {
        let state = freshState()
        state.apply(preset: .night)
        XCTAssertEqual(state.activePreset, .night)
        state.warmthK = 3000 // user drags away from NIGHT's 0K
        XCTAssertNil(state.activePreset, "preset marker should clear once the value no longer matches it")
    }

    func test_movingBrightnessSlider_afterAPreset_clearsThePresetMarker() {
        let state = freshState()
        state.apply(preset: .day)
        state.brightness = 0.5
        XCTAssertNil(state.activePreset)
    }

    // The macOS 26 colour-bug help is offered on macOS >= 26 and nowhere
    // else. It replaced a banner that appeared on its own; these assert
    // the version gate, and — the point of the change — that nothing about
    // turning the filter on or off can make help appear by itself.
    func test_gammaBugHelp_isOfferedOnMacOS26AndLater() {
        let suite = "test.\(UUID().uuidString)"
        XCTAssertTrue(AppState(persistence: Persistence(suiteName: suite), osMajorVersion: 26).showsGammaBugHelp)
        XCTAssertTrue(AppState(persistence: Persistence(suiteName: suite), osMajorVersion: 27).showsGammaBugHelp)
    }

    func test_gammaBugHelp_isNotOfferedBeforeMacOS26() {
        let suite = "test.\(UUID().uuidString)"
        XCTAssertFalse(AppState(persistence: Persistence(suiteName: suite), osMajorVersion: 13).showsGammaBugHelp)
        XCTAssertFalse(AppState(persistence: Persistence(suiteName: suite), osMajorVersion: 15).showsGammaBugHelp)
    }

    // The regression this change exists to prevent: a Mac that is fine
    // must never be told about a bug it doesn't have, and toggling the
    // filter must not change what the popover offers. `showsGammaBugHelp`
    // is a `let`, so this is really a design assertion — it will stop
    // compiling, not just failing, if anyone makes it stateful again.
    func test_gammaBugHelp_doesNotChangeWhenTheFilterIsToggled() {
        let state = AppState(persistence: Persistence(suiteName: "test.\(UUID().uuidString)"), osMajorVersion: 26)
        let before = state.showsGammaBugHelp
        state.isOn = true
        state.isOn = false
        state.isOn = true
        XCTAssertEqual(state.showsGammaBugHelp, before)
    }

    func test_renderState_reflectsCurrentFields() {
        let state = freshState()
        state.isOn = true
        state.warmthK = 1900
        state.brightness = 0.7
        state.pwmSafe = true
        let render = state.renderState
        XCTAssertEqual(render, RenderState(isOn: true, warmthK: 1900, brightness: 0.7, pwmSafe: true))
    }

    // Deliberately does not go through a live AppState on the write side.
    // An earlier version built an AppState, mutated it, then *separately*
    // called persistence.save(...) directly and asserted a second AppState
    // saw the result — code review pointed out that entangled this test
    // with AppState's own 250ms-debounced autosave timer for no reason:
    // nothing here needs AppState to write, only to correctly *read* a
    // snapshot, so writing the snapshot directly removes the (currently
    // benign, but real) theoretical race with that pending timer.
    func test_appState_hydratesFromAPersistedSnapshot() {
        let suite = "test.\(UUID().uuidString)"
        let persistence = Persistence(suiteName: suite)
        persistence.save(
            PersistedState(
                isOn: true,
                warmthK: PresetID.evening.warmthK,
                brightness: PresetID.evening.brightness,
                pwmSafe: true,
                activePreset: PresetID.evening.rawValue
            )
        )

        let reloaded = AppState(persistence: Persistence(suiteName: suite))
        XCTAssertTrue(reloaded.isOn)
        XCTAssertEqual(reloaded.warmthK, PresetID.evening.warmthK)
        XCTAssertEqual(reloaded.brightness, PresetID.evening.brightness)
        XCTAssertEqual(reloaded.activePreset, .evening)
        XCTAssertTrue(reloaded.pwmSafe)
    }

    // Documents *why* flush() exists: without it, a change made moments
    // before quitting is still sitting in the 250 ms debounce and never
    // reaches disk. If this ever starts failing, persistence stopped being
    // debounced and flush() may no longer be load-bearing.
    func test_aFreshChange_isNotYetPersisted_becauseTheSaveIsDebounced() {
        let suite = "test.\(UUID().uuidString)"
        let persistence = Persistence(suiteName: suite)
        let state = AppState(persistence: persistence)
        state.isOn = true

        let onDisk = Persistence(suiteName: suite).load()
        XCTAssertFalse(onDisk.isOn, "expected the debounced save not to have fired yet")
    }

    // The fix for that: applicationWillTerminate calls flush().
    func test_flush_persistsImmediately_withoutWaitingForTheDebounce() {
        let suite = "test.\(UUID().uuidString)"
        let persistence = Persistence(suiteName: suite)
        let state = AppState(persistence: persistence)
        state.apply(preset: .night)
        state.isOn = true

        state.flush()

        let onDisk = Persistence(suiteName: suite).load()
        XCTAssertTrue(onDisk.isOn)
        XCTAssertEqual(onDisk.warmthK, PresetID.night.warmthK)
        XCTAssertEqual(onDisk.brightness, PresetID.night.brightness)
        XCTAssertEqual(onDisk.activePreset, PresetID.night.rawValue)
    }

    // Covers the other direction: AppState -> PersistedState shape, without
    // depending on the debounce timer either (calls persistence.save
    // directly with the same literal AppState.persist() would build).
    func test_persistedStateShape_matchesAppStateFields() {
        let suite = "test.\(UUID().uuidString)"
        let persistence = Persistence(suiteName: suite)
        let state = AppState(persistence: persistence)
        state.apply(preset: .night)
        state.isOn = true

        persistence.save(
            PersistedState(
                isOn: state.isOn,
                warmthK: state.warmthK,
                brightness: state.brightness,
                pwmSafe: state.pwmSafe,
                activePreset: state.activePreset?.rawValue
            )
        )

        let raw = Persistence(suiteName: suite).load()
        XCTAssertEqual(raw.isOn, true)
        XCTAssertEqual(raw.warmthK, PresetID.night.warmthK)
        XCTAssertEqual(raw.brightness, PresetID.night.brightness)
        XCTAssertEqual(raw.activePreset, PresetID.night.rawValue)
    }

    // MARK: - Preset editing (C4, CLAUDE.md §3.7)

    func test_values_forUneditedPreset_returnsBuiltInDefault() {
        let state = freshState()
        XCTAssertEqual(state.values(for: .evening), PresetID.evening.defaultValues)
    }

    func test_setPresetValues_overridesWhatApplyUses() {
        let state = freshState()
        let custom = PresetValues(warmthK: 3300, brightness: 0.6)
        state.setPresetValues(custom, for: .evening)
        XCTAssertEqual(state.values(for: .evening), custom)

        state.apply(preset: .evening)
        XCTAssertEqual(state.warmthK, 3300)
        XCTAssertEqual(state.brightness, 0.6)
    }

    // "reset to defaults" per CLAUDE.md §3.7 — dragging an override back to
    // exactly the built-in value should behave identically to pressing
    // Reset, not leave a redundant override sitting around.
    func test_setPresetValues_matchingTheDefault_isEquivalentToNoOverride() {
        let state = freshState()
        state.setPresetValues(PresetValues(warmthK: 3300, brightness: 0.6), for: .night)
        state.setPresetValues(PresetID.night.defaultValues, for: .night)
        XCTAssertEqual(state.values(for: .night), PresetID.night.defaultValues)

        // `presetOverrides`'s setter is private but its getter is internal
        // (`private(set)`), so the test target can read it directly here —
        // confirms the persisted JSON won't carry a no-op override either.
        XCTAssertTrue(state.presetOverrides.isEmpty)
    }

    func test_resetPreset_removesOnlyThatPresetsOverride() {
        let state = freshState()
        state.setPresetValues(PresetValues(warmthK: 5000, brightness: 0.9), for: .day)
        state.setPresetValues(PresetValues(warmthK: 3300, brightness: 0.6), for: .evening)

        state.resetPreset(.day)

        XCTAssertEqual(state.values(for: .day), PresetID.day.defaultValues)
        XCTAssertEqual(state.values(for: .evening), PresetValues(warmthK: 3300, brightness: 0.6))
    }

    func test_resetAllPresets_clearsEveryOverride() {
        let state = freshState()
        for preset in PresetID.allCases {
            state.setPresetValues(PresetValues(warmthK: 3333, brightness: 0.33), for: preset)
        }
        state.resetAllPresets()
        for preset in PresetID.allCases {
            XCTAssertEqual(state.values(for: preset), preset.defaultValues)
        }
    }

    // Editing the sliders of the preset that's *currently* selected should
    // update AppState live (not just the stored override) and keep that
    // preset marked as active — otherwise Settings and the popover would
    // show two different ideas of what "NIGHT" currently means.
    func test_editingTheActivePresetsValues_updatesSlidersLiveAndKeepsItActive() {
        let state = freshState()
        state.apply(preset: .night)
        state.setPresetValues(PresetValues(warmthK: 500, brightness: 0.2), for: .night)

        XCTAssertEqual(state.warmthK, 500)
        XCTAssertEqual(state.brightness, 0.2)
        XCTAssertEqual(state.activePreset, .night, "editing the active preset's own values must not un-highlight it")
    }

    func test_editingADifferentPresetsValues_doesNotAffectCurrentSlidersOrActiveMarker() {
        let state = freshState()
        state.apply(preset: .day)
        state.setPresetValues(PresetValues(warmthK: 500, brightness: 0.2), for: .night)

        XCTAssertEqual(state.warmthK, PresetID.day.warmthK)
        XCTAssertEqual(state.activePreset, .day)
    }

    // MARK: - Hotkey adjustments (C4, CLAUDE.md §3.9)

    func test_cycleToNextPreset_goesDayEveningNightDay() {
        let state = freshState()
        state.apply(preset: .day)
        state.cycleToNextPreset()
        XCTAssertEqual(state.activePreset, .evening)
        state.cycleToNextPreset()
        XCTAssertEqual(state.activePreset, .night)
        state.cycleToNextPreset()
        XCTAssertEqual(state.activePreset, .day)
    }

    func test_cycleToNextPreset_withNoActivePreset_startsAtDay() {
        let state = freshState()
        state.warmthK = 3000 // drifted away from every preset
        XCTAssertNil(state.activePreset)
        state.cycleToNextPreset()
        XCTAssertEqual(state.activePreset, .day)
    }

    func test_adjustWarmth_stepsAndClampsToConfigRange() {
        let state = freshState()
        state.warmthK = Config.maxWarmthK
        state.adjustWarmth(by: Config.warmthHotkeyStepK)
        XCTAssertEqual(state.warmthK, Config.maxWarmthK, "must clamp, not overshoot past the max")

        state.warmthK = Config.minWarmthK
        state.adjustWarmth(by: -Config.warmthHotkeyStepK)
        XCTAssertEqual(state.warmthK, Config.minWarmthK, "must clamp, not undershoot past the min")

        state.warmthK = 2700
        state.adjustWarmth(by: Config.warmthHotkeyStepK)
        XCTAssertEqual(state.warmthK, 2750)

        // Low-end warmth adjustments must preserve the new 50 K precision.
        state.warmthK = 800
        state.adjustWarmth(by: -Config.warmthHotkeyStepK)
        XCTAssertEqual(state.warmthK, 750)
        state.adjustWarmth(by: Config.warmthHotkeyStepK)
        XCTAssertEqual(state.warmthK, 800)
    }

    func test_adjustBrightness_stepsAndClampsToConfigRange() {
        let state = freshState()
        state.brightness = Config.maxBrightness
        state.adjustBrightness(by: Config.brightnessHotkeyStep)
        XCTAssertEqual(state.brightness, Config.maxBrightness)

        state.brightness = Config.minBrightness
        state.adjustBrightness(by: -Config.brightnessHotkeyStep)
        XCTAssertEqual(state.brightness, Config.minBrightness)
    }

    // MARK: - Locale override (C4, CLAUDE.md §5)

    func test_effectiveLocale_defaultsToAutoupdatingCurrent_whenNoOverride() {
        let state = freshState()
        XCTAssertNil(state.locale)
        XCTAssertEqual(state.effectiveLocale, Locale.autoupdatingCurrent)
    }

    func test_effectiveLocale_usesTheOverrideWhenSet() {
        let state = freshState()
        state.locale = "ru"
        XCTAssertEqual(state.effectiveLocale, Locale(identifier: "ru"))
    }

    // The AppKit surfaces (context menu, window titles, toast) can't read
    // SwiftUI's environment, so they go through `localized(_:)`. Pins that
    // the override actually changes what they get — a plain
    // `String(localized:)` would return the system language here.
    func test_localized_honoursTheLanguageOverride() {
        let state = freshState()
        state.locale = "ru"
        XCTAssertEqual(state.localized("main.on"), "ВКЛ")
        state.locale = "uz"
        XCTAssertEqual(state.localized("main.on"), "YOQISH")
        state.locale = "en"
        XCTAssertEqual(state.localized("main.on"), "ON")
    }

    func test_localeAndUpdateChecksEnabled_surviveFlushAndReload() {
        let suite = "test.\(UUID().uuidString)"
        let state = AppState(persistence: Persistence(suiteName: suite))
        state.locale = "uz"
        state.updateChecksEnabled = true
        state.flush()

        let reloaded = AppState(persistence: Persistence(suiteName: suite))
        XCTAssertEqual(reloaded.locale, "uz")
        XCTAssertTrue(reloaded.updateChecksEnabled)
    }
}
