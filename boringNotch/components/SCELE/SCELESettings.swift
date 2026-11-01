import Defaults
import SwiftUI

struct SCELESettings: View {
    @ObservedObject private var manager = SCELEManager.shared
    @Default(.sceleEnabled) private var enabled
    @Default(.sceleTaskNotifications) private var notificationsEnabled
    @Default(.sceleSyncMinutes) private var syncMinutes
    @State private var username = ""
    @State private var password = ""
    @State private var search = ""

    var body: some View {
        Form {
            Section {
                Toggle("Show Tasks tab", isOn: $enabled)
                    .disabled(manager.isConnecting)
                Text("Assignments and quizzes from scele.cs.ui.ac.id.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SCELESyncIntervalRow(minutes: $syncMinutes)
                    .disabled(manager.isConnecting)
                Text("Choose 1–1440 minutes. Changes apply immediately while SCELE is enabled. You can also refresh manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: { Text("SCELE") }

            Section {
                Toggle("Notify in the notch about new tasks", isOn: $notificationsEnabled)
                Text("Shows a short banner when a sync finds a new assignment or quiz in your selected courses. The first sync and newly selected courses stay quiet. Hover or click the banner to open Tasks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Preview notch notification") { manager.previewTaskNotification() }
                    .disabled(!enabled || !notificationsEnabled)
            } header: { Text("Notifications") }

            Section {
                if manager.isConnected {
                    LabeledContent("Account", value: manager.accountName ?? manager.username)
                    LabeledContent("Username", value: manager.username)
                }
                if !manager.isConnected || manager.requiresSignIn {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .onSubmit { connect() }
                    HStack {
                        Button(manager.requiresSignIn ? "Sign in again" : "Connect SCELE", action: connect)
                            .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || password.isEmpty || manager.isConnecting)
                        if manager.isConnecting { ProgressView().controlSize(.small) }
                    }
                    Text("Your access token is stored in macOS Keychain. Your password is only used to sign in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if manager.isConnected {
                    HStack {
                        Button("Refresh now") { Task { await manager.refresh(force: true) } }
                            .disabled(manager.isRefreshing || manager.requiresSignIn || !enabled)
                        if manager.isRefreshing { ProgressView().controlSize(.small) }
                        Spacer()
                        Button("Disconnect", role: .destructive) { manager.disconnect() }
                            .disabled(manager.isConnecting)
                    }
                }
                if let message = manager.errorMessage {
                    Text(message).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if let date = manager.updatedAt {
                    LabeledContent("Last synced", value: date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Account") }

            if manager.isConnected {
                Section {
                    Defaults.Toggle(key: .sceleShowInCalendar) { Text("Show SCELE deadlines in the Home calendar") }
                    Text("Assignments and quizzes appear on their due date with an orange marker and a SCELE label. Home uses your Mac’s time zone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Defaults.Toggle(key: .sceleHideSubmitted) { Text("Hide submitted assignments and finished quiz attempts") }
                    Text("Shows deadlines for the next 60 days and overdue work from the last 7 days. Times in the Tasks tab use WIB. A finished quiz attempt may still allow another attempt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if manager.statusFailureCount > 0 {
                        Text("Some submission statuses could not be read. Those deadlines remain visible with “Status unavailable”.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if !manager.hiddenTaskIDs.isEmpty {
                        Button("Restore hidden tasks (\(manager.hiddenTaskIDs.count))") { manager.restoreHiddenTasks() }
                    }
                } header: { Text("Tasks") }

                Section {
                    Text("Select your courses. For courses shared by several classes, right-click a task in the notch and choose “Hide from notch” to hide another class’s deadline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text("\(manager.selectedCourseIDs.count) selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Current courses") { manager.selectCurrentCourses() }
                        Button("Clear") { manager.clearCourseSelection() }
                    }
                    TextField("Find a course", text: $search)
                    ForEach(filteredCourses) { course in
                        Toggle(isOn: Binding(
                            get: { manager.selectedCourseIDs.contains(course.id) },
                            set: { manager.selectCourse(course.id, selected: $0) }
                        )) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(course.title)
                                Text(course.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Courses") }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("SCELE")
        .onAppear { username = manager.username }
        .onDisappear { password = "" }
    }

    private var filteredCourses: [SCELECourse] {
        manager.courses.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
            || $0.subtitle.localizedCaseInsensitiveContains(search) }
    }

    private func connect() {
        guard !password.isEmpty, !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !manager.isConnecting else { return }
        let signInPassword = password
        password = ""
        Task { await manager.connect(username: username, password: signInPassword) }
    }
}

struct SCELESyncIntervalRow: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 12) {
            Text("Sync interval")
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                TextField("Minutes", value: intervalBinding, format: .number.grouping(.never))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 64)
                    .accessibilityLabel("Sync interval in minutes")
                Text("min")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Stepper("Sync interval", value: intervalBinding, in: SCELESyncInterval.minuteRange)
                    .labelsHidden()
                    .fixedSize()
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity)
    }

    private var intervalBinding: Binding<Int> {
        Binding(get: { SCELESyncInterval.minutes(minutes) }, set: { minutes = SCELESyncInterval.minutes($0) })
    }
}
