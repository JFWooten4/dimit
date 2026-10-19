import AppKit
import SwiftUI
import XCTest
@testable import Dimit

/// Hosts each C4 view off-screen in every supported language and checks it
/// lays out inside its intended frame — CLAUDE.md §5: "Menu bar / popover
/// must fit 1.4× English string length. Test with Russian, which is
/// longest." This environment can't screenshot popovers or windows above
/// its own pane, so rasterizing the SwiftUI hierarchy directly is the one
/// way to look at these surfaces here. Set `DIMIT_RENDER_DIR` to also
/// write PNGs for eyeballing; otherwise this only asserts on geometry.
@MainActor
final class LayoutRenderTests: XCTestCase {
    private let locales = ["en", "uz", "ru"]

    func test_popover_fitsIn320ptWidth_inEveryLanguage() {
        for locale in locales {
            let state = freshState(locale: locale)
            let view = PopoverView(
                appState: state,
                pwmSafeCoordinator: PWMSafeCoordinator(backends: []),
                openSettings: {}
            )
            .environment(\.locale, Locale(identifier: locale))
            let size = render(view, name: "popover-\(locale)")
            XCTAssertEqual(size.width, 320, accuracy: 0.5, "\(locale): popover must stay at its fixed 320pt width")
            XCTAssertLessThan(size.height, 520, "\(locale): popover grew unreasonably tall — a string is probably wrapping badly")
        }
    }

    /// The macOS 26 help replaced a banner that opened itself; its whole
    /// point is that it costs one quiet line until someone asks. This
    /// measures that: present on 26+, absent below, and worth about a line
    /// of height in every language (Russian is the long one, CLAUDE.md §5).
    func test_popover_gammaBugHelpIsOneCollapsedLine_andAbsentBeforeMacOS26() {
        for locale in locales {
            let offered = render(popover(locale: locale, osMajorVersion: 26), name: "popover-help-\(locale)")
            let notOffered = render(popover(locale: locale, osMajorVersion: 15), name: "popover-nohelp-\(locale)")

            XCTAssertEqual(offered.width, 320, accuracy: 0.5, "\(locale): the help row must not widen the popover")
            XCTAssertEqual(notOffered.width, 320, accuracy: 0.5)
            let added = offered.height - notOffered.height
            XCTAssertGreaterThan(added, 12, "\(locale): macOS 26 should be offered the help")
            XCTAssertLessThan(added, 60, "\(locale): collapsed help must stay about one line, not a paragraph")
        }
    }

    private func popover(locale: String, osMajorVersion: Int) -> some View {
        PopoverView(
            appState: freshState(locale: locale, osMajorVersion: osMajorVersion),
            pwmSafeCoordinator: PWMSafeCoordinator(backends: []),
            openSettings: {}
        )
        .environment(\.locale, Locale(identifier: locale))
    }

    func test_settings_fitsItsFixedFrame_inEveryLanguage() {
        for locale in locales {
            let state = freshState(locale: locale)
            let view = SettingsView(
                appState: state,
                displayManager: DisplayManager(),
                pwmSafeCoordinator: PWMSafeCoordinator(backends: []),
                restoreColours: {}
            )
            let size = render(view, name: "settings-\(locale)")
            XCTAssertEqual(size.width, 520, accuracy: 0.5, "\(locale)")
            XCTAssertEqual(size.height, 460, accuracy: 0.5, "\(locale)")
        }
    }

    // The whole-window render above always lands on Settings' first tab
    // (General) — it never actually looks at the Schedule tab's own
    // controls (a segmented mode picker, DatePickers, a DisclosureGroup,
    // a Stepper: several control types not used anywhere else in this
    // codebase yet). Rendered directly, in each of its three modes.
    func test_scheduleTab_fitsAndRenders_inEveryMode_andEveryLanguage() {
        for locale in locales {
            for mode in ScheduleMode.allCases {
                let state = freshState(locale: locale)
                state.scheduleConfig.mode = mode
                if mode == .sunsetToSunrise {
                    state.scheduleConfig.location = Coordinate(latitude: 41.2995, longitude: 69.2401)
                    state.scheduleConfig.selectedCityID = "tashkent"
                }
                if mode == .bellCurve {
                    // Hue must remain visible when brightness is constant.
                    state.scheduleConfig.fixedDayStart = TimeOfDay(hour: 0, minute: 0)
                    state.scheduleConfig.peakTime = TimeOfDay(hour: 13, minute: 0)
                    state.scheduleConfig.bedtime = TimeOfDay(hour: 17, minute: 0)
                    state.scheduleConfig.lowBrightness = 1
                    state.scheduleConfig.peakBrightness = 1
                }
                let view = ScheduleSettingsTab(appState: state)
                    .environment(\.locale, Locale(identifier: locale))
                    .frame(width: 520)
                let size = render(view, name: "schedule-\(mode.rawValue)-\(locale)")
                XCTAssertGreaterThan(size.height, 0, "\(mode.rawValue)/\(locale): view produced no content")
                // SettingsView's real window is a fixed 520x460, and its
                // TabView reserves roughly 40pt for the tab bar itself,
                // leaving ~420pt of actual content height. An earlier
                // version of this test only checked "&lt; 900" — comfortably
                // true even for content that would need to scroll inside
                // the real window, so it never actually proved the tab
                // fits (an independent review caught the gap, though not
                // a live failure: every mode measures well under the real
                // budget). `Form`/`.formStyle(.grouped)` scrolls
                // gracefully if this ever needs to grow past it, so this
                // is a real ceiling, not a hard crash risk — but a
                // regression here means the tab now needs scrolling to
                // see everything, in the one language (Russian) most
                // likely to hit it first.
                XCTAssertLessThan(size.height, 420, "\(mode.rawValue)/\(locale): exceeds the real Settings window's content height — this tab would now need scrolling")
            }
        }
    }

