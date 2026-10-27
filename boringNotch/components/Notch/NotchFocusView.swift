//
//  NotchFocusView.swift
//  boringNotch
//
//  The Focus tab, the closed-notch countdown and the "phase finished" banner.
//

import Defaults
import SwiftUI

// MARK: - Open notch

struct NotchFocusView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var pomodoro = PomodoroManager.shared

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            FocusDial()
                .frame(width: 116, height: 116)

            VStack(alignment: .leading, spacing: 12) {
                FocusPhasePicker()
                FocusCycleRow()
                FocusControls()
            }

            Spacer(minLength: 0)

            FocusTodayCard()
                .frame(width: 128)
        }
        // A fixed height like Usage and Lyrics, then the same top-aligned area as Home,
        // so the header doesn't shift when switching tabs.
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(height: 134, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .padding(.leading, 4)
        .transition(.opacity)
        .blur(radius: vm.notchState == .closed ? 30 : 0)
        .onAppear { pomodoro.rollStatsIfNeeded() }
    }
}

/// Re-renders its content once a second while the timer runs, lined up with the
/// end date so the seconds tick over on time. Nothing else redraws.
struct FocusTimeline<Content: View>: View {
    @ObservedObject var pomodoro = PomodoroManager.shared
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        if pomodoro.isRunning, let end = pomodoro.endDate {
            TimelineView(.periodic(from: Self.alignedStart(end), by: 1)) { context in
                content(context.date)
            }
        } else {
            content(Date())
        }
    }

    /// A start just after a whole-second boundary before the end date.
    private static func alignedStart(_ end: Date) -> Date {
        let left = max(0, end.timeIntervalSinceNow)
        return end.addingTimeInterval(-left.rounded(.up) + 0.02)
    }
}

struct FocusRing: View {
    let progress: Double
    let tint: Color
    var lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.smooth(duration: 0.5), value: progress)
        .animation(.smooth, value: tint)
    }
}

struct FocusDial: View {
    @ObservedObject var pomodoro = PomodoroManager.shared

    var body: some View {
        FocusTimeline { date in
            ZStack {
                FocusRing(progress: pomodoro.progress(at: date), tint: pomodoro.phase.tint)
                VStack(spacing: 1) {
                    Image(systemName: pomodoro.phase.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pomodoro.phase.tint)
                        .contentTransition(.symbolEffect(.replace))
                    Text(PomodoroManager.format(pomodoro.remaining(at: date)))
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                    Text(statusLabel)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.gray)
                        .textCase(.uppercase)
                }
            }
        }
        .animation(.smooth, value: pomodoro.phase)
    }

    private var statusLabel: String {
        pomodoro.status == .paused ? String(localized: "Paused") : pomodoro.phase.title
    }
}

struct FocusPhasePicker: View {
    @ObservedObject var pomodoro = PomodoroManager.shared
    @Namespace private var animation

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PomodoroPhase.allCases) { phase in
                let selected = phase == pomodoro.phase
                Button {
                    withAnimation(.smooth) {
                        pomodoro.select(phase)
                    }
                } label: {
                    Text(phase.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .contentShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundStyle(selected ? .white : .gray)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color(nsColor: .secondarySystemFill))
                            .matchedGeometryEffect(id: "phase", in: animation)
                    }
                }
            }
        }
        .clipShape(Capsule())
    }
}

struct FocusCycleRow: View {
    @ObservedObject var pomodoro = PomodoroManager.shared
    @Default(.pomodoroSessionsUntilLongBreak) private var sessionsSetting

    private var total: Int { max(2, sessionsSetting) }

    /// Focus sessions already finished in this cycle.
    private var done: Int {
        pomodoro.phase == .longBreak ? total : pomodoro.cyclePosition % total
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { index in
                    Circle()
                        .fill(dotColor(index))
                        .frame(width: 7, height: 7)
                }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .animation(.smooth, value: done)
    }

    private func dotColor(_ index: Int) -> Color {
        if index < done { return PomodoroPhase.focus.tint }
        if index == done && pomodoro.phase == .focus {
            return PomodoroPhase.focus.tint.opacity(pomodoro.isActive ? 0.45 : 0.25)
        }
        return .white.opacity(0.14)
    }

    private var caption: String {
        if pomodoro.phase == .focus {
            let next = pomodoro.nextPhase == .longBreak ? String(localized: "long break next") : String(localized: "short break next")
            return String(localized: "Session \(done + 1) of \(total) · \(next)")
        }
        return pomodoro.phase == .longBreak
            ? String(localized: "Cycle complete")
            : String(localized: "\(done) of \(total) sessions done")
    }
}

struct FocusControls: View {
    @ObservedObject var pomodoro = PomodoroManager.shared

