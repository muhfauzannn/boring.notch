//
//  AIUsageManager.swift
//  boringNotch
//
//  Polls Claude and ChatGPT plan usage through the XPC helper and publishes it
//  for the Usage tab and the closed-notch warning.
//

import Combine
import Defaults
import Foundation

@MainActor
final class AIUsageManager: ObservableObject {
    static let shared = AIUsageManager()

    @Published private(set) var states: [AIService: UsageState] = [:]
    /// The service whose warning the closed notch is showing.
    @Published private(set) var warningService: AIService?
    /// Claude Code's Keychain item can't be read yet, so Settings offers a one-time "Grant access".
    @Published private(set) var claudeKeychainBlocked = false

    var enabledServices: [AIService] {
        AIService.allCases.filter(\.isEnabled)
    }

    var isEnabled: Bool { !enabledServices.isEmpty }

    private var pollTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    /// Window labels already warned about, per service, so a warning fires once per crossing.
    private var warnedWindows: [AIService: Set<String>] = [:]

    private init() {
        Defaults.publisher(keys: .showClaudeUsage, .showChatGPTUsage, .aiUsageRefreshInterval, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.restart() }
            }
            .store(in: &cancellables)
        restart()
    }

    func state(for service: AIService) -> UsageState {
        states[service] ?? .idle
    }

    func restart() {
        pollTask?.cancel()
        for service in AIService.allCases where !service.isEnabled {
            states[service] = nil
            warnedWindows[service] = nil
            if service == .claude { claudeKeychainBlocked = false }
        }
        guard isEnabled else {
            if BoringViewCoordinator.shared.currentView == .usage {
                BoringViewCoordinator.shared.currentView = .home
            }
            return
        }

        let interval = max(Defaults[.aiUsageRefreshInterval], 60)
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// For opening the tab: skip the network round trip (and the redraw it causes mid-transition)
    /// when every service already has numbers from the last minute.
    func refreshIfStale(maxAge: TimeInterval = 60) async {
        let fresh = enabledServices.allSatisfy { service in
            if case .loaded(let snapshot) = state(for: service) {
                return Date().timeIntervalSince(snapshot.updatedAt) < maxAge
            }
            return false
        }
        if !fresh { await refresh() }
    }

    func refresh() async {
        await withTaskGroup(of: Void.self) { group in
            for service in enabledServices {
                group.addTask { await self.refresh(service) }
            }
        }
    }

    private func refresh(_ service: AIService) async {
        if case .loaded = state(for: service) {
            // Keep showing the last numbers while refreshing.
        } else {
            states[service] = .loading
        }

        let result = await XPCHelperClient.shared.fetchAIUsage(service: service.rawValue)
        guard service.isEnabled else { return }

        if service == .claude {
            claudeKeychainBlocked = result.data == nil
                && (result.error == "keychainApproval" || result.error?.hasPrefix("keychain:") == true)
        }

        if let data = result.data, let snapshot = AIUsageParser.parse(data, for: service) {
            states[service] = .loaded(snapshot)
            checkWarning(snapshot, for: service)
        } else {
            let message = AIUsageParser.message(for: result.error ?? "badResponse", service: service)
            // A transient failure shouldn't wipe numbers we already have.
            if case .loaded = state(for: service), result.error?.hasPrefix("network:") == true { return }
            states[service] = .failed(message)
        }
    }

    private func checkWarning(_ snapshot: UsageSnapshot, for service: AIService) {
        let threshold = Defaults[.aiUsageWarnThreshold]
        var warned = warnedWindows[service] ?? []

        // Forget windows that dropped back below the threshold (they reset).
        for window in snapshot.windows where window.usedPercent < threshold {
            warned.remove(window.label)
        }

        let crossing = snapshot.windows
            .filter { $0.usedPercent >= threshold && !warned.contains($0.label) }
            .max { $0.usedPercent < $1.usedPercent }

        if let crossing {
            warned.insert(crossing.label)
            if Defaults[.showAIUsageWarnings] {
                warningService = service
                BoringViewCoordinator.shared.toggleExpandingView(
                    status: true, type: .aiUsage, value: crossing.usedPercent)
            }
        }
        warnedWindows[service] = warned
    }

    /// Shows the macOS Keychain dialog for the Claude Code item, then reloads.
    /// Returns a message when access still isn't working, nil on success.
    func grantClaudeKeychainAccess() async -> String? {
        let error = await XPCHelperClient.shared.requestClaudeKeychainAccess()
        await refresh()
        guard let error else { return nil }
        switch error {
        case "denied": return "Access was denied. Try again and choose Allow or Always Allow."
        case "notSignedIn": return "No Claude Code sign-in found. Sign in with Claude Code first."
        case "credentialsUnreadable": return "Couldn't read the Claude Code sign-in."
        case "helperUnavailable": return "Helper unavailable"
        default: return "Keychain returned \(error.replacingOccurrences(of: "api:", with: ""))"
        }
    }

    /// The window that triggered the current warning, for the closed-notch view.
    var warningWindow: UsageWindow? {
        guard let service = warningService, case .loaded(let snapshot) = state(for: service) else { return nil }
        return snapshot.windows.max { $0.usedPercent < $1.usedPercent }
    }
}