    // The Displays tab gained C5b's Experimental DDC toggle plus two
    // paragraphs of help text — the longest prose in Settings, and never
    // render-tested before (the whole-window test only ever shows the
    // first tab).
    func test_displaysTab_fitsAndRenders_inEveryLanguage() {
        for locale in locales {
            let state = freshState(locale: locale)
            state.ddcEnabled = true // the expanded state, with help text showing
            let view = DisplaysSettingsTab(
                appState: state,
                displayManager: DisplayManager(),
                pwmSafeCoordinator: PWMSafeCoordinator(backends: [])
            )
            .environment(\.locale, Locale(identifier: locale))
            .frame(width: 520)
            let size = render(view, name: "displays-\(locale)")
            XCTAssertGreaterThan(size.height, 0, "\(locale): produced no content")
            XCTAssertLessThan(size.height, 420, "\(locale): exceeds the real Settings window's content height")
        }
    }

    func test_onboarding_fitsItsFixedFrame_inEveryLanguage() {
        for locale in locales {
            let state = freshState(locale: locale)
            let view = OnboardingView(appState: state, restoreColours: {}, finish: {})
            let size = render(view, name: "onboarding-\(locale)")
            XCTAssertEqual(size.width, 460, accuracy: 0.5, "\(locale)")
            XCTAssertEqual(size.height, 360, accuracy: 0.5, "\(locale)")
        }
    }

