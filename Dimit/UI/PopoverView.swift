import SwiftUI

/// CLAUDE.md §1: "Two sliders, three presets, one button. Anything else
/// lives behind a Settings gear." ARCHITECTURE.md §10 has the fuller visual
/// spec (gradients, segmented control, PWM row help text); this pass gets
/// the structure and every string wired to the catalog, plain system
/// controls throughout. Custom styling is polish for a later cycle, not a
/// blocker for a working app.
struct PopoverView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pwmSafeCoordinator: PWMSafeCoordinator
    let openSettings: () -> Void
    // @Environment, not Locale.current: Locale.current ignores a
    // .environment(\.locale, ...) override, which is both how SwiftUI
    // previews/tests switch locale and how C4's in-app language override
    // will need to work (CLAUDE.md §5: "Settings has a language override").
    @Environment(\.locale) private var locale
    /// Collapsed on every popover open, deliberately: it is a
    /// troubleshooting question, not a setting, so it has nothing to
    /// remember and never occupies the popover unless asked for.
    @State private var isGammaBugHelpExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            onOffButton
            warmthRow
            brightnessRow
            presetPicker
            pwmSafeRow
            if appState.showsGammaBugHelp {
                gammaBugHelp
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("app.name")
                .font(.headline)
            Spacer()
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel(Text("settings.title"))
        }
    }

    // The macOS 26 colour-bug help (Apple FB22273730), on macOS ≥ 26 only.
    //
    // This used to be a yellow banner that appeared by itself the first
    // time the filter was turned ON — CLAUDE.md §3.3's original wording,
    // written when we believed we had a machine that reproduced the bug.
    // We don't: every Mac we can test on applies the colour table fine
    // (docs/QA.md), and Apple's own threads say it hits *some* Macs. A
    // warning shown to everyone on macOS 26+ therefore alarmed mostly
    // people with no problem.
    //
    // The bug is still undetectable from inside the process (read-back
    // returns the values it stored, DTS-confirmed), so the user is the
    // only available detector: they can see whether the screen turned
    // warm. Hence a quiet one-line question instead of a warning — closed
    // by default, and the same explanation and Displays-settings shortcut
    // behind it for whoever answers "no".
    // A `DisclosureGroup` rather than a hand-rolled chevron button so the
    // expanded/collapsed state is announced by VoiceOver without inventing
    // two more strings for it (CLAUDE.md §8's accessibility bar).
    private var gammaBugHelp: some View {
        DisclosureGroup(isExpanded: $isGammaBugHelpExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("banner.gamma_blocked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("banner.open_settings")
                        .font(.caption.bold())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Text("help.colours_not_changing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var onOffButton: some View {
        ZapButton(isOn: appState.isOn) { appState.isOn.toggle() }
    }

    private var warmthRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("main.warmth")
                Spacer()
                Text(formattedWarmth)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // CLAUDE.md §8 quality bar: "VoiceOver labels for both sliders."
            // Without an explicit label a bare Slider announces only its
            // value ("6500K") with no indication of *what* it controls —
            // the visible Text above it is a separate a11y element.
            Slider(value: $appState.warmthK, in: Config.minWarmthK...Config.maxWarmthK, step: Config.warmthHotkeyStepK)
                .accessibilityLabel(Text("main.warmth"))
                .accessibilityValue(Text(formattedWarmth))
        }
    }

    private var brightnessRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("main.brightness")
                Spacer()
                Text(formattedBrightness)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $appState.brightness, in: Config.minBrightness...Config.maxBrightness)
                .accessibilityLabel(Text("main.brightness"))
                .accessibilityValue(Text(formattedBrightness))
        }
    }

    private var presetPicker: some View {
        Picker("", selection: presetBinding) {
            ForEach(PresetID.allCases, id: \.self) { preset in
                Text(preset.titleKey).tag(Optional(preset))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var presetBinding: Binding<PresetID?> {
        Binding(
            get: { appState.activePreset },
            set: { newValue in
                guard let preset = newValue else { return }
                appState.apply(preset: preset)
            }
        )
    }

    private var pwmSafeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $appState.pwmSafe) {
                Text("main.pwm_safe")
            }
            .help(Text("main.pwm_safe.help"))

            if appState.pwmSafe, let status = pwmStatusText {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(pwmStatusIsWarning ? .orange : .secondary)
            }
        }
    }

    // Maps PWMSafeCoordinator.summaryState to the catalog strings CLAUDE.md
    // §5.1 already defines for each state. `.pinned` shows the battery
    // note (CLAUDE.md §3.6) rather than a redundant "it's on" message —
    // the toggle itself and the (in this build, placeholder) menu-bar dot
    // already say that.
    private var pwmStatusText: LocalizedStringResource? {
        switch pwmSafeCoordinator.summaryState {
        case .pinning: return "pwm.waiting"
        case .wontHold: return "pwm.wont_hold"
        case .unsupported: return "pwm.unsupported"
        case .pinned: return "main.pwm_safe.help" // doubles as the battery note
        case .off, nil: return nil
        }
    }

    private var pwmStatusIsWarning: Bool {
        switch pwmSafeCoordinator.summaryState {
        case .wontHold, .unsupported: return true
        default: return false
        }
    }

    private var formattedWarmth: String {
        ValueFormatting.warmth(appState.warmthK, locale: locale)
    }

    private var formattedBrightness: String {
        ValueFormatting.brightness(appState.brightness)
    }
}

