//
//  PomodoroManager.swift
//  boringNotch
//
//  The focus timer behind the Focus tab and the closed-notch countdown.
//  Time left is always worked out from the phase's end date, never by counting
//  ticks, so the timer stays right across sleep and relaunch.
//

import AppKit
import Combine
import Defaults
import SwiftUI
import UserNotifications

enum PomodoroPhase: String, CaseIterable, Identifiable, Codable {
    case focus
    case shortBreak
    case longBreak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: return String(localized: "Focus")
        case .shortBreak: return String(localized: "Short break")
        case .longBreak: return String(localized: "Long break")
        }
    }

    var icon: String {
        switch self {
        case .focus: return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak: return "figure.walk"
        }
    }

    var tint: Color {
        switch self {
        case .focus: return Color(red: 1.0, green: 0.42, blue: 0.33)
        case .shortBreak: return Color(red: 0.30, green: 0.85, blue: 0.55)
        case .longBreak: return Color(red: 0.35, green: 0.68, blue: 1.0)
        }
    }

    var isBreak: Bool { self != .focus }

    /// The configured length, in seconds.
    var duration: TimeInterval {
        let minutes: Int
        switch self {
        case .focus: minutes = Defaults[.pomodoroFocusMinutes]
        case .shortBreak: minutes = Defaults[.pomodoroShortBreakMinutes]
        case .longBreak: minutes = Defaults[.pomodoroLongBreakMinutes]
        }
        return TimeInterval(max(1, minutes) * 60)
    }
}

enum PomodoroSound: String, CaseIterable, Identifiable, Defaults.Serializable {
    case none = "None"
    case glass = "Glass"
    case hero = "Hero"
    case ping = "Ping"
    case purr = "Purr"
    case submarine = "Submarine"
    case funk = "Funk"
    case pop = "Pop"
    case tink = "Tink"

    var id: String { rawValue }

    func play() {
        guard self != .none else { return }
        NSSound(named: NSSound.Name(rawValue))?.play()
    }
}

enum PomodoroStatus: String, Codable {
    case idle
    case running
    case paused
}

/// What gets saved, so a relaunch picks up where the timer was.
struct PomodoroSnapshot: Codable, Defaults.Serializable {
    var phase: PomodoroPhase = .focus
    var status: PomodoroStatus = .idle
    /// Focus sessions finished (or skipped) since the last long break.
    var cyclePosition: Int = 0
    /// Set while running.
    var endDate: Date?
    /// Set while paused.
    var pausedRemaining: TimeInterval?
    /// The phase's length when it started, so changing a duration mid-phase doesn't break the ring.
    var phaseDuration: TimeInterval = 25 * 60
    /// Today's numbers, keyed by day so they roll over at midnight.
    var statsDay: String = ""
    var sessionsToday: Int = 0
    var focusSecondsToday: TimeInterval = 0
}

@MainActor
final class PomodoroManager: ObservableObject {
    static let shared = PomodoroManager()

    @Published private(set) var phase: PomodoroPhase = .focus
    @Published private(set) var status: PomodoroStatus = .idle
    @Published private(set) var cyclePosition: Int = 0
    @Published private(set) var endDate: Date?
    @Published private(set) var pausedRemaining: TimeInterval?
    @Published private(set) var phaseDuration: TimeInterval = 25 * 60
    @Published private(set) var sessionsToday: Int = 0
    @Published private(set) var focusSecondsToday: TimeInterval = 0
    /// The phase that just ended, for the closed-notch banner.
    @Published private(set) var lastFinishedPhase: PomodoroPhase?

    private var statsDay: String = ""
    private var completionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?
    private var dayChangeObserver: NSObjectProtocol?
    private let notificationDelegate = PomodoroNotificationDelegate()

    /// Running or paused: something worth showing in the closed notch.
    var isActive: Bool { status != .idle }
    var isRunning: Bool { status == .running }

    var sessionsUntilLongBreak: Int { max(2, Defaults[.pomodoroSessionsUntilLongBreak]) }