    // The ON/OFF button is the one control in this app whose label colour
    // used to be chosen *for* us: `.buttonStyle(.borderedProminent)` picks a
    // label colour from the tint's luminance, and with `.tint(.secondary)`
    // for the OFF state it put a dark label on the near-black fill
    // `.secondary` produces in light mode. The owner reported it from a real
    // screen — "when it is off i can't see the letters" — and no test here
    // could have caught it, because every test in this file measured
    // geometry and none had ever looked at a colour.
    //
    // So this one renders the real `ZapButton` and reads its pixels. The
    // ratio is WCAG's: (Lmax + 0.05) / (Lmin + 0.05) over relative
    // luminance. 4.5:1 is the normal-text bar; the outlined OFF state clears
    // it with room to spare (12.49:1 light, 12.93:1 dark) because
    // `.primary`-on-background is what every other label in the popover
    // does.
    //
    // Both appearances are checked because the bug lived in exactly one of
    // them: reverting the fix measures 3.48:1 in light mode and 13.11:1 in
    // dark. A single-appearance test would have called the broken build fine.
    func test_onOffButton_labelIsReadableAgainstItsOwnFill_inBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let contrast = onOffButtonContrast(isOn: false, appearance: appearance)
            XCTAssertGreaterThan(
                contrast, 4.5,
                "\(appearance.rawValue): the OFF label must be plainly readable — measured \(String(format: "%.2f", contrast)):1"
            )
        }
    }

    // The ON state is white on the two fixed brand colours ARCHITECTURE.md
    // §10 specifies (#FF6A00 → #FF2D2D), so its contrast is a property of
    // the palette rather than of a styling choice. Measured where the label
    // actually sits — the middle of the gradient — that is **3.44:1**, which
    // clears WCAG's 3:1 bar for large text (this label is 17pt bold) though
    // not the 4.5:1 normal-text one. The floor is the large-text bar.
    //
    // Worth pinning because the previous styling did *not* clear it: system
    // `.orange` measured 2.32:1 light / 2.23:1 dark. Raising the floor
    // further would mean darkening the specified brand colours — a design
    // decision to take with the owner, not a silent edit.
    func test_onOffButton_onStateClearsTheLargeTextBar() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let contrast = onOffButtonContrast(isOn: true, appearance: appearance)
            XCTAssertGreaterThan(
                contrast, 3.0,
                "\(appearance.rawValue): white on the warm gradient measured \(String(format: "%.2f", contrast)):1 — below WCAG's 3:1 large-text bar"
            )
        }
    }

    // The menu-bar icon is the only part of this app that is on screen all
    // the time, and it had never been tested at all. The owner reported the
    // pinned state as "when it is on ... in bottom something appears":
    // `MenuBarIcon` composed the PWM badge onto a hard-coded 18×18 canvas
    // while `circle`/`circle.fill` come back at 15×15, so pinning silently
    // scaled the glyph up by 20% — the icon grew. The badge was also over
    // twice ARCHITECTURE.md §10's "3 pt dot" and merged into `circle.fill`
    // with no gap, reading as one lopsided blob rather than a badge.
    func test_menuBarIcon_pinnedBadgeDoesNotResizeTheIcon() {
        for isOn in [true, false] {
            let plain = MenuBarIcon.image(isOn: isOn, pwmPinned: false, accessibilityDescription: "x")
            let pinned = MenuBarIcon.image(isOn: isOn, pwmPinned: true, accessibilityDescription: "x")
            XCTAssertEqual(
                plain?.size, pinned?.size,
                "isOn=\(isOn): the icon must not change size when PWM-Safe pins — it sits in the menu bar next to everything else"
            )
            XCTAssertEqual(pinned?.isTemplate, true, "isOn=\(isOn): must stay a template image so it follows the menu-bar tint")
        }
    }

    // ...and the badge must actually be drawn, or the test above would pass
    // just as well on a version that ignored `pwmPinned` entirely.
    func test_menuBarIcon_pinnedBadgeIsVisiblyDifferentFromUnpinned() {
        let plain = rasterize(MenuBarIcon.image(isOn: true, pwmPinned: false, accessibilityDescription: "x"))
        let pinned = rasterize(MenuBarIcon.image(isOn: true, pwmPinned: true, accessibilityDescription: "x"))
        XCTAssertNotNil(plain)
        XCTAssertNotNil(pinned)
        XCTAssertNotEqual(plain, pinned, "the pinned icon must actually carry a badge")
    }

    // MARK: - Helpers

    /// Flattens an icon onto white at a fixed size so two of them can be
    /// compared byte for byte.
    private func rasterize(_ image: NSImage?) -> Data? {
        guard let image else { return nil }
        let size = NSSize(width: 64, height: 64)
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Renders the real `ZapButton` under one appearance and returns the
    /// WCAG contrast ratio between the lightest and darkest pixels **in the
    /// centre of the button**, where the label sits.
    ///
    /// The crop is the whole point, and the first version of this helper got
    /// it wrong: measuring min/max across the entire image passed happily on
    /// the broken code, because the lightest pixel was the backdrop showing
    /// past the button's edge and the darkest was the button's own fill — a
    /// large ratio that says nothing about whether the *label* is legible
    /// against the fill behind it. Restricted to a box around the centred
    /// glyphs, the two extremes can only be glyph and fill, which is the
    /// question the owner actually asked ("i can't see the letters"). With
    /// the uncropped version, reverting the fix still "passed" the OFF
    /// assertion — the crop is what makes this test mean anything.
    private func onOffButtonContrast(isOn: Bool, appearance name: NSAppearance.Name) -> Double {
        let appearance = NSAppearance(named: name)!
        let view = ZapButton(isOn: isOn, toggle: {})
            .frame(width: 320)
            // The popover draws on a vibrant material; `windowBackgroundColor`
            // is the closest opaque stand-in, and an opaque backdrop is
            // required — the OFF state's fill is `.clear`, and luminance
            // maths on transparent pixels is meaningless.
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, name == .darkAqua ? .dark : .light)

        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()

        var lightest = -1.0
        var darkest = 2.0
        appearance.performAsCurrentDrawingAppearance {
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            // The label is centred both ways. This box is wide enough to
            // contain the glyphs of "ON"/"OFF"/"ВКЛ"/"YOQISH" and the fill
            // between them, and inset far enough to exclude the button's
            // own border and anything outside it.
            let xRange = (rep.pixelsWide * 35 / 100)..<(rep.pixelsWide * 65 / 100)
            let yRange = (rep.pixelsHigh * 30 / 100)..<(rep.pixelsHigh * 70 / 100)
            for x in xRange {
                for y in yRange {
                    guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let luminance = relativeLuminance(colour)
                    lightest = max(lightest, luminance)
                    darkest = min(darkest, luminance)
                }
            }
        }
        guard lightest >= 0, darkest <= 1 else {
            XCTFail("could not rasterize the button under \(name.rawValue)")
            return 0
        }
        return (lightest + 0.05) / (darkest + 0.05)
    }

    /// WCAG 2.1 relative luminance: linearize each sRGB channel, then weight
    /// by the eye's sensitivity to it.
    private func relativeLuminance(_ colour: NSColor) -> Double {
        func linear(_ channel: CGFloat) -> Double {
            let c = Double(channel)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.redComponent)
            + 0.7152 * linear(colour.greenComponent)
            + 0.0722 * linear(colour.blueComponent)
    }

    private func freshState(locale: String, osMajorVersion: Int = 27) -> AppState {
        let state = AppState(
            persistence: Persistence(suiteName: "test.\(UUID().uuidString)"),
            osMajorVersion: osMajorVersion
        )
        state.locale = locale
        state.isOn = true
        state.pwmSafe = true
        return state
    }

    /// Returns the hosted view's fitting size; writes a PNG when asked.
    @discardableResult
    private func render<V: View>(_ view: V, name: String) -> CGSize {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()

        if let dir = ProcessInfo.processInfo.environment["DIMIT_RENDER_DIR"],
           let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
            }
        }
        return size
    }
}
