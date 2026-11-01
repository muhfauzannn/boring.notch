import AppKit
import Defaults
import SwiftUI

/// Two wings keep the message out from underneath the physical camera housing.
struct SCELETaskBanner: View {
    let announcement: SCELETaskAnnouncement
    let closedNotchWidth: CGFloat

    private var wingWidth: CGFloat { max(0, (640 - closedNotchWidth - 34) / 2) }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bell.badge.fill")
                    .foregroundStyle(Color.effectiveAccent)
                Text(announcement.tasks.count == 1 ? "New SCELE task" : "\(announcement.tasks.count) new SCELE tasks")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(width: wingWidth, alignment: .leading)

            Rectangle().fill(.black).frame(width: closedNotchWidth + 10)

            if let task = announcement.tasks.first {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(task.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(task.courseName)
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                }
                .frame(width: wingWidth, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .help("Open Tasks to see new SCELE assignments and quizzes")
        .accessibilityElement(children: .combine)
    }
}

struct NotchSCELEView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var manager = SCELEManager.shared
    @Default(.sceleHideSubmitted) private var hideSubmitted
    @State private var filter: SCELETaskFilter = .upcoming

    var body: some View {
        VStack(spacing: 7) {
            if !manager.isConnected {
                setupView
            } else {
                toolbar
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    taskList(at: context.date)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 134, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 2)
        .transition(.opacity)
        .blur(radius: vm.notchState == .closed ? 30 : 0)
        .task { await manager.refresh() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("Show tasks", selection: $filter) {
                ForEach(SCELETaskFilter.allCases) { filter in Text(filter.title).tag(filter) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 235)

            Spacer(minLength: 0)
            if manager.requiresSignIn {
                Button("Sign in again", action: openSettings)
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
            } else if let error = manager.errorMessage {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                    .help(error)
                    .accessibilityLabel(error)
            } else if let date = manager.updatedAt {
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.gray)
                    .lineLimit(1)
                    .help("Last successful sync. Deadlines use Jakarta time (WIB).")
            }

            Button {
                Task { await manager.refresh(force: true) }
            } label: {
                if manager.isRefreshing { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .frame(width: 18)
            .disabled(manager.isRefreshing || manager.requiresSignIn)
            .help("Refresh tasks")
            .accessibilityLabel("Refresh tasks")

            Button(action: openSettings) { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain)
                .help("SCELE settings and courses")
                .accessibilityLabel("SCELE settings and courses")
        }
        .font(.caption)
    }

    @ViewBuilder
    private func taskList(at date: Date) -> some View {
        let visible = manager.tasks.filter {
            manager.selectedCourseIDs.contains($0.courseID) && !manager.hiddenTaskIDs.contains($0.id)
                && !(hideSubmitted && $0.submission.isFinished)
                && $0.isInDisplayRange(at: date) && filter.includes($0, at: date)
        }
        if visible.isEmpty {
            VStack(spacing: 5) {
                Image(systemName: manager.isRefreshing ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                    .font(.title3)
                    .foregroundStyle(.gray)
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundStyle(.gray)
                if manager.selectedCourseIDs.isEmpty {
                    Button("Choose courses", action: openSettings).buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(visible) { task in
                        SCELETaskRow(task: task, now: date)
                            .contextMenu {
                                Button("Open in SCELE") { NSWorkspace.shared.open(task.url) }
                                Button("Hide from notch") { manager.hide(task) }
                            }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private var emptyMessage: String {
        if manager.requiresSignIn { return "Sign in again to update your saved tasks." }
        if manager.isRefreshing { return "Syncing your SCELE tasks…" }
        if manager.errorMessage != nil { return "Could not update tasks. Open SCELE settings for details." }
        if manager.selectedCourseIDs.isEmpty { return "Choose the courses you want to follow." }
        return "No tasks in this view."
    }

    private var setupView: some View {
        VStack(spacing: 8) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 24))
                .foregroundStyle(.gray)
            Text("Your campus deadlines, at a glance")
                .font(.subheadline.weight(.medium))
            Text("Connect SCELE to see assignments and quizzes here.")
                .font(.caption)
                .foregroundStyle(.gray)
            Button("Connect SCELE", action: openSettings)
                .buttonStyle(.borderedProminent)
                .tint(.effectiveAccent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openSettings() { SettingsWindowController.shared.showWindow(tab: "SCELE") }
}

private enum SCELETaskFilter: String, CaseIterable, Identifiable {
    case upcoming, week, overdue
    var id: Self { self }
    var title: String {
        switch self { case .upcoming: return "Upcoming"; case .week: return "7 days"; case .overdue: return "Overdue" }
    }
    func includes(_ task: SCELETask, at date: Date) -> Bool {
        switch self {
        case .upcoming: return task.dueDate >= date
        case .week: return task.dueDate >= date && task.dueDate <= date.addingTimeInterval(7 * 86_400)
        case .overdue: return task.dueDate < date && !task.submission.isFinished
        }
    }
}

private struct SCELETaskRow: View {
    let task: SCELETask
    let now: Date
    @State private var isHovered = false

    private var urgent: Bool { !task.submission.isFinished && task.dueDate.timeIntervalSince(now) < 86_400 }

    var body: some View {
        Button { NSWorkspace.shared.open(task.url) } label: {
            rowContent
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("\(task.title)\n\(task.courseName)\n\(task.submission.title) · WIB")
        .accessibilityLabel(Text("\(task.title), \(task.courseName), \(task.submission.title), \(countdown)"))
    }

    private var rowContent: some View {
        HStack(spacing: 9) {
            Image(systemName: task.kind == .quiz ? "questionmark.square" : "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(urgent ? Color.orange : Color.gray)
                .frame(width: 20)
            taskInfo
            deadlineInfo
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8))
                .foregroundStyle(.gray)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.white.opacity(isHovered ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private var taskInfo: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(task.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(task.courseName + " · " + task.submission.title)
                .font(.system(size: 9))
                .foregroundStyle(task.submission.isFinished ? Color.green : Color.gray)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var deadlineInfo: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(countdown)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(urgent ? Color.orange : Color.white)
            Text(formattedDeadline)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
        }
    }

    private var formattedDeadline: String {
        let style = Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "Asia/Jakarta")!)
            .day().month(.abbreviated).hour().minute()
        return task.dueDate.formatted(style)
    }

    private var countdown: String {
        let seconds = task.dueDate.timeIntervalSince(now)
        let minutes = max(1, Int(ceil(abs(seconds) / 60)))
        let amount: String
        if minutes >= 1440 { amount = "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
        else if minutes >= 60 { amount = "\(minutes / 60)h \(minutes % 60)m" }
        else { amount = "\(minutes)m" }
        return seconds < 0 ? "\(amount) overdue" : "in \(amount)"
    }
}