#Preview {
    PopoverView(appState: AppState(), pwmSafeCoordinator: PWMSafeCoordinator(backends: []), openSettings: {})
}

/// CLAUDE.md §1.1's "one button" — the ON/OFF hero.
///
/// A view of its own rather than a `private var` inside `PopoverView` for
/// one reason: `DimitTests/LayoutRenderTests` renders *this exact view* and
/// measures the contrast between its label and its own background. The bug
/// below was reported from a real screen, and the only way this environment
/// can prove it stays fixed is to rasterize the thing itself and look at
/// the pixels — not a reconstruction of it that could drift.
struct ZapButton: View {
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            // Label shows CURRENT state, matching the fill below (a warm
            // gradient when on) — code review on C1 caught this inverted
            // (label said "OFF" on an orange, active-looking button while
            // isOn was true). The accessibility value below correctly
            // describes the opposite word: what activating it changes it TO.
            Text(isOn ? "main.on" : "main.off")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(ZapButtonStyle(isOn: isOn))
        // Reads as "Dimit, ON, button" rather than the bare "OFF, button, ON"
        // an earlier hint produced (label, trait, then a lone contradictory
        // word). Uses only strings already in the catalog; proper
        // action-phrase hints ("Turns the filter off") need new UZ/RU
        // translations and belong with C4's full VoiceOver pass.
        .accessibilityLabel(Text("app.name"))
        .accessibilityValue(Text(isOn ? "main.on" : "main.off"))
    }
}

/// ARCHITECTURE.md §10's ON/OFF button, exactly: a warm gradient fill when
/// on, an outline when off.
///
/// Deliberately **not** `.borderedProminent`. That style derives the
/// label's colour from the tint's computed luminance, and the first version
/// of this button passed it `.tint(.secondary)` for the OFF state.
/// `.secondary` is not a fill colour: in **light** mode it produced a
/// near-black fill, and the automatic contrast then put a dark label on it.
/// "OFF" was drawn — just unreadable. Reported from the owner's screen, and
/// measured afterwards at **3.48:1 in light mode** against 12.49:1 for the
/// outline below. (Dark mode was never affected — 13.11:1 either way — which
/// is exactly why a style that picks colours for you is the wrong thing to
/// trust: it failed in one appearance and looked fine in the other.)
///
/// The ON state improved too, incidentally: white on this gradient measures
/// 3.44:1, clearing WCAG's 3:1 large-text bar, where the previous system
/// `.orange` sat at 2.2–2.3:1 and cleared nothing.
///
/// `LayoutRenderTests` measures all of it, and was itself checked by
/// reverting this fix and confirming it fails.
struct ZapButtonStyle: ButtonStyle {
    let isOn: Bool

    private static let gradient = LinearGradient(
        colors: [Color(red: 1, green: 0x6A / 255, blue: 0), Color(red: 1, green: 0x2D / 255, blue: 0x2D / 255)],
        startPoint: .leading, endPoint: .trailing
    )

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .foregroundStyle(isOn ? Color.white : Color.primary)
            .background(isOn ? AnyShapeStyle(Self.gradient) : AnyShapeStyle(.clear), in: shape)
            .overlay {
                if !isOn {
                    shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 1.5)
                }
            }
            // The OFF state has no opaque fill, and this is the app's
            // primary control: state plainly what is clickable rather than
            // depending on how SwiftUI hit-tests a shape filled with
            // `.clear`. (Probing the real hit region from a test turned out
            // to be impossible here — `NSHostingView.hitTest` answers for
            // the whole host, identically for the opaque ON state, so it
            // can't tell the two apart. One line beats an open question on
            // the button everything else in the popover hangs off.) It also
            // correctly excludes the rounded corners, which a default
            // rectangular hit area would not.
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}
