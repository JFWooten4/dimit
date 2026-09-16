import SwiftUI

/// ARCHITECTURE.md §10: "Onboarding (3 steps, first launch only):
/// headline, screenshots-stay-normal, no-account-no-tracking with the
/// updates opt-in checkbox and a 'Restore colours' safety button."
///
/// The updates checkbox defaults to off and writes straight to
/// `appState.updateChecksEnabled` — CLAUDE.md §1.2 "opt-in", §7 "default
/// off to honour zero network." Nothing here makes a network call; C7
/// reads the flag when Sparkle arrives.
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let restoreColours: () -> Void
    let finish: () -> Void

    @State private var step = 0
    private let stepCount = 3

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Group {
                switch step {
                case 0: stepOne
                case 1: stepTwo
                default: stepThree
                }
            }
            .frame(maxWidth: .infinity)
            .transition(.opacity)

            Spacer(minLength: 0)

            HStack {
                pageDots
                Spacer()
                Button {
                    if step < stepCount - 1 {
                        withAnimation { step += 1 }
                    } else {
                        finish()
                    }
                } label: {
                    Text(step < stepCount - 1 ? "onboarding.next" : "onboarding.get_started")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 460, height: 360)
        .environment(\.locale, appState.effectiveLocale)
    }

    private var stepOne: some View {
        VStack(spacing: 12) {
            Image(systemName: "sun.max.trianglebadge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("onboarding.1.title").font(.title2.bold())
            Text("onboarding.1.body")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepTwo: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.blue)
            Text("onboarding.2.title").font(.title2.bold())
            Text("onboarding.2.body")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stepThree: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("onboarding.3.title").font(.title2.bold())
            Text("onboarding.3.body")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $appState.updateChecksEnabled) {
                Text("settings.updates")
            }
            .toggleStyle(.checkbox)
            .padding(.top, 8)

            // The "for safety" button: if anything about the first ON
            // leaves the screen wrong, this is one click away without
            // needing to find the menu-bar icon first.
            Button {
                restoreColours()
            } label: {
                Text("menu.restore_colours")
            }
            .buttonStyle(.bordered)
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { index in
                Circle()
                    .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }
}
