import KeyboardShortcuts
import SwiftUI

/// ARCHITECTURE.md §10: "General (launch at login, language, updates
/// opt-in, hotkeys)." Preset editing has no named tab of its own in that
/// spec, so it lives here too — this is the "everyday behavior" tab, and
/// CLAUDE.md §3.7's "user-editable, reset to defaults" fits naturally next
/// to the other per-user preferences on this page.
struct GeneralSettingsTab: View {
    @ObservedObject var appState: AppState

    // `SMAppService.mainApp.status` is the single source of truth (see
    // LaunchAtLogin.swift) — mirrored into local `@State` only because
    // SwiftUI needs *some* observable value to redraw the toggle from; it
    // is refreshed from the real status on every view appearance, not
    // trusted as authoritative between refreshes.
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: launchAtLoginBinding) {
                    Text("settings.launch_at_login")
                }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                languagePicker

                Toggle(isOn: $appState.updateChecksEnabled) {
                    Text("settings.updates")
                }
            }

            Section {
                ForEach(PresetID.allCases, id: \.self) { preset in
                    PresetEditorRow(appState: appState, preset: preset)
                }
                Button {
                    appState.resetAllPresets()
                } label: {
                    Text("settings.preset_reset_all")
                }
            } header: {
                Text("settings.presets_title")
            }

            Section {
                KeyboardShortcuts.Recorder(for: .toggleOnOff) { Text("hotkey.toggle") }
                KeyboardShortcuts.Recorder(for: .cyclePresets) { Text("hotkey.cycle_presets") }
                KeyboardShortcuts.Recorder(for: .warmthUp) { Text("hotkey.warmth_up") }
                KeyboardShortcuts.Recorder(for: .warmthDown) { Text("hotkey.warmth_down") }
                KeyboardShortcuts.Recorder(for: .brightnessUp) { Text("hotkey.brightness_up") }
                KeyboardShortcuts.Recorder(for: .brightnessDown) { Text("hotkey.brightness_down") }
            } header: {
                Text("hotkey.section_title")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // The toggle can go stale if the user changed login items from
            // System Settings directly (outside our own toggle) while this
            // tab was closed; re-read the real status each time it opens.
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginEnabled },
            set: { newValue in
                do {
                    try LaunchAtLogin.setEnabled(newValue)
                    launchAtLoginEnabled = newValue
                    launchAtLoginError = nil
                } catch {
                    // Revert visually rather than show the toggle "on"
                    // while SMAppService silently refused — a wrong-but-
                    // confident UI is worse than a visible error here.
                    launchAtLoginEnabled = LaunchAtLogin.isEnabled
                    // Add the one piece of advice that actually helps when
                    // this fails, instead of only relaying macOS's "Invalid
                    // argument". Only when it applies: telling someone whose
                    // app *is* in Applications to move it there would be
                    // worse than saying nothing.
                    launchAtLoginError = appState.localized(
                        "settings.launch_at_login_error", error.localizedDescription
                    ) + (LaunchAtLogin.isInApplicationsFolder ? "" : "\n" + appState.localized("settings.launch_at_login_move_hint"))
                }
            }
        )
    }

    private var languagePicker: some View {
        Picker(selection: languageBinding) {
            Text("settings.language_system").tag(Optional<String>.none)
            Text("settings.language_en").tag(Optional("en"))
            Text("settings.language_uz").tag(Optional("uz"))
            Text("settings.language_ru").tag(Optional("ru"))
        } label: {
            Text("settings.language")
        }
    }

    private var languageBinding: Binding<String?> {
        Binding(get: { appState.locale }, set: { appState.locale = $0 })
    }
}

/// One preset's warmth + brightness sliders plus a per-row reset button —
/// CLAUDE.md §3.7. Reads/writes through `AppState.values(for:)` /
/// `setPresetValues(_:for:)` rather than holding its own local state, so
/// editing the *active* preset here updates the popover's sliders live
/// (`AppStateTests.test_editingTheActivePresetsValues_...` pins that).
private struct PresetEditorRow: View {
    @ObservedObject var appState: AppState
    let preset: PresetID
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(preset.titleKey).bold()
                Spacer()
                Button {
                    appState.resetPreset(preset)
                } label: {
                    Text("settings.preset_reset")
                }
                .buttonStyle(.borderless)
                // Three identical "Reset, button" rows are indistinguishable
                // to VoiceOver without naming which preset each resets.
                .accessibilityLabel(Text("\(String(localized: "settings.preset_reset")) \(String(localized: preset.titleKey))"))
            }

            HStack {
                Text("main.warmth").frame(width: 90, alignment: .leading)
                Slider(
                    value: warmthBinding,
                    in: Config.minWarmthK...Config.maxWarmthK,
                    step: Config.warmthHotkeyStepK
                )
                // CLAUDE.md §8: "VoiceOver labels for both sliders and all
                // buttons." The sibling Text is a separate element, so
                // without these the row reads as six unlabelled sliders.
                .accessibilityLabel(Text("\(String(localized: preset.titleKey)) — \(String(localized: "main.warmth"))"))
                .accessibilityValue(Text(ValueFormatting.warmth(warmthBinding.wrappedValue, locale: locale)))
                Text(ValueFormatting.warmth(warmthBinding.wrappedValue, locale: locale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            HStack {
                Text("main.brightness").frame(width: 90, alignment: .leading)
                Slider(
                    value: brightnessBinding,
                    in: Config.minBrightness...Config.maxBrightness
                )
                .accessibilityLabel(Text("\(String(localized: preset.titleKey)) — \(String(localized: "main.brightness"))"))
                .accessibilityValue(Text(ValueFormatting.brightness(brightnessBinding.wrappedValue)))
                Text(ValueFormatting.brightness(brightnessBinding.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private var warmthBinding: Binding<Double> {
        Binding(
            get: { appState.values(for: preset).warmthK },
            set: { appState.setPresetValues(PresetValues(warmthK: $0, brightness: appState.values(for: preset).brightness), for: preset) }
        )
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { appState.values(for: preset).brightness },
            set: { appState.setPresetValues(PresetValues(warmthK: appState.values(for: preset).warmthK, brightness: $0), for: preset) }
        )
    }
}
