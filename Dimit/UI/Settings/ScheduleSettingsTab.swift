import SwiftUI

/// ARCHITECTURE.md §10 / CLAUDE.md §3.8. The tab C4 explicitly omitted
/// ("Schedule tab in Settings" arrives with C5) now exists.
struct ScheduleSettingsTab: View {
    @ObservedObject var appState: AppState

    // Lazy, not eagerly constructed: this view rebuilds on every AppState
    // change (including every schedule tick's own writes), and a plain
    // `= LocationProvider()` default would allocate a fresh
    // CLLocationManager on each rebuild only to discard it — SwiftUI keeps
    // just the first result. Created once, on first actual use, in
    // requestLocation() below.
    @State private var locationProvider: LocationProvider?
    @State private var locationMessage: String?
    // True while a one-shot CoreLocation request is outstanding — disables
    // the button so a slow permission dialog or GPS fix can't be
    // double-clicked into two overlapping requests, the second of which
    // would silently replace `LocationProvider`'s single stored completion
    // and drop the first click's result forever (found by an independent
    // review).
    @State private var isRequestingLocation = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $appState.scheduleConfig.mode) {
                    Text("schedule.manual").tag(ScheduleMode.manual)
                    Text("schedule.sun").tag(ScheduleMode.sunsetToSunrise)
                    Text("schedule.fixed").tag(ScheduleMode.fixedTimes)
                    Text("schedule.bell").tag(ScheduleMode.bellCurve)
                } label: {
                    Text("schedule.mode_title")
                }
                .pickerStyle(.menu)
            }

            switch appState.scheduleConfig.mode {
            case .manual:
                // Manual has nothing to configure, but an `EmptyView` here
                // left the whole tab blank below the picker — reported as
                // "why this is empty do we really need it?". Manual is the
                // default, so that blank pane is what most people see the
                // first time they open this tab, and it reads as broken
                // rather than as "no schedule". One line saying what the
                // mode means, and what the other two would do, costs
                // nothing and answers the question in place.
                Section {
                    Text("schedule.manual_help")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .sunsetToSunrise:
                locationSection
                timeSection(title: "schedule.bedtime", binding: $appState.scheduleConfig.bedtime)
                rampSection
            case .fixedTimes:
                timeSection(title: "schedule.fixed_day_start", binding: $appState.scheduleConfig.fixedDayStart)
                timeSection(title: "schedule.fixed_evening_start", binding: $appState.scheduleConfig.fixedEveningStart)
                timeSection(title: "schedule.bedtime", binding: $appState.scheduleConfig.bedtime)
                rampSection
            case .bellCurve:
                bellSection
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Sunset -> Sunrise: location

    @ViewBuilder
    private var locationSection: some View {
        Section {
            HStack {
                Button {
                    requestLocation()
                } label: {
                    Text("schedule.use_location")
                }
                .disabled(isRequestingLocation)
                if let locationMessage {
                    Text(locationMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Picker(selection: cityBinding) {
                // Not "No location set": the picker's empty row sat
                // directly above a caption reading "Using your location ·
                // Tashkent", so the two lines contradicted each other. This
                // row means "no city chosen", which is true either way; the
                // caption below is the one that reports the real state.
                Text("schedule.city_choose").tag(Optional<String>.none)
                ForEach(CityList.all) { city in
                    Text(city.titleKey).tag(Optional(city.id))
                }
            } label: {
                Text("schedule.city")
            }

            Text(currentLocationDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var cityBinding: Binding<String?> {
        Binding(
            get: { appState.scheduleConfig.selectedCityID },
            set: { newID in
                guard let newID, let city = CityList.city(id: newID) else {
                    appState.scheduleConfig.selectedCityID = nil
                    return
                }
                appState.scheduleConfig.selectedCityID = newID
                appState.scheduleConfig.location = city.coordinate
                locationMessage = nil
            }
        )
    }

    private var currentLocationDescription: String {
        if let cityID = appState.scheduleConfig.selectedCityID, let city = CityList.city(id: cityID) {
            return appState.localized("schedule.location_using_city", appState.localized(city.titleKey))
        }
        // A location the device reported. This used to read "Using manual
        // coordinates" — the only non-city branch there was — so granting
        // location access told you the wrong thing and named nothing.
        // Name the nearest city offline when there is one; otherwise show
        // the actual numbers, which is at least true.
        if let location = appState.scheduleConfig.location {
            let place = CityList.nearest(to: location).map { appState.localized($0.titleKey) }
                ?? String(format: "%.2f, %.2f", location.latitude, location.longitude)
            return appState.localized("schedule.location_using_device", place)
        }
        return appState.localized("schedule.location_none")
    }

    private func requestLocation() {
        locationMessage = nil
        isRequestingLocation = true
        let provider = locationProvider ?? LocationProvider()
        locationProvider = provider
        provider.requestOneTimeLocation { result in
            isRequestingLocation = false
            switch result {
            case .success(let coordinate):
                appState.scheduleConfig.location = coordinate
                appState.scheduleConfig.selectedCityID = nil
                locationMessage = nil
            case .denied:
                locationMessage = appState.localized("schedule.location_denied")
            case .failed:
                locationMessage = appState.localized("schedule.location_failed")
            }
        }
    }

    // MARK: - Shared rows

    private var bellSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                bellPreview
                    .frame(height: 54)
                    .accessibilityHidden(true)
                Text("schedule.bell_help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DatePicker(selection: timeOfDayAsDate($appState.scheduleConfig.fixedDayStart), displayedComponents: .hourAndMinute) {
                Text("schedule.wake")
            }
            DatePicker(selection: timeOfDayAsDate($appState.scheduleConfig.peakTime), displayedComponents: .hourAndMinute) {
                Text("schedule.peak")
            }
            DatePicker(selection: timeOfDayAsDate($appState.scheduleConfig.bedtime), displayedComponents: .hourAndMinute) {
                Text("schedule.bedtime")
            }
            brightnessRow(title: "schedule.low_brightness", binding: Binding(
                get: { appState.scheduleConfig.lowBrightness },
                set: {
                    appState.scheduleConfig.lowBrightness = $0
                    appState.scheduleConfig.peakBrightness = max($0, appState.scheduleConfig.peakBrightness)
                }
            ))
            brightnessRow(title: "schedule.peak_brightness", binding: Binding(
                get: { appState.scheduleConfig.peakBrightness },
                set: {
                    appState.scheduleConfig.peakBrightness = $0
                    appState.scheduleConfig.lowBrightness = min($0, appState.scheduleConfig.lowBrightness)
                }
            ))
            if ScheduleEngine.bellTimes(on: Date(), config: appState.scheduleConfig, calendar: .current) == nil {
                Text("schedule.bell_invalid")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func brightnessRow(title: LocalizedStringResource, binding: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .frame(width: 175, alignment: .leading)
            Slider(value: binding, in: Config.minBrightness...Config.maxBrightness, step: 0.01)
                .accessibilityLabel(Text(title))
            Text(ValueFormatting.brightness(binding.wrappedValue))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
        }
    }

    private var bellPreview: some View {
        let config = appState.scheduleConfig
        let calendar = Calendar.current
        let times = ScheduleEngine.bellTimes(on: Date(), config: config, calendar: calendar)
        let samples: [(x: Double, target: ScheduleEngine.Resolution)] = (0...144).compactMap { index in
            guard let times,
                  let end = calendar.date(byAdding: .day, value: 1, to: times.wake) else { return nil }
            let x = Double(index) / 144
            let date = times.wake.addingTimeInterval(end.timeIntervalSince(times.wake) * x)
            let phases = ScheduleEngine.phases(coveringDayOf: date, mode: .bellCurve, config: config, calendar: calendar)
            guard let target = ScheduleEngine.target(at: date, phases: phases, values: appState.values(for:)) else { return nil }
            return (x, target)
        }
        let gradient = Gradient(stops: samples.map { sample in
            let rgb = WarmthCurve.rgb(kelvin: sample.target.warmthK)
            return Gradient.Stop(color: Color(red: rgb.r, green: rgb.g, blue: rgb.b), location: sample.x)
        })
        return GeometryReader { geometry in
            let huePath = Path { path in
                for (index, sample) in samples.enumerated() {
                    let point = CGPoint(x: sample.x * geometry.size.width,
                                        y: (1 - sample.target.warmthK / Config.maxWarmthK) * (geometry.size.height - 6) + 3)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            ZStack {
                Path { path in
                    for (index, sample) in samples.enumerated() {
                        let point = CGPoint(x: sample.x * geometry.size.width,
                                            y: (1 - sample.target.brightness) * (geometry.size.height - 6) + 3)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                // A thin outline keeps the neutral (white) peak visible
                // in light appearance as well as dark appearance.
                huePath.stroke(.primary.opacity(0.35), lineWidth: 5)
                huePath.stroke(LinearGradient(gradient: gradient, startPoint: .leading, endPoint: .trailing),
                               style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }
    }

    private func timeSection(title: LocalizedStringResource, binding: Binding<TimeOfDay>) -> some View {
        Section {
            DatePicker(
                selection: timeOfDayAsDate(binding),
                displayedComponents: .hourAndMinute
            ) {
                Text(title)
            }
        }
    }

    /// `DatePicker` needs a `Date`; `TimeOfDay` only ever cares about
    /// hour/minute, so this projects through a fixed reference date rather
    /// than adding a second representation of the same information.
    private func timeOfDayAsDate(_ binding: Binding<TimeOfDay>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: binding.wrappedValue.hour, minute: binding.wrappedValue.minute, second: 0, of: Date()) ?? Date()
            },
            set: { newDate in
                let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                binding.wrappedValue = TimeOfDay(hour: components.hour ?? 0, minute: components.minute ?? 0)
            }
        )
    }

    private var rampSection: some View {
        Section {
            // Was labelled just "Transition · 20 min", which the owner read
            // and asked "what is transition? it is not understandable".
            // It is the fade between presets; the label now says so and the
            // caption explains why you would want it long or short.
            Stepper(
                value: $appState.scheduleConfig.rampMinutes,
                // From 0, not 1: the caption offers "set it to 0 to switch
                // instantly", and `ScheduleEngine` already treats a
                // zero-length ramp as jumping straight to the target
                // (`duration > 0 ? … : 1.0`). A promise the stepper could
                // not actually reach would be worse than not offering it.
                in: 0...120,
                step: 5
            ) {
                HStack {
                    Text("schedule.transition")
                    Spacer()
                    Text(appState.localized("schedule.ramp_minutes_value", appState.scheduleConfig.rampMinutes))
                        .foregroundStyle(.secondary)
                }
            }
            Text("schedule.transition_help")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
