import AVFoundation
import SwiftUI

struct NotchView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var weatherScrollTarget: Int? = 0
    @State private var calendarDatesVisible = true

    var body: some View {
        ZStack(alignment: .top) {
            surface
                .frame(width: surfaceSize.width, height: surfaceSize.height)

            if model.presentation != .hidden {
                presentationContent
                    .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
                    .clipped()
                    .foregroundStyle(.white)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.985, anchor: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            if model.isVolumeActivityVisible && model.isExpanded {
                volumeActivity
                .padding(.leading, 18)
                .frame(width: surfaceSize.width, height: model.notchHeight, alignment: .leading)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -3)))
                .allowsHitTesting(false)
            }
        }
        .frame(width: NotchGeometry.maximumPanelSize.width, height: NotchGeometry.maximumPanelSize.height, alignment: .top)
        .animation(morphAnimation, value: model.presentation)
        .animation(reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.28, bounce: 0.04), value: model.isVolumeActivityVisible)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Interactive notch")
    }

    private var surface: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: collapsedSurface ? 15 : 30,
            bottomTrailingRadius: collapsedSurface ? 15 : 30,
            topTrailingRadius: 0,
            style: .continuous
        )
        return shape
        .fill(Color(red: 0, green: 0, blue: 0))
        .compositingGroup()
    }

    @ViewBuilder
    private var presentationContent: some View {
        switch model.presentation {
        case .hidden:
            EmptyView()
        case .startup:
            StartupConfirmationView(onFinished: model.finishStartupActivity)
                .padding(.bottom, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case .compactMedia:
            compactActivity(showArtwork: true, showTimer: false, finished: false)
                .transaction { $0.animation = nil }
        case .compactTimer:
            compactActivity(showArtwork: false, showTimer: true, finished: false)
                .transaction { $0.animation = nil }
        case .compactMediaAndTimer:
            compactActivity(showArtwork: true, showTimer: true, finished: false)
                .transaction { $0.animation = nil }
        case .compactCharging:
            compactChargingActivity
        case .timerFinished:
            compactActivity(showArtwork: false, showTimer: true, finished: true)
                .transaction { $0.animation = nil }
        case .dashboard:
            expandedChrome { dashboard }
                .transition(widgetTransition(for: model.lastDetailModule))
        case .detail(let module):
            expandedChrome { detail(module) }
                .transition(widgetTransition(for: module))
        case .customize:
            expandedChrome { customizeDashboard }
        case .mirror:
            expandedChrome { mirrorDetail }
        }
    }

    private func compactActivity(showArtwork: Bool, showTimer: Bool, finished: Bool) -> some View {
        HStack(spacing: 0) {
            Group {
                if showArtwork {
                    artwork(size: 30, cornerRadius: 8)
                } else if finished {
                    Image(systemName: "timer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(moduleTint(.timer))
                        .symbolEffect(.pulse, options: .repeating)
                } else {
                    Image(systemName: "timer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(moduleTint(.timer).opacity(0.8))
                }
            }
            .frame(width: compactWingWidth)

            Spacer(minLength: model.notchWidth - 4)

            Group {
                if showTimer {
                    Button(action: finished ? model.acknowledgeTimer : {}) {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(finished ? "Done" : timerString(model.timer.remaining))
                                .font(.system(size: finished ? 9 : 12, weight: .semibold))
                                .monospacedDigit()
                                .contentTransition(reduceMotion ? .opacity : .numericText(value: model.timer.remaining.rounded(.up)))
                                .animation(timerDigitAnimation, value: model.timer.remaining.rounded(.up))
                            if !finished {
                                Text(model.timer.state == .paused ? "Paused" : "Timer")
                                    .font(.system(size: 7, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .foregroundStyle(finished ? moduleTint(.timer) : .white)
                    }
                    .buttonStyle(.plain)
                } else {
                    WaveformView(
                        isPlaying: model.media.isPlaying,
                        levels: model.spectrumLevels,
                        accent: mediaTint,
                        feedback: model.playbackFeedback
                    )
                    .frame(width: 34, height: 22)
                }
            }
            .frame(width: compactWingWidth)
        }
        .padding(.horizontal, 7)
        .padding(.bottom, 5)
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private var compactChargingActivity: some View {
        VStack(spacing: 6) {
            Color.clear.frame(height: model.notchHeight + 3)
            ChargingRingActivity(
                percent: model.battery.percentage,
                isCharging: model.battery.isCharging,
                pulseID: model.chargingPulseID
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var volumeActivity: some View {
        HStack(spacing: 7) {
                Image(systemName: volumeSymbol)
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .font(.system(size: 12))
                    .frame(width: 16)
            GeometryReader { geometry in
                Capsule().fill(.white.opacity(0.18))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white)
                            .frame(width: geometry.size.width * CGFloat(model.volume))
                    }
                    .clipped()
            }
            .frame(height: 4)
            Text("\(Int((model.volume * 100).rounded()))%")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double((model.volume * 100).rounded())))
                .frame(width: 28, alignment: .trailing)
        }
        .frame(width: min(156, max(96, (surfaceSize.width - model.notchWidth) / 2 - 36)))
        .foregroundStyle(.white.opacity(0.85))
        .animation(reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.22, bounce: 0), value: model.volume)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue(model.volume <= 0.01 ? "Muted" : "\(Int((model.volume * 100).rounded())) percent")
    }

    private func expandedChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(model.notchHeight, 30))
            if model.presentation != .dashboard {
                navigationRail.frame(height: model.presentation == .customize ? 24 : 30)
            }
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var navigationRail: some View {
        HStack(spacing: 8) {
            Text(navigationTitle)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.6))
            Text(model.presentation == .customize ? "Move to notch for Home" : "Move to notch to return")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.38))
            Spacer(minLength: 8)
            if model.presentation == .customize {
                Text("\(model.dashboardWidgets.count)/4 pinned")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 22)
    }

    private var dashboard: some View {
        HStack(spacing: 8) {
            ForEach(Array(DashboardLayout.columns(for: model.dashboardWidgets).enumerated()), id: \.offset) { _, column in
                VStack(spacing: 8) {
                    ForEach(column) { widget in
                        dashboardWidget(widget, compact: column.count == 2)
                            .frame(height: column.count == 2 ? 65 : 138)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 138, alignment: .top)
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func dashboardWidget(_ widget: DashboardWidget, compact: Bool) -> some View {
        Group {
            if compact {
                smallDashboardWidget(widget.module)
            } else {
                Group {
                    switch widget.module {
                    case .media: mediaDashboard
                    case .today: calendarDashboard(narrow: model.dashboardWidgets.count >= 3)
                    case .weather: weatherDashboard(narrow: model.dashboardWidgets.count >= 3)
                    case .system: batteryDashboard(compact: false)
                    case .timer: timerDashboard(compact: false)
                    case .mirror: largeUtilityWidget(widget.module)
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.065), lineWidth: 0.5))
    }

    @ViewBuilder
    private func smallDashboardWidget(_ module: DashboardModule) -> some View {
        if module == .media {
            VStack(alignment: .leading, spacing: 3) {
                Button { model.openDetail(.media) } label: {
                    HStack(spacing: 5) {
                        artwork(size: 20, cornerRadius: 5)
                        Text(model.media.hasMedia ? model.media.title : "Media")
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 1) {
                    compactTransportButton("backward.fill", label: "Previous track", action: model.previousTrack)
                    compactTransportButton(model.media.isPlaying ? "pause.fill" : "play.fill", label: "Play or pause", action: model.togglePlayPause)
                    compactTransportButton("forward.fill", label: "Next track", action: model.nextTrack)
                }
            }
            .padding(7)
        } else if module == .system {
            batteryDashboard(compact: true)
                .padding(8)
        } else if module == .timer {
            timerDashboard(compact: true)
                .padding(8)
        } else {
            Button { model.openDetail(module) } label: {
                HStack(spacing: 8) {
                    Image(systemName: module.symbolName)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(moduleTint(module))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(smallWidgetValue(module))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(module == .timer && !reduceMotion ? .numericText(value: model.timer.remaining.rounded(.up)) : .opacity)
                            .animation(module == .timer ? timerDigitAnimation : nil, value: model.timer.remaining.rounded(.up))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text(module.title)
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(DashboardModuleButtonStyle())
            .padding(8)
        }
    }

    private func largeUtilityWidget(_ module: DashboardModule) -> some View {
        Button { model.openDetail(module) } label: {
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: module.symbolName)
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(moduleTint(module))
                Spacer(minLength: 0)
                Text(largeWidgetValue(module))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(module == .timer && !reduceMotion ? .numericText(value: model.timer.remaining.rounded(.up)) : .opacity)
                    .animation(module == .timer ? timerDigitAnimation : nil, value: model.timer.remaining.rounded(.up))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(module.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardModuleButtonStyle())
    }

    private func timerDigits(fontSize: CGFloat) -> some View {
        let reading = CountdownReading(seconds: timerDisplaySeconds)
        return Text(reading.formatted)
            .font(.system(size: fontSize, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(moduleTint(.timer))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .contentTransition(reduceMotion ? .opacity : .numericText(value: reading.seconds))
            .animation(timerDigitAnimation, value: reading.seconds)
            .accessibilityLabel("Timer, \(reading.formatted) remaining")
    }

    @ViewBuilder
    private func timerDashboard(compact: Bool) -> some View {
        if compact {
            HStack(spacing: 8) {
                Button { model.openDetail(.timer) } label: {
                    timerDigits(fontSize: 14)
                        .frame(width: 62, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DashboardModuleButtonStyle())
                timerHomeAction(compact: true)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button { model.openDetail(.timer) } label: {
                    timerDigits(fontSize: 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 54)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DashboardModuleButtonStyle())
                Spacer(minLength: 0)
                timerHomeAction(compact: false)
            }
        }
    }

    private func timerHomeAction(compact: Bool) -> some View {
        Button { model.openDetail(.timer) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timer")
                    .font(.system(size: compact ? 12 : 18, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(model.timer.isActive || model.timer.isFinished ? timerStatusText : "Set a timer")
                    .font(.system(size: compact ? 8 : 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardModuleButtonStyle())
        .accessibilityLabel("Open timer controls")
    }

    private func batteryDashboard(compact: Bool) -> some View {
        Button { model.openDetail(.system) } label: {
            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                HStack(spacing: 8) {
                    Image(systemName: model.battery.symbolName)
                        .font(.system(size: compact ? 16 : 22, weight: .regular))
                        .contentTransition(.symbolEffect(.replace))
                    Text(model.battery.isAvailable ? "\(model.battery.percentage)%" : "—")
                        .font(.system(size: compact ? 17 : 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(batteryTint)

                if !compact {
                    Spacer(minLength: 0)
                    Text(model.battery.isAvailable ? model.battery.timeRemainingDescription : "Battery unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                batteryChargeBar(height: compact ? 4 : 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardModuleButtonStyle())
        .accessibilityLabel("Open Battery details")
        .accessibilityValue(model.battery.isAvailable ? "\(model.battery.percentage) percent" : "Battery unavailable")
    }

    private func batteryChargeBar(height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule()
                    .fill(batteryTint)
                    .frame(width: geometry.size.width * batteryProgress)
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.32, dampingFraction: 0.88), value: model.battery.percentage)
        .accessibilityHidden(true)
    }

    private func weatherDashboard(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { model.openDetail(.weather) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.weather.placeName ?? "Local forecast")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        WeatherSymbol(symbol: WeatherCondition.symbol(for: model.weather.conditionCode, isDay: model.weather.isDay), size: 19)
                            .frame(width: 24)
                        Text(model.weather.access == .ready ? "\(model.weather.temperature)°" : "Weather")
                            .font(.system(size: model.weather.access == .ready ? 25 : 17, weight: .regular))
                            .contentTransition(.numericText())
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(DashboardModuleButtonStyle())
            .accessibilityLabel("Open Weather forecast")

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if model.weather.access == .ready && !model.weather.days.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(model.weather.days.prefix(narrow ? 2 : 3)) { day in
                        weatherDayButton(day)
                    }
                }
            } else {
                Button { model.openDetail(.weather) } label: {
                    Text("Open for forecast")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func weatherDayButton(_ day: WeatherDay) -> some View {
        Button { model.openWeatherDay(day.date) } label: {
            VStack(spacing: 4) {
                Text(Calendar.current.isDateInToday(day.date) ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(height: 10)
                WeatherSymbol(symbol: WeatherCondition.symbol(for: day.conditionCode), size: 14)
                    .frame(height: 20)
                Text("\(day.high)°")
                .foregroundStyle(.white)
                .font(.system(size: 9))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardModuleButtonStyle())
        .accessibilityLabel("Hourly forecast for \(day.date.formatted(date: .complete, time: .omitted))")
    }

    private func smallWidgetValue(_ module: DashboardModule) -> String {
        switch module {
        case .media: return model.media.hasMedia ? model.media.title : "Media"
        case .today: return model.selectedCalendarDate.formatted(.dateTime.day())
        case .timer: return model.timer.isActive ? timerString(model.timer.remaining) : "Start"
        case .system: return model.battery.isAvailable ? "\(model.battery.percentage)%" : "—"
        case .weather: return model.weather.access == .ready ? "\(model.weather.temperature)°" : "—"
        case .mirror: return "Open"
        }
    }

    private func largeWidgetValue(_ module: DashboardModule) -> String {
        switch module {
        case .timer: return model.timer.isActive ? timerString(model.timer.remaining) : "Set a timer"
        case .system: return model.battery.timeRemainingDescription
        case .weather: return model.weather.access == .ready
            ? "\(model.weather.temperature)° · \(model.weather.placeName ?? "Nearby")"
            : "Local weather"
        case .mirror: return "Front camera"
        default: return smallWidgetValue(module)
        }
    }

    private var customizeDashboard: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(DashboardModule.allCases) { module in
                    galleryTile(module)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
    }

    private func galleryTile(_ module: DashboardModule) -> some View {
        let pinned = model.dashboardWidgets.contains(where: { $0.module == module })
        return ZStack(alignment: .topTrailing) {
            Button { model.openGalleryPreview(module) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Text(module.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                        // Reserve the independent pin control's space without
                        // nesting one Button inside another.
                        Color.clear.frame(width: 28, height: 25)
                    }
                    HStack(spacing: 8) {
                        if module == .media {
                            artwork(size: 24, cornerRadius: 5)
                        } else {
                            Image(systemName: module.symbolName)
                                .font(.system(size: 17, weight: .regular))
                                .foregroundStyle(moduleTint(module))
                                .frame(width: 24, height: 24)
                        }
                        Text(galleryPrimary(module))
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(height: 68)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(pinned ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(pinned ? moduleTint(module).opacity(0.26) : Color.white.opacity(0.06), lineWidth: 0.75))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(SubtlePressButtonStyle())
            .accessibilityLabel("Open \(module.title) preview")

            Button { _ = model.setWidgetEnabled(module, enabled: !pinned) } label: {
                Image(systemName: pinned ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(pinned ? moduleTint(module) : .white.opacity(0.45))
                    .frame(width: 28, height: 25)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled((!pinned && model.dashboardWidgets.count >= 4) || (pinned && model.dashboardWidgets.count == 1))
            .accessibilityLabel(pinned ? "Unpin \(module.title)" : "Pin \(module.title)")
            .padding(.top, 7)
            .padding(.trailing, 10)
        }
    }

    private func galleryPrimary(_ module: DashboardModule) -> String {
        switch module {
        case .media: return model.media.hasMedia ? model.media.title : "Nothing playing"
        case .today: return model.currentDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        case .timer: return model.timer.isActive ? timerString(model.timer.remaining) : "Ready to start"
        case .system: return model.battery.isAvailable ? "\(model.battery.percentage)% battery" : "Battery unavailable"
        case .weather: return model.weather.access == .ready ? "\(model.weather.temperature)° · \(WeatherCondition.description(for: model.weather.conditionCode))" : "Local forecast"
        case .mirror: return "Front camera"
        }
    }

    private var mirrorDetail: some View {
        ZStack {
            if model.mirrorState == .running || model.mirrorState == .starting {
                CameraPreviewView(
                    session: model.cameraSession,
                    onReady: model.mirrorPreviewAttached,
                    onDetached: model.mirrorPreviewDetached
                )
                    .overlay(alignment: .bottomLeading) {
                        Label("Mirror", systemImage: "camera.fill")
                            .font(.system(size: 10, weight: .medium))
                            .padding(10)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(14)
                    }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: model.mirrorState == .denied ? "camera.fill" : "web.camera")
                        .font(.system(size: 34))
                        .foregroundStyle(.white.opacity(0.65))
                    Text(mirrorStatusTitle)
                        .font(.system(size: 14, weight: .semibold))
                    if model.mirrorState == .denied {
                        Button("Open Camera Settings", action: model.openCameraSettings)
                            .buttonStyle(PillButtonStyle(tint: .white))
                    } else if model.mirrorState == .unavailable {
                        Button("Try again", action: model.openMirror)
                            .buttonStyle(PillButtonStyle(tint: .white))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private var mirrorStatusTitle: String {
        switch model.mirrorState {
        case .preview: return "Open Mirror to use your camera"
        case .requestingPermission: return "Allow camera access…"
        case .starting: return "Starting camera…"
        case .running: return "Mirror"
        case .denied: return "Camera access is off"
        case .unavailable: return "Camera couldn't start"
        }
    }

    private var mediaDashboard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { model.openDetail(.media) } label: {
                HStack(spacing: 12) {
                    artwork(size: 54, cornerRadius: 8)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.media.hasMedia ? model.media.title : "Nothing playing")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                        Text(model.media.hasMedia ? artistName : "Media ready")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(DashboardModuleButtonStyle())

            Spacer(minLength: 0)

            NotchSlider(
                value: Binding(get: { model.displayedElapsedTime }, set: model.updateSeek),
                range: 0...max(model.media.duration, 1),
                isEnabled: model.media.hasMedia && model.media.duration > 0,
                accent: mediaTint,
                onEditingChanged: model.setSeeking
            )
            .frame(height: 13)
            .accessibilityLabel("Track progress")

            HStack(spacing: 18) {
                dashboardTransportButton("backward.fill", label: "Previous track", action: model.previousTrack)
                dashboardTransportButton(model.media.isPlaying ? "pause.fill" : "play.fill", label: model.media.isPlaying ? "Pause" : "Play", action: model.togglePlayPause)
                dashboardTransportButton("forward.fill", label: "Next track", action: model.nextTrack)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func calendarDashboard(narrow: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Button { model.openDetail(.today) } label: {
                    Text(model.selectedCalendarDate.formatted(narrow ? .dateTime.month(.abbreviated) : .dateTime.month(.wide).year()))
                        .font(.system(size: narrow ? 10 : 12, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Calendar details")
                calendarNavigationButton("chevron.left", label: "Previous day", width: narrow ? 20 : 25) { model.moveCalendarSelection(byDays: -1) }
                calendarNavigationButton("chevron.right", label: "Next day", width: narrow ? 20 : 25) { model.moveCalendarSelection(byDays: 1) }
            }

            calendarWeekStrip(narrow: narrow, compactHome: narrow)

            Button { model.openDetail(.today) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    calendarHomeSummary(maxEvents: narrow ? 1 : 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open calendar events")
        }
    }

    private func calendarWeekStrip(narrow: Bool, compactHome: Bool = false) -> some View {
        HStack(spacing: narrow ? 1 : 3) {
            ForEach(compactHome ? compactCalendarDates : homeCalendarDates, id: \.self) { date in
                    Button {
                        model.selectCalendarDate(date)
                    } label: {
                        VStack(spacing: 5) {
                            Text(date.formatted(.dateTime.weekday(.narrow)))
                                .font(.system(size: 8, weight: .regular))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(height: 10)
                            Text(date.formatted(.dateTime.day()))
                                .font(.system(size: narrow ? 9 : 10, weight: .regular))
                                .monospacedDigit()
                                .frame(width: narrow ? 16 : 22, height: narrow ? 16 : 22)
                                .background(isSelectedCalendarDate(date) ? Color(nsColor: .systemRed) : .clear, in: Circle())
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: narrow ? 35 : 38)
                        .contentShape(Rectangle())
                        .animation(calendarMotion, value: isSelectedCalendarDate(date))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
            }
        }
    }

    @ViewBuilder
    private func detail(_ module: DashboardModule) -> some View {
        switch module {
        case .media: mediaDetail
        case .today: todayDetail
        case .timer: timerDetail
        case .system: systemDetail
        case .weather: weatherDetail
        case .mirror: mirrorDetail
        }
    }

    private var weatherDetail: some View {
        let hourly = model.weatherForecastMode == .hours
        let hour = hourly ? model.weather.summaryHour(on: model.selectedWeatherDate, at: model.currentDate, page: weatherScrollTarget ?? 0) : nil
        let showsCurrent = !hourly || (Calendar.current.isDateInToday(model.selectedWeatherDate) && (weatherScrollTarget ?? 0) == 0)
        let temperature: Int? = showsCurrent ? model.weather.temperature : hour?.temperature
        let condition = showsCurrent ? model.weather.conditionCode : hour?.conditionCode ?? model.weather.conditionCode
        let isDay = showsCurrent ? model.weather.isDay : hour?.isDay ?? true
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                if model.weather.access == .ready {
                    Text(model.weather.placeName ?? "Nearby")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    HStack(alignment: .center, spacing: 10) {
                        WeatherSymbol(symbol: WeatherCondition.symbol(for: condition, isDay: isDay), size: 27)
                        Text(temperature.map { "\($0)°" } ?? "—")
                            .font(.system(size: 42, weight: .regular, design: .rounded))
                            .contentTransition(.numericText())
                    }
                    Text(WeatherCondition.description(for: condition))
                        .font(.system(size: 11, weight: .regular))
                    if hourly {
                        Text(showsCurrent ? "Now" : hour?.time.formatted(.dateTime.hour()) ?? "No hourly data")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if let day = hourly ? model.selectedWeatherDay : model.weather.days.first {
                        Text("H:\(day.high)°  L:\(day.low)°")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                } else {
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(moduleTint(.weather))
                    Text(weatherStatusTitle)
                        .font(.system(size: 11, weight: .semibold))
                    Text(weatherStatusDetail)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                    if model.weather.access == .denied || model.weather.access == .error {
                        Button(model.weather.access == .denied ? "Open Settings" : "Try again") {
                            if model.weather.access == .denied {
                                model.openLocationSettings()
                            } else {
                                model.refreshWeather()
                            }
                        }
                            .buttonStyle(PillButtonStyle(tint: moduleTint(.weather)))
                    }
                }
                Spacer(minLength: 0)
                Text("Weather by Open-Meteo")
                    .font(.system(size: 8))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(width: 150, alignment: .leading)
            .modifier(detailEntrance(delay: 0))

            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1)

            VStack(alignment: .leading, spacing: 6) {
                weatherModeSelector
                // This row occupies the same space in both modes so labels,
                // symbols and temperatures share a stable vertical baseline.
                HStack(spacing: 6) {
                    Text(model.weatherForecastMode == .days ? "\(model.weather.days.count)-day forecast"
                         : Calendar.current.isDateInToday(model.selectedWeatherDate) ? "Today"
                         : model.selectedWeatherDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                    calendarNavigationButton("chevron.left", label: "Previous forecast day", width: 22) { model.moveWeatherDay(by: -1) }
                        .disabled(model.weatherForecastMode != .hours || model.weatherDay(by: -1) == nil)
                    calendarNavigationButton("chevron.right", label: "Next forecast day", width: 22) { model.moveWeatherDay(by: 1) }
                        .disabled(model.weatherForecastMode != .hours || model.weatherDay(by: 1) == nil)
                }
                .frame(height: 25)
                if model.weather.access == .ready {
                    weatherForecastStrip
                } else {
                    Text("Forecast appears after location access.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(weatherForecastAnimation, value: model.weatherForecastMode)
            .modifier(detailEntrance(delay: 0.045))
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    private var weatherModeSelector: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.06))
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))

            Color.clear
                .frame(width: 68, height: 22)
                .glassEffect(.regular.tint(Color(nsColor: .systemBlue).opacity(0.65)), in: Capsule())
                .offset(x: model.weatherForecastMode == .days ? 2 : 74)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                ForEach(WeatherForecastMode.allCases) { mode in
                    Button {
                        withAnimation(weatherForecastAnimation) {
                            model.setWeatherForecastMode(mode)
                        }
                    } label: {
                        Text(mode == .days ? "Days" : "Hours")
                            .font(.system(size: 10, weight: model.weatherForecastMode == mode ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(model.weatherForecastMode == mode ? 1 : 0.6))
                            .frame(width: 72, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(mode == .days ? "Daily forecast" : "Hourly forecast")
                    .accessibilityAddTraits(model.weatherForecastMode == mode ? .isSelected : [])
                }
            }
        }
        .frame(width: 144, height: 26)
        .environment(\.colorScheme, .dark)
        .animation(weatherForecastAnimation, value: model.weatherForecastMode)
    }

    private var weatherForecastAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.34, bounce: 0.1)
    }

    private var weatherForecastEntries: [WeatherForecastEntry] {
        if model.weatherForecastMode == .days {
            return model.weather.days.map { day in
                WeatherForecastEntry(
                    label: Calendar.current.isDateInToday(day.date) ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)),
                    symbol: WeatherCondition.symbol(for: day.conditionCode),
                    temperature: day.high,
                    precipitationChance: day.precipitationChance, day: day.date
                )
            }
        }
        // Today's forecast begins with the current hour, so the first visible
        // column never needs a late programmatic scroll during its entrance.
        let hours = model.weather.forecastHours(on: model.selectedWeatherDate, at: model.currentDate)
        return hours.map { hour in
            WeatherForecastEntry(
                label: hour.time.formatted(.dateTime.hour()),
                symbol: WeatherCondition.symbol(for: hour.conditionCode, isDay: hour.isDay),
                temperature: hour.temperature,
                precipitationChance: hour.precipitationChance, day: nil
            )
        }
    }

    private var weatherForecastStrip: some View {
        let entries = weatherForecastEntries
        return Group {
            if entries.isEmpty {
                Text("Forecast is unavailable for this day.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            ForEach(0..<ForecastPaging.pageCount(for: entries.count), id: \.self) { page in
                                HStack(alignment: .top, spacing: 0) {
                                    // Five fitted slots per page, including the final
                                    // partial page. No edge icon needs to peek or clip.
                                    ForEach(0..<ForecastPaging.itemsPerPage, id: \.self) { slot in
                                        let index = page * ForecastPaging.itemsPerPage + slot
                                        Group {
                                            if entries.indices.contains(index) {
                                                weatherForecastColumn(entries[index])
                                            } else {
                                                Color.clear
                                            }
                                        }
                                        .frame(width: max(0, geometry.size.width - 12) / CGFloat(ForecastPaging.itemsPerPage), height: 70, alignment: .top)
                                    }
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(width: geometry.size.width)
                                .id(page)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollPosition(id: $weatherScrollTarget, anchor: .leading)
                    .onChange(of: model.weatherForecastMode) { _, _ in
                        resetWeatherScrollPosition()
                    }
                    .onChange(of: model.selectedWeatherDate) { _, _ in
                        resetWeatherScrollPosition()
                    }
                    .onChange(of: entries.count) { _, count in
                        let lastPage = max(0, ForecastPaging.pageCount(for: count) - 1)
                        if (weatherScrollTarget ?? 0) > lastPage { resetWeatherScrollPosition() }
                    }
                }
            }
        }
        .frame(height: 74, alignment: .topLeading)
        .onDisappear { resetWeatherScrollPosition() }
    }

    private func resetWeatherScrollPosition() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { weatherScrollTarget = 0 }
    }

    private func weatherForecastColumn(_ entry: WeatherForecastEntry) -> some View {
        VStack(spacing: 5) {
            Text(entry.label)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 10)
                .contentTransition(reduceMotion ? .opacity : .numericText())
            WeatherSymbol(symbol: entry.symbol, size: 16)
                .frame(height: 20)
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            Text("\(entry.temperature)°")
            .font(.system(size: 12))
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(height: 14)
            Text("\(entry.precipitationChance)%")
                .font(.system(size: 8))
                .foregroundStyle(moduleTint(.weather))
                .frame(height: 10)
                .contentTransition(reduceMotion ? .opacity : .numericText())
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let day = entry.day else { return }
            withAnimation(weatherForecastAnimation) { model.openWeatherDay(day) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.day.map { "Hourly forecast for \($0.formatted(date: .complete, time: .omitted))" }
            ?? "\(entry.label), \(entry.temperature) degrees, \(entry.precipitationChance) percent chance of precipitation")
        .accessibilityAddTraits(entry.day == nil ? [] : .isButton)
        .accessibilityAction {
            guard let day = entry.day else { return }
            withAnimation(weatherForecastAnimation) { model.openWeatherDay(day) }
        }
    }

    private var mediaDetail: some View {
        HStack(spacing: 16) {
            Button(action: model.openMediaApp) {
                artwork(size: 104, cornerRadius: 8)
            }
            .buttonStyle(.plain)
            .disabled(model.media.sourceBundleIdentifier == nil)
            .accessibilityLabel("Open media source")
            .modifier(detailEntrance(delay: 0))

            VStack(alignment: .leading, spacing: 8) {
                Button(action: model.openMediaApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.media.hasMedia ? model.media.title : "No media available")
                            .font(.system(size: 17, weight: .semibold))
                            .lineLimit(1)
                        Text(model.media.hasMedia ? artistName : "Start playback in any media app")
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.media.sourceBundleIdentifier == nil)
                .accessibilityLabel("Open media source")

                mediaProgress

                HStack(spacing: 14) {
                    transportButton("backward.fill", action: model.previousTrack)
                    Button(action: model.togglePlayPause) {
                        Image(systemName: model.media.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 34, height: 34)
                            .foregroundStyle(.black)
                            .background(mediaTint, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.media.hasMedia)
                    transportButton("forward.fill", action: model.nextTrack)
                    Spacer()
                    compactVolume
                }
            }
            .modifier(detailEntrance(delay: 0.045))
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }

    private var todayDetail: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.selectedCalendarDate.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity)
                    .animation(calendarMotion, value: model.selectedCalendarDate)
                Button {
                    withAnimation(calendarMotion) { calendarDatesVisible = true }
                } label: {
                    Text(model.selectedCalendarDate.formatted(.dateTime.day()))
                        .font(.system(size: 30, weight: .regular))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(Calendar.current.component(.day, from: model.selectedCalendarDate))))
                        .animation(calendarMotion, value: model.selectedCalendarDate)
                        .frame(width: 52, height: 52)
                        .background(Color(nsColor: .systemRed), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(SubtlePressButtonStyle())
                .accessibilityLabel("Show calendar dates, \(model.selectedCalendarDate.formatted(date: .complete, time: .omitted))")
                Text(model.selectedCalendarDate.formatted(.dateTime.month(.wide)))
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.opacity)
                    .animation(calendarMotion, value: model.selectedCalendarDate)

                Spacer(minLength: 8)

                if hasGoogleCalendar {
                    Label("Google", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    Button { model.openInternetAccounts() } label: {
                        Text("Add Google")
                            .font(.system(size: 9, weight: .regular))
                            .padding(.horizontal, 9)
                            .frame(height: 24)
                            .foregroundStyle(.white)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                        .accessibilityLabel("Add Google Calendar account")
                }
            }
            .frame(width: 100, alignment: .leading)
            .modifier(detailEntrance(delay: 0))

            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1)

            VStack(alignment: .leading, spacing: 5) {
                if calendarDatesVisible {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(model.selectedCalendarDate.formatted(.dateTime.month(.wide).year()))
                                .font(.system(size: 10, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            calendarNavigationButton("chevron.left", label: "Previous week", width: 22) { model.moveCalendarSelection(byDays: -7) }
                            Button("Today") { model.selectCalendarDate(model.currentDate) }
                                .font(.system(size: 9))
                                .buttonStyle(.plain)
                            calendarNavigationButton("chevron.right", label: "Next week", width: 22) { model.moveCalendarSelection(byDays: 7) }
                        }
                        .frame(height: 22)
                        calendarWeekStrip(narrow: true)
                        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                    }
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: -6).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 7) {
                        calendarDetailContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(calendarMotion) { calendarDatesVisible = false }
                }
                .accessibilityAction(named: "Focus calendar events") {
                    withAnimation(calendarMotion) { calendarDatesVisible = false }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(detailEntrance(delay: 0.045))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .onAppear { calendarDatesVisible = true }
    }

    private var calendarMotion: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.28, bounce: 0)
    }

    @ViewBuilder
    private var calendarDetailContent: some View {
        switch model.calendar.access {
        case .preview:
            VStack(alignment: .leading, spacing: 8) {
                Text("See today’s upcoming events here.")
                    .font(.system(size: 12, weight: .medium))
                Text("Calendar access is requested only when you open Today.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.6))
            }
        case .denied:
            calendarMessage(symbol: "calendar.badge.exclamationmark", title: "Calendar access denied", detail: "Enable access in System Settings → Privacy & Security.")
        case .restricted:
            calendarMessage(symbol: "lock.fill", title: "Calendar is restricted", detail: "This Mac does not allow calendar access.")
        case .error:
            calendarMessage(symbol: "exclamationmark.triangle", title: "Couldn’t load Calendar", detail: model.calendar.errorMessage ?? "Try opening Today again.")
        case .authorized:
            if model.calendar.events.isEmpty {
                calendarMessage(symbol: "checkmark.circle", title: Calendar.current.isDateInToday(model.selectedCalendarDate) ? "Nothing else today" : "No events", detail: "Your calendar is clear.")
            } else {
                ForEach(model.calendar.events) { event in
                    HStack(spacing: 9) {
                        Capsule()
                            .fill(Color(red: event.color.red, green: event.color.green, blue: event.color.blue))
                            .frame(width: 3, height: 27)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                            Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 8.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    private var timerDetail: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.timer.state == .idle ? "Ready" : timerStatusText)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                timerDigits(fontSize: 36)
                    .frame(height: 76, alignment: .leading)
            }
            .frame(width: 150, alignment: .leading)
            .modifier(detailEntrance(delay: 0))

            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1)

            VStack(spacing: 13) {
                HStack(spacing: 8) {
                    ForEach([5, 10, 25], id: \.self) { minutes in
                        Button("\(minutes) min") { model.startTimer(minutes: minutes) }
                            .buttonStyle(PillButtonStyle(tint: moduleTint(.timer)))
                    }
                }

                HStack(spacing: 9) {
                    timerAdjustmentButton(symbol: "minus", label: "Decrease timer") {
                        model.adjustCustomTimerMinutes(by: -1)
                    }
                    Text("\(model.customTimerMinutes) min")
                        .font(.system(size: 11, weight: .regular))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(model.customTimerMinutes)))
                        .animation(timerDigitAnimation, value: model.customTimerMinutes)
                        .frame(width: 50)
                    timerAdjustmentButton(symbol: "plus", label: "Increase timer") {
                        model.adjustCustomTimerMinutes(by: 1)
                    }
                    Button("Start") { model.startCustomTimer() }.buttonStyle(PillButtonStyle(prominent: true, tint: moduleTint(.timer)))
                    Button("Clock", action: model.openClock).buttonStyle(PillButtonStyle(tint: moduleTint(.timer)))
                }

                if model.timer.state != .idle {
                    HStack(spacing: 8) {
                        if model.timer.isFinished {
                            Button("Dismiss", action: model.acknowledgeTimer)
                                .buttonStyle(PillButtonStyle(prominent: true, tint: moduleTint(.timer)))
                        } else {
                            Button(model.timer.state == .paused ? "Resume" : "Pause") {
                                model.timer.state == .paused ? model.resumeTimer() : model.pauseTimer()
                            }
                            .buttonStyle(PillButtonStyle(prominent: true, tint: moduleTint(.timer)))
                            Button("+1 min", action: model.addTimerMinute).buttonStyle(PillButtonStyle(tint: moduleTint(.timer)))
                            Button("Cancel", action: model.cancelTimer).buttonStyle(PillButtonStyle(tint: moduleTint(.timer)))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .modifier(detailEntrance(delay: 0.045))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private var systemDetail: some View {
        HStack(spacing: 22) {
            HStack(spacing: 13) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: batteryProgress * model.detailRevealProgress)
                        .stroke(batteryTint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(detailAnimation, value: model.detailRevealProgress)
                    Image(systemName: model.battery.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(batteryTint)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, options: .nonRepeating, value: model.chargingPulseID)
                }
                .frame(width: 65, height: 65)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.battery.isAvailable ? "\(model.battery.percentage)%" : "—")
                        .font(.system(size: 27, weight: .regular))
                        .foregroundStyle(batteryTint)
                        .contentTransition(.numericText())
                    Text(model.battery.isCharging ? "Charging" : "Battery")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 185, alignment: .leading)
            .modifier(detailEntrance(delay: 0))

            Rectangle().fill(Color.white.opacity(0.09)).frame(width: 1)

            VStack(alignment: .leading, spacing: 8) {
                Text(!model.battery.isAvailable ? "Battery status" : model.battery.isOnExternalPower ? "Power status" : "Estimated remaining")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))

                HStack(spacing: 9) {
                    Image(systemName: model.battery.isOnExternalPower ? "powerplug.fill" : "clock.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(batteryTint)
                    Text(model.battery.isAvailable ? model.battery.timeRemainingDescription : "Unavailable")
                        .font(.system(size: 24, weight: .regular))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }

                Text(!model.battery.isAvailable ? "Battery information isn’t available" : model.battery.isOnExternalPower ? "Connected to external power" : "Based on your Mac’s current energy use")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))

            }
            .modifier(detailEntrance(delay: 0.045))
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func timerAdjustmentButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(moduleTint(.timer))
                .background(moduleTint(.timer).opacity(0.16), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dashboardTransportButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .frame(width: 30, height: 30)
                .foregroundStyle(symbol == "play.fill" || symbol == "pause.fill" ? mediaTint : .white)
        }
        .buttonStyle(.plain)
        .disabled(!model.media.hasMedia)
        .accessibilityLabel(label)
    }

    private func compactTransportButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .regular))
                .frame(width: 25, height: 20)
                .foregroundStyle(symbol == "play.fill" || symbol == "pause.fill" ? mediaTint : .white)
        }
        .buttonStyle(.plain)
        .disabled(!model.media.hasMedia)
        .accessibilityLabel(label)
    }

    private func calendarNavigationButton(
        _ symbol: String,
        label: String,
        width: CGFloat = 25,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .regular))
                .frame(width: width, height: 25)
        }
        .buttonStyle(QuietButtonStyle())
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func calendarHomeSummary(maxEvents: Int) -> some View {
        switch model.calendar.access {
        case .authorized where !model.calendar.events.isEmpty:
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.calendar.events.prefix(maxEvents)) { event in
                    HStack(spacing: 7) {
                        Capsule()
                            .fill(Color(red: event.color.red, green: event.color.green, blue: event.color.blue))
                            .frame(width: 3, height: 20)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(event.title).font(.system(size: 9, weight: .semibold)).lineLimit(1)
                            Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 7.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        case .authorized:
            Label("No events", systemImage: "checkmark.circle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        case .denied, .restricted:
            Label("Calendar access unavailable", systemImage: "lock.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        case .error:
            Label("Couldn’t load events", systemImage: "exclamationmark.triangle")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        case .preview:
            Label("Open to connect Calendar", systemImage: "calendar.badge.plus")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private func artwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
        MediaArtworkView(image: model.media.artwork, size: size, cornerRadius: cornerRadius)
    }

    private var mediaProgress: some View {
        HStack(spacing: 7) {
            Text(timeString(model.displayedElapsedTime)).frame(width: 31, alignment: .trailing)
            NotchSlider(
                value: Binding(get: { model.displayedElapsedTime }, set: model.updateSeek),
                range: 0...max(model.media.duration, 1),
                isEnabled: model.media.hasMedia && model.media.duration > 0,
                accent: mediaTint,
                onEditingChanged: model.setSeeking
            )
            .frame(height: 14)
            Text("−" + timeString(max(model.media.duration - model.displayedElapsedTime, 0))).frame(width: 36, alignment: .leading)
        }
        .font(.system(size: 8.5, weight: .regular))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.6))
    }

    private var compactVolume: some View {
        HStack(spacing: 8) {
            Button(action: model.toggleMute) { Image(systemName: volumeSymbol).frame(width: 14) }
                .buttonStyle(QuietButtonStyle())
                .disabled(!model.isVolumeAvailable)
            NotchSlider(
                value: Binding(get: { Double(model.volume) }, set: { model.setVolume(Float($0)) }),
                range: 0...1,
                isEnabled: model.isVolumeAvailable,
                onEditingChanged: model.setVolumeEditing
            )
            .frame(width: 108, height: 14)
        }
    }

    private func transportButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .regular)).frame(width: 28, height: 30)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(!model.media.hasMedia)
    }

    private func calendarMessage(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
        }
    }

    private var surfaceSize: CGSize {
        switch model.presentation {
        case .hidden: return CGSize(width: model.notchWidth, height: model.notchHeight)
        case .startup:
            return CGSize(width: min(max(model.notchWidth + 40, 220), 300), height: model.notchHeight + 32)
        case .compactMedia, .compactTimer:
            return CGSize(width: min(model.notchWidth + 104, 330), height: model.notchHeight + 12)
        case .compactMediaAndTimer:
            return CGSize(width: min(model.notchWidth + 138, 360), height: model.notchHeight + 12)
        case .compactCharging:
            return CGSize(width: min(max(model.notchWidth + 130, 300), 380), height: model.notchHeight + 104)
        case .timerFinished:
            return CGSize(width: min(model.notchWidth + 150, 380), height: model.notchHeight + 14)
        case .dashboard: return CGSize(width: NotchGeometry.dashboardWidth, height: model.dashboardHeight)
        case .detail:
            return CGSize(width: NotchGeometry.detailSize.width, height: max(NotchGeometry.detailSize.height, model.dashboardHeight))
        case .customize: return NotchGeometry.customizeSize
        case .mirror: return NotchGeometry.mirrorSize
        }
    }

    private var collapsedSurface: Bool {
        model.presentation == .hidden || model.presentation == .startup || (model.presentation.isCompact && model.presentation != .compactCharging)
    }

    private var homeCalendarDates: [Date] {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: model.selectedCalendarDate)?.start
            ?? calendar.startOfDay(for: model.selectedCalendarDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var compactCalendarDates: [Date] {
        (-2...2).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: model.selectedCalendarDate) }
    }

    private func isSelectedCalendarDate(_ date: Date) -> Bool {
        Calendar.current.isDate(date, inSameDayAs: model.selectedCalendarDate)
    }

    private var compactWingWidth: CGFloat {
        max((surfaceSize.width - model.notchWidth - 14) / 2, 34)
    }

    private var morphAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .interpolatingSpring(mass: 0.75, stiffness: 330, damping: 23, initialVelocity: 0)
    }

    private var detailAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .interpolatingSpring(mass: 0.75, stiffness: 330, damping: 23, initialVelocity: 0)
    }

    private func detailEntrance(delay: Double) -> DetailEntrance {
        DetailEntrance(progress: model.detailRevealProgress, reduceMotion: reduceMotion, delay: delay)
    }

    private func widgetTransition(for module: DashboardModule) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .scale(scale: 0.94, anchor: widgetAnchor(for: module)).combined(with: .opacity),
            removal: .scale(scale: 0.94, anchor: widgetAnchor(for: module)).combined(with: .opacity)
        )
    }

    private func widgetAnchor(for module: DashboardModule) -> UnitPoint {
        switch module {
        case .media: return UnitPoint(x: 0.26, y: 0.56)
        case .today: return UnitPoint(x: 0.74, y: 0.56)
        case .timer: return UnitPoint(x: 0.85, y: 0.22)
        case .system: return UnitPoint(x: 0.94, y: 0.22)
        case .weather: return UnitPoint(x: 0.76, y: 0.22)
        case .mirror: return UnitPoint(x: 0.87, y: 0.22)
        }
    }

    private var navigationTitle: String {
        switch model.presentation {
        case .detail(let module): return module.title
        case .customize: return "Widgets"
        case .mirror: return "Mirror"
        default: return ""
        }
    }

    private var mediaTint: Color { Color(nsColor: model.accentColor) }

    private func moduleTint(_ module: DashboardModule) -> Color {
        switch module {
        case .media: return mediaTint
        case .today: return Color(nsColor: .systemRed)
        case .timer: return Color(nsColor: .systemOrange)
        case .system: return Color(nsColor: .systemGreen)
        case .weather: return Color(nsColor: .systemCyan)
        case .mirror: return Color(nsColor: .systemPurple)
        }
    }

    private var batteryTint: Color { Color(nsColor: .systemGreen) }

    private var weatherStatusTitle: String {
        switch model.weather.access {
        case .preview: return "Open for local weather"
        case .requestingPermission: return "Allow location access…"
        case .loading: return "Finding local weather…"
        case .denied: return "Location access off"
        case .restricted: return "Location unavailable"
        case .error: return "Weather unavailable"
        case .ready: return "Local weather"
        }
    }

    private var weatherStatusDetail: String {
        switch model.weather.access {
        case .denied: return "Enable Location Services for Interactive Notch in System Settings."
        case .restricted: return "Location Services are restricted on this Mac."
        case .error: return "Check your connection and try again."
        default: return "Your approximate location is used only for the forecast."
        }
    }

    private var artistName: String {
        model.media.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown artist" : model.media.artist
    }

    private var hasGoogleCalendar: Bool {
        model.calendar.accountNames.contains {
            let name = $0.lowercased()
            return name.contains("google") || name.contains("gmail")
        }
    }

    private var timerStatusText: String {
        switch model.timer.state {
        case .idle: return "Choose a focus timer"
        case .running: return "Running"
        case .paused: return "Paused"
        case .finished: return "Timer complete"
        }
    }

    private var timerDisplaySeconds: Double {
        model.timer.state == .idle ? Double(model.customTimerMinutes * 60) : model.timer.remaining.rounded(.up)
    }

    private var timerDigitAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.24, bounce: 0)
    }

    private var timerProgress: Double {
        guard model.timer.totalDuration > 0 else { return 0 }
        return min(max(1 - model.timer.remaining / model.timer.totalDuration, 0), 1)
    }

    private var batteryProgress: CGFloat {
        guard model.battery.isAvailable else { return 0 }
        return CGFloat(min(max(model.battery.percentage, 0), 100)) / 100
    }

    private var volumeSymbol: String {
        switch model.volume {
        case ...0.01: return "speaker.slash.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    private func timerString(_ value: TimeInterval) -> String {
        CountdownReading(seconds: value).formatted
    }

    private func timeString(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let seconds = Int(value.rounded(.down))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct MediaArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.white.opacity(0.09)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: max(10, cornerRadius * 1.2), weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
            }
        }
        // Bound the fill first, then crop. Clipping an unconstrained wide video
        // thumbnail before applying the frame lets it spill into adjacent UI.
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct WeatherSymbol: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Group {
            if symbol == "cloud.fog.fill" {
                ZStack {
                    Image(systemName: "cloud.fill")
                        .font(.system(size: size * 0.72, weight: .regular))
                        .foregroundStyle(.white.opacity(0.85))
                        .offset(y: -size * 0.22)
                    VStack(spacing: size * 0.085) {
                        ForEach([0.85, 1.05, 0.7], id: \.self) { width in
                            Capsule()
                                .fill(.white.opacity(0.55))
                                .frame(width: size * width, height: max(1, size * 0.065))
                        }
                    }
                    .offset(y: size * 0.32)
                }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .regular))
                    .symbolRenderingMode(.multicolor)
            }
        }
        .frame(width: size * 1.35, height: size * 1.2)
        .accessibilityHidden(true)
    }
}

private struct WeatherForecastEntry {
    let label: String
    let symbol: String
    let temperature: Int
    let precipitationChance: Int
    let day: Date?
}

private struct StartupConfirmationView: View {
    let onFinished: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var morph: CGFloat = 0

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.16))
                .frame(width: 72, height: 3)
                .opacity(Double(1 - morph))

            StartupConfirmationStroke(morph: morph)
                .trim(from: 0, to: progress)
                .stroke(
                    Color(red: 1 - Double(morph) * 0.8, green: 1 - Double(morph) * 0.22, blue: 1 - Double(morph) * 0.65),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 80, height: 24)
        }
        .frame(width: 80, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(morph < 1 ? "Starting Interactive Notch" : "Interactive Notch ready")
        .task {
            do {
                // Let the black silhouette settle before filling the bar.
                try await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .linear(duration: 0.01) : .smooth(duration: 0.55)) {
                    progress = 1
                }
                try await Task.sleep(for: .milliseconds(reduceMotion ? 100 : 600))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(duration: 0.34, bounce: 0.12)) {
                    morph = 1
                }
                try await Task.sleep(for: .milliseconds(reduceMotion ? 350 : 700))
                guard !Task.isCancelled else { return }
                onFinished()
            } catch {
                // Hover navigation cancels this task without completing over
                // the dashboard the user just opened.
            }
        }
    }
}

private struct StartupConfirmationStroke: Shape {
    var morph: CGFloat

    var animatableData: CGFloat {
        get { morph }
        set { morph = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Interpolate one continuous stroke from a full bar into a checkmark.
        // Keeping its identity avoids a jump between separate views.
        let start = CGPoint(x: rect.midX - 36 + 28 * morph, y: rect.midY)
        let elbow = CGPoint(x: rect.midX - 12 + 10 * morph, y: rect.midY + 6 * morph)
        let end = CGPoint(x: rect.midX + 36 - 26 * morph, y: rect.midY - 7 * morph)
        var path = Path()
        path.move(to: start)
        path.addLine(to: elbow)
        path.addLine(to: end)
        return path
    }
}

private struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let onReady: () -> Void
    let onDetached: () -> Void

    final class Coordinator {
        var isMounted = true
        let onDetached: () -> Void

        init(onDetached: @escaping () -> Void) { self.onDetached = onDetached }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDetached: onDetached) }

    func makeNSView(context: Context) -> MirrorPreviewNSView {
        let view = MirrorPreviewNSView(session: session)
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            if coordinator.isMounted { onReady() }
        }
        return view
    }

    func updateNSView(_ nsView: MirrorPreviewNSView, context: Context) {
        nsView.configureMirroring()
    }

    static func dismantleNSView(_ nsView: MirrorPreviewNSView, coordinator: Coordinator) {
        coordinator.isMounted = false
        DispatchQueue.main.async { coordinator.onDetached() }
    }
}

private final class MirrorPreviewNSView: NSView {
    private let captureSession: AVCaptureSession

    init(session: AVCaptureSession) {
        captureSession = session
        super.init(frame: .zero)
        wantsLayer = true
        configureMirroring()
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        return preview
    }

    func configureMirroring() {
        guard let connection = (layer as? AVCaptureVideoPreviewLayer)?.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}

private struct ChargingRingActivity: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let percent: Int
    let isCharging: Bool
    let pulseID: Int
    @State private var ringProgress: CGFloat = 0

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(Color(nsColor: .systemGreen), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                    .symbolEffect(.bounce, options: .nonRepeating, value: pulseID)
            }
            .frame(width: 62, height: 62)
            Text("\(max(0, min(percent, 100)))% \(isCharging ? "charged" : "on power")")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
        .onAppear(perform: animateRing)
        .onChange(of: pulseID) { _, _ in animateRing() }
    }

    private func animateRing() {
        ringProgress = 0
        withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.72, dampingFraction: 0.84)) {
            ringProgress = CGFloat(max(0, min(percent, 100))) / 100
        }
    }
}

private struct WaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedFeedback: PlaybackFeedback?
    let isPlaying: Bool
    let levels: [Double]
    let accent: Color
    let feedback: PlaybackFeedback?

    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { index in
                let rawLevel = index < levels.count ? levels[index] : 0
                let level = rawLevel.isFinite ? min(max(rawLevel, 0), 1) : 0
                let geometry = SpectrumBarGeometry.bar(at: index, level: level, playing: isPlaying, feedback: renderedFeedback)
                Capsule()
                    .fill(accent)
                    // Keep the live levels independent of the color transition.
                    // The last of eight bars finishes at 2.58 + 7 × 0.06 = 3 s.
                    .animation(reduceMotion ? nil : .easeInOut(duration: 2.58).delay(Double(index) * 0.06), value: accent)
                    .opacity(renderedFeedback != nil ? 1 : (isPlaying ? 0.55 + level * 0.45 : 0.35))
                    .frame(width: geometry.width, height: geometry.height)
                    .animation(reduceMotion ? nil : .spring(response: 0.13, dampingFraction: 0.88), value: level)
                    .position(x: geometry.centerX, y: 11)
                    .animation(reduceMotion ? nil : .spring(duration: 0.16, bounce: 0.06).delay(Double(index) * 0.009), value: renderedFeedback)
            }
        }
        .frame(width: 34, height: 22)
        .onChange(of: feedback, initial: true) { _, newValue in renderedFeedback = newValue }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(renderedFeedback == .pause ? "Paused" : renderedFeedback == .play ? "Playing" : "Live eight-band audio spectrum")
    }
}

