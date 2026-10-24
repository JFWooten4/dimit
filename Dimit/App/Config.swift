import Foundation

/// Product-wide constants. CLAUDE.md §2: "product name and bundle ID as
/// constants in Config.swift." Everything else that varies by cycle
/// (pricing, API host, feature flags) is added here as that cycle lands —
/// see the `// C4`, `// C5` etc. markers below for what's still to come.
enum Config {
    static let productName = "Dimit"
    static let bundleID = "app.dimit.mac"

    // MARK: - Warmth (CLAUDE.md §3.2)
    static let minWarmthK: Double = 0
    static let maxWarmthK: Double = 6500

    // MARK: - Brightness (CLAUDE.md §1, §3.3)
    static let minBrightness: Double = 0.10
    static let maxBrightness: Double = 1.0
    /// Below this, gamma dimming bands and loses text; the C3 overlay takes over.
    static let gammaDimFloor: Double = 0.30

    // MARK: - Hotkey step sizes (CLAUDE.md §3.9, C4)
    // Named here (not inlined in HotkeyManager) so a future stepper button
    // in the UI can't drift from what the hotkey does for the same action.
    static let warmthHotkeyStepK: Double = 50 // shared by both sliders and the hotkeys
    static let brightnessHotkeyStep: Double = 0.05

    // CLAUDE.md §3.4 names `Config.ddcEnabled` as the DDC feature flag. It
    // landed in C5b as `AppState.ddcEnabled` instead — persisted, and
    // bound to a real Settings toggle, which a `static var` here could be
    // neither. Same default (OFF), same meaning; noted rather than left as
    // a dead second copy for someone to wire up by mistake.
}
