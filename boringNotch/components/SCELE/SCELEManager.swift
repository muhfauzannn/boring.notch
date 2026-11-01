import Combine
import Defaults
import Foundation

@MainActor
final class SCELEManager: ObservableObject {
    static let shared = SCELEManager()

    @Published private(set) var courses: [SCELECourse] = []
    @Published private(set) var tasks: [SCELETask] = []
    @Published private(set) var selectedCourseIDs: Set<Int> = []
    @Published private(set) var hiddenTaskIDs: Set<String> = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var isConnecting = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var requiresSignIn = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusFailureCount = 0
    @Published private(set) var accountName: String?
    @Published private(set) var username = ""

    var isConnected: Bool { credential != nil }

    private let client = SCELEClient()
    private let credentials = SCELECredentialStore()
    private let cache = SCELECacheStore()
    private var credential: SCELECredential?
    private var generation = UUID()
    private var needsRefresh = false
    private var needsInitialSelection = false
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        do {
            if let stored = try credentials.read() {
                credential = stored
                accountName = stored.fullName
                username = stored.username
                if let saved = cache.read(userID: stored.userID) { restore(saved) }
                else { needsInitialSelection = true }
            }
        } catch { errorMessage = error.localizedDescription }

        Defaults.publisher(.sceleEnabled, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.restartPolling() }
            }
            .store(in: &cancellables)
        restartPolling()
    }

    func connect(username: String, password: String) async {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        invalidateRefresh()
        let operation = generation
        defer { isConnecting = false }
        do {
            let signedIn = try await client.signIn(username: username, password: password)
            let enrolled = try await client.courses(using: signedIn)
            guard operation == generation, !Task.isCancelled else { return }
            try credentials.save(signedIn)
            let sameAccount = credential?.userID == signedIn.userID
            credential = signedIn
            accountName = signedIn.fullName
            self.username = signedIn.username
            requiresSignIn = false
            courses = enrolled
            if !sameAccount || needsInitialSelection {
                selectedCourseIDs = Set(enrolled.filter { $0.isCurrent(at: Date()) }.map(\.id))
                if selectedCourseIDs.isEmpty { selectedCourseIDs = Set(enrolled.map(\.id)) }
                hiddenTaskIDs = []
                tasks = []
                updatedAt = nil
            }
            needsInitialSelection = false
            selectedCourseIDs.formIntersection(Set(enrolled.map(\.id)))
            needsRefresh = true
            persist()
            isConnecting = false
            Defaults[.sceleEnabled] = true
            restartPolling()
        } catch {
            guard operation == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        do { try credentials.delete() }
        catch { errorMessage = error.localizedDescription; return }
        invalidateRefresh()
        pollTask?.cancel()
        pollTask = nil
        selectionTask?.cancel()
        credential = nil
        needsInitialSelection = false
        accountName = nil
        username = ""
        requiresSignIn = false
        courses = []
        selectedCourseIDs = []
        tasks = []
        hiddenTaskIDs = []
        updatedAt = nil
        statusFailureCount = 0
        errorMessage = nil
        do { try cache.delete() }
        catch { errorMessage = "Signed out. The saved task cache could not be removed from this Mac." }
    }

    func refresh(force: Bool = false) async {
        guard Defaults[.sceleEnabled], let credential, !requiresSignIn, !isConnecting else { return }
        if let refreshTask { await refreshTask.value; return }
        if !force, !needsRefresh, let updatedAt, Date().timeIntervalSince(updatedAt) < 300 { return }
        isRefreshing = true
        let operation = generation
        let selected = selectedCourseIDs
        let initializeSelection = needsInitialSelection
        let operationTask = Task { [weak self, client] in
            do {
                let enrolled = try await client.courses(using: credential)
                let effectiveSelection: Set<Int>
                if initializeSelection {
                    let current = Set(enrolled.filter { $0.isCurrent(at: Date()) }.map(\.id))
                    effectiveSelection = current.isEmpty ? Set(enrolled.map(\.id)) : current
                } else {
                    effectiveSelection = selected.intersection(Set(enrolled.map(\.id)))
                }
                let result = try await client.tasks(using: credential, courses: enrolled, selectedIDs: effectiveSelection)
                guard let self, self.generation == operation, !Task.isCancelled else { return }
                self.courses = enrolled
                self.selectedCourseIDs = effectiveSelection
                self.tasks = result.tasks
                self.statusFailureCount = result.statusFailureCount
                self.updatedAt = Date()
                self.needsRefresh = false
                self.needsInitialSelection = false
                self.errorMessage = nil
                self.persist()
            } catch {
                guard let self, self.generation == operation, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
                if (error as? SCELEError) == .expiredSession { self.requiresSignIn = true }
            }
            guard let self, self.generation == operation else { return }
            self.isRefreshing = false
            self.refreshTask = nil
        }
        refreshTask = operationTask
        await operationTask.value
    }

    func selectCourse(_ id: Int, selected: Bool) {
        if selected { selectedCourseIDs.insert(id) } else { selectedCourseIDs.remove(id) }
        selectionChanged()
    }

    func selectCurrentCourses() {
        selectedCourseIDs = Set(courses.filter { $0.isCurrent(at: Date()) }.map(\.id))
        selectionChanged()
    }

    func clearCourseSelection() {
        selectedCourseIDs = []
        selectionChanged()
    }

    func hide(_ task: SCELETask) {
        hiddenTaskIDs.insert(task.id)
        persist()
    }

    func restoreHiddenTasks() {
        hiddenTaskIDs = []
        persist()
    }

    private func selectionChanged() {
        needsInitialSelection = false
        invalidateRefresh()
        needsRefresh = true
        persist()
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await self?.refresh(force: true)
        }
    }

    private func restartPolling() {
        pollTask?.cancel()
        invalidateRefresh()
        guard Defaults[.sceleEnabled] else {
            if BoringViewCoordinator.shared.currentView == .tasks { BoringViewCoordinator.shared.currentView = .home }
            return
        }
        guard credential != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
    }

    private func invalidateRefresh() {
        generation = UUID()
        refreshTask?.cancel()
        refreshTask = nil
        isRefreshing = false
    }

    private func restore(_ saved: SCELECache) {
        courses = saved.courses
        selectedCourseIDs = saved.selectedCourseIDs
        hiddenTaskIDs = saved.hiddenTaskIDs
        tasks = saved.tasks
        updatedAt = saved.updatedAt
        statusFailureCount = saved.statusFailureCount
    }

    private func persist() {
        guard let credential else { return }
        do {
            try cache.save(SCELECache(userID: credential.userID, courses: courses,
                                      selectedCourseIDs: selectedCourseIDs, hiddenTaskIDs: hiddenTaskIDs,
                                      tasks: tasks, updatedAt: updatedAt, statusFailureCount: statusFailureCount))
        } catch { errorMessage = "Tasks are available, but they could not be saved for offline use." }
    }
}