private struct DetailEntrance: ViewModifier {
    let progress: CGFloat
    let reduceMotion: Bool
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(y: reduceMotion ? 0 : (1 - progress) * 8)
            .scaleEffect(reduceMotion ? 1 : 0.975 + 0.025 * progress, anchor: .top)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.34, dampingFraction: 0.8).delay(delay),
                value: progress
            )
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.48 : 0.78))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.25)
            .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}

private struct DashboardModuleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}

private struct SubtlePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}

private struct PillButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var prominent = false
    var tint = Color(nsColor: .systemOrange)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9.5, weight: .regular))
            .padding(.horizontal, 11)
            .frame(height: 27)
            .foregroundStyle(prominent ? Color.black : tint)
            .background(
                prominent
                    ? tint.opacity(configuration.isPressed ? 0.76 : 1)
                    : tint.opacity(configuration.isPressed ? 0.25 : 0.14),
                in: Capsule()
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.2, bounce: 0), value: configuration.isPressed)
    }
}

private struct NotchSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var isEnabled = true
    var accent = Color.white
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 3)
                Capsule().fill(accent.opacity(isEnabled ? 0.82 : 0.2)).frame(width: max(3, width * normalizedValue), height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .offset(x: max(0, min(width - 7, width * normalizedValue - 3.5)))
                    .opacity(isEnabled ? 1 : 0.25)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        onEditingChanged(true)
                        setValue(x: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        guard isEnabled else { return }
                        setValue(x: gesture.location.x, width: width)
                        onEditingChanged(false)
                    }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int(normalizedValue * 100)) percent")
        .accessibilityAdjustableAction { direction in
            guard isEnabled else { return }
            let step = (range.upperBound - range.lowerBound) / 20
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }

    private var normalizedValue: Double {
        guard value.isFinite, range.lowerBound.isFinite, range.upperBound.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }

    private func setValue(x: CGFloat, width: CGFloat) {
        guard x.isFinite, width.isFinite, width > 0 else { return }
        let progress = min(max(Double(x / width), 0), 1)
        value = range.lowerBound + progress * (range.upperBound - range.lowerBound)
    }
}