    var body: some View {
        HStack(spacing: 10) {
            FocusRoundButton(icon: "arrow.counterclockwise", help: resetHelp) {
                withAnimation(.smooth) { pomodoro.reset() }
            }

            Button {
                withAnimation(.smooth) { pomodoro.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pomodoro.isRunning ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                    Text(primaryTitle)
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(pomodoro.phase.tint)
                .frame(width: 104, height: 32)
                .background(Capsule().fill(pomodoro.phase.tint.opacity(0.18)))
                .contentShape(Capsule())
            }
            .buttonStyle(PlainButtonStyle())

            FocusRoundButton(icon: "forward.end.fill", help: String(localized: "Skip to \(pomodoro.nextPhase.title)")) {
                withAnimation(.smooth) { pomodoro.skip() }
            }
        }
    }

    private var primaryTitle: String {
        switch pomodoro.status {
        case .idle: return String(localized: "Start")
        case .running: return String(localized: "Pause")
        case .paused: return String(localized: "Resume")
        }
    }

    private var resetHelp: String {
        pomodoro.isActive ? String(localized: "Restart this phase") : String(localized: "Start the cycle over")
    }
}

struct FocusRoundButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? .white : .gray)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color(nsColor: .secondarySystemFill)))
                .contentShape(Circle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct FocusTodayCard: View {
    @ObservedObject var pomodoro = PomodoroManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.gray)
            Spacer(minLength: 0)
            Text("\(pomodoro.sessionsToday)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(pomodoro.sessionsToday == 1 ? LocalizedStringKey("session") : LocalizedStringKey("sessions"))
                .font(.caption)
                .foregroundStyle(.gray)
            Text(focusedText)
                .font(.caption2)
                .foregroundStyle(.gray)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.opened).fill(.white.opacity(0.05)))
        .animation(.smooth, value: pomodoro.sessionsToday)
    }

    private var focusedText: String {
        pomodoro.focusSecondsToday > 0
            ? String(localized: "\(PomodoroManager.formatDuration(pomodoro.focusSecondsToday)) focused")
            : String(localized: "Nothing yet")
    }
}

// MARK: - Header tab

/// The countdown next to the Focus tab icon while another tab is showing.
struct FocusTabBadge: View {
    @ObservedObject var pomodoro = PomodoroManager.shared

    var body: some View {
        FocusTimeline { date in
            Text(PomodoroManager.format(pomodoro.remaining(at: date)))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(pomodoro.isRunning ? pomodoro.phase.tint : .gray)
        }
    }
}

// MARK: - Closed notch

/// Width of each side of the closed-notch countdown. Both sides match so the
/// black middle stays centred on the real notch.
let focusLiveActivitySideWidth: CGFloat = 44

/// Ring on the left, time on the right, like a Dynamic Island timer.
struct FocusLiveActivity: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var pomodoro = PomodoroManager.shared

    private var ringSize: CGFloat { max(0, vm.effectiveClosedNotchHeight - 12) }

    var body: some View {
        FocusTimeline { date in
            HStack {
                ZStack {
                    FocusRing(progress: pomodoro.progress(at: date), tint: pomodoro.phase.tint, lineWidth: 2.5)
                    if pomodoro.status == .paused {
                        Image(systemName: "pause.fill")
                            .font(.system(size: max(6, ringSize * 0.32), weight: .bold))
                            .foregroundStyle(.gray)
                    }
                }
                .frame(width: ringSize, height: ringSize)
                .frame(width: focusLiveActivitySideWidth, alignment: .leading)

                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width - cornerRadiusInsets.closed.top)

                Text(PomodoroManager.format(pomodoro.remaining(at: date)))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(pomodoro.isRunning ? pomodoro.phase.tint : .gray)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: focusLiveActivitySideWidth, alignment: .trailing)
            }
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}

/// Shown for a few seconds when a phase ends, styled like the battery notification.
struct FocusFinishedBanner: View {
    @ObservedObject var pomodoro = PomodoroManager.shared
    let closedNotchWidth: CGFloat
    @State private var bounce = false

    var body: some View {
        let finished = pomodoro.lastFinishedPhase ?? .focus
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(finished.tint)
                    .symbolEffect(.bounce, value: bounce)
                Text(finished == .focus ? LocalizedStringKey("Focus done") : LocalizedStringKey("Break over"))
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: 120, alignment: .leading)

            Rectangle()
                .fill(.black)
                .frame(width: closedNotchWidth + 10)

            HStack(spacing: 6) {
                Text(pomodoro.phase.title)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                FocusTimeline { date in
                    Text(PomodoroManager.format(pomodoro.remaining(at: date)))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(pomodoro.phase.tint)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .onAppear { bounce.toggle() }
    }
}

#Preview {
    NotchFocusView()
        .environmentObject(BoringViewModel())
        .padding()
        .frame(width: 600, height: 160)
        .background(.black)
}