    /// The phase that follows the current one when it finishes.
    var nextPhase: PomodoroPhase {
        if phase.isBreak { return .focus }
        return (cyclePosition + 1) % sessionsUntilLongBreak == 0 ? .longBreak : .shortBreak
    }

    private init() {
        restore()

        // Keep an idle timer's length in step with Settings.
        Defaults.publisher(
            keys: .pomodoroFocusMinutes, .pomodoroShortBreakMinutes, .pomodoroLongBreakMinutes,
            options: []
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor in
                guard let self, self.status == .idle else { return }
                self.phaseDuration = self.phase.duration
                self.save()
            }
        }
        .store(in: &cancellables)

        Defaults.publisher(.pomodoroEnabled, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                Task { @MainActor in
                    guard let self, !change.newValue else { return }
                    self.resetCycle()
                    if BoringViewCoordinator.shared.currentView == .focus {
                        BoringViewCoordinator.shared.currentView = .home
                    }
                }
            }
            .store(in: &cancellables)

        // The sleep in the completion task may not fire on time across system sleep.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.checkCompletion() }
        }

        // Start today's numbers from zero at midnight, even while the timer sits idle.
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rollStatsIfNeeded() }
        }
    }

    // MARK: - Time

    /// Seconds left at `date`, for views that redraw on their own schedule.
    func remaining(at date: Date = Date()) -> TimeInterval {
        switch status {
        case .running:
            return max(0, (endDate ?? date).timeIntervalSince(date))
        case .paused:
            return pausedRemaining ?? phaseDuration
        case .idle:
            return phaseDuration
        }
    }

    /// 0 at the start of the phase, 1 when it ends.
    func progress(at date: Date = Date()) -> Double {
        guard phaseDuration > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: date) / phaseDuration))
    }

    /// "24:13". Minutes can go past 59 so the text keeps one width.
    nonisolated static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    nonisolated static func formatDuration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: - Controls

    func toggle() {
        switch status {
        case .idle: start()
        case .running: pause()
        case .paused: resume()
        }
    }

    func start() {
        guard status == .idle else { return }
        phaseDuration = phase.duration
        run(for: phaseDuration)
    }

    func pause() {
        guard status == .running else { return }
        completionTask?.cancel()
        pausedRemaining = remaining()
        endDate = nil
        status = .paused
        save()
    }

    func resume() {
        guard status == .paused else { return }
        run(for: pausedRemaining ?? phaseDuration)
    }

    /// Moves on to the next phase without counting the current one in today's stats.
    func skip() {
        advance(completed: false)
    }

    /// Restarts the current phase; when it's already untouched, starts the cycle over.
    func reset() {
        if status == .idle && phaseDuration == phase.duration {
            resetCycle()
        } else {
            setIdle(phase)
        }
    }

    func resetCycle() {
        cyclePosition = 0
        setIdle(.focus)
    }

    func select(_ newPhase: PomodoroPhase) {
        guard newPhase != phase || status != .idle else { return }
        setIdle(newPhase)
    }

    // MARK: - State changes

    private func run(for seconds: TimeInterval) {
        endDate = Date().addingTimeInterval(seconds)
        pausedRemaining = nil
        status = .running
        scheduleCompletion()
        save()
    }

    private func setIdle(_ newPhase: PomodoroPhase) {
        completionTask?.cancel()
        phase = newPhase
        status = .idle
        endDate = nil
        pausedRemaining = nil
        phaseDuration = newPhase.duration
        save()
    }

    private func scheduleCompletion() {
        completionTask?.cancel()
        guard let endDate else { return }
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, endDate.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.checkCompletion()
        }
    }

    private func checkCompletion() {
        rollStatsIfNeeded()
        guard status == .running, let endDate else { return }
        if endDate <= Date() {
            advance(completed: true)
        } else {
            scheduleCompletion()
        }
    }

    /// Ends the current phase and sets up the next one.
    /// `notify` is off when catching up after a relaunch, so an old phase doesn't chime.
    private func advance(completed: Bool, notify: Bool = true) {
        completionTask?.cancel()
        let finished = phase
        let next = nextPhase
        let endedAt = endDate ?? Date()

        if finished == .focus {
            cyclePosition += 1
            rollStatsIfNeeded()
            // A session counts for the day it ended; one that ended on an earlier day
            // while the app was closed doesn't count for today.
            if completed && Self.dayKey(endedAt) == statsDay {
                sessionsToday += 1
                focusSecondsToday += phaseDuration
            }
        } else if finished == .longBreak {
            cyclePosition = 0
        }

        setIdle(next)

        if completed && notify {
            announce(finished: finished, next: next)
        }

        let autoStart = next.isBreak ? Defaults[.pomodoroAutoStartBreaks] : Defaults[.pomodoroAutoStartFocus]
        if completed && notify && autoStart {
            start()
        }
    }

    // MARK: - Feedback

    private func announce(finished: PomodoroPhase, next: PomodoroPhase) {
        Defaults[.pomodoroSound].play()

        if Defaults[.enableHaptics] {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }

        if Defaults[.pomodoroShowInClosedNotch] {
            lastFinishedPhase = finished
            BoringViewCoordinator.shared.toggleExpandingView(status: true, type: .focus)
        }

        if Defaults[.pomodoroNotifications] {
            postNotification(finished: finished, next: next)
        }
    }

    static func finishedTitle(_ phase: PomodoroPhase) -> String {
        phase == .focus ? String(localized: "Focus session done") : String(localized: "Break's over")
    }

    static func nextLine(_ next: PomodoroPhase) -> String {
        next == .focus
            ? String(localized: "Time to focus · \(PomodoroManager.formatDuration(next.duration))")
            : String(localized: "\(next.title) · \(PomodoroManager.formatDuration(next.duration))")
    }

    private func postNotification(finished: PomodoroPhase, next: PomodoroPhase) {
        let center = UNUserNotificationCenter.current()
        // Without a delegate macOS may hold back banners while the app counts as active.
        if center.delegate == nil {
            center.delegate = notificationDelegate
        }
        let content = UNMutableNotificationContent()
        content.title = Self.finishedTitle(finished)
        content.body = Self.nextLine(next)
        // The app plays its own sound when one is picked.
        content.sound = nil
        let request = UNNotificationRequest(identifier: "pomodoro-\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request)
    }

    /// Asks macOS for permission; turns the setting back off when refused.
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            if !granted {
                Task { @MainActor in Defaults[.pomodoroNotifications] = false }
            }
        }
    }

    // MARK: - Persistence

    private static func dayKey(_ date: Date = Date()) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }

    func rollStatsIfNeeded() {
        let today = Self.dayKey()
        guard statsDay != today else { return }
        statsDay = today
        sessionsToday = 0
        focusSecondsToday = 0
        save()
    }

    private func save() {
        Defaults[.pomodoroSnapshot] = PomodoroSnapshot(
            phase: phase,
            status: status,
            cyclePosition: cyclePosition,
            endDate: endDate,
            pausedRemaining: pausedRemaining,
            phaseDuration: phaseDuration,
            statsDay: statsDay,
            sessionsToday: sessionsToday,
            focusSecondsToday: focusSecondsToday
        )
    }

    private func restore() {
        let saved = Defaults[.pomodoroSnapshot]
        phase = saved.phase
        status = saved.status
        cyclePosition = saved.cyclePosition
        endDate = saved.endDate
        pausedRemaining = saved.pausedRemaining
        phaseDuration = saved.status == .idle ? saved.phase.duration : saved.phaseDuration
        statsDay = saved.statsDay
        sessionsToday = saved.sessionsToday
        focusSecondsToday = saved.focusSecondsToday
        rollStatsIfNeeded()

        guard Defaults[.pomodoroEnabled] else {
            if status != .idle { setIdle(phase) }
            return
        }

        if status == .running {
            if let endDate, endDate > Date() {
                scheduleCompletion()
            } else {
                // Finished while the app wasn't running: count it, but don't chime or auto-start.
                advance(completed: true, notify: false)
            }
        }
    }
}

/// Lets focus-timer banners show even while boring.notch counts as the active app.
final class PomodoroNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
