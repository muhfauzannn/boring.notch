//
//  AIUsageProviding.swift
//  boringNotch
//
//  Models and parsing for the AI Usage tab. The helper fetches the raw JSON
//  (see BoringNotchXPCHelper+AIUsage.swift); this file turns it into snapshots.
//  Both endpoints are undocumented, so parsing is deliberately lenient.
//

import Defaults
import Foundation
import SwiftUI

enum AIService: String, CaseIterable, Identifiable {
    case claude
    case chatgpt

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .chatgpt: return "ChatGPT"
        }
    }

    var logoAsset: String {
        switch self {
        case .claude: return "ClaudeLogo"
        case .chatgpt: return "OpenAILogo"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.91, green: 0.57, blue: 0.44)
        case .chatgpt: return Color(red: 0.24, green: 0.84, blue: 0.60)
        }
    }

    var isEnabled: Bool {
        switch self {
        case .claude: return Defaults[.showClaudeUsage]
        case .chatgpt: return Defaults[.showChatGPTUsage]
        }
    }

    var signInHint: String {
        switch self {
        case .claude: return "Sign in with Claude Code first"
        case .chatgpt: return "Run codex login first"
        }
    }
}

struct UsageWindow: Equatable {
    let label: String
    /// 0...100
    let usedPercent: Double
    let resetsAt: Date?
}

struct UsageSnapshot: Equatable {
    let plan: String?
    let windows: [UsageWindow]
    let updatedAt: Date

    var highestUsage: Double {
        windows.map(\.usedPercent).max() ?? 0
    }
}

enum UsageState: Equatable {
    case idle
    case loading
    case loaded(UsageSnapshot)
    case failed(String)
}

enum AIUsageParser {
    static func parse(_ data: Data, for service: AIService) -> UsageSnapshot? {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = envelope["usage"] as? [String: Any]
        else { return nil }

        switch service {
        case .claude:
            return parseClaude(usage, plan: envelope["plan"] as? String)
        case .chatgpt:
            return parseCodex(usage)
        }
    }

    // {"five_hour": {"utilization": 62.0, "resets_at": "2026-10-26T19:00:00.000+00:00"}, "seven_day": {...}, "seven_day_opus": {...}}
    private static func parseClaude(_ usage: [String: Any], plan: String?) -> UsageSnapshot? {
        let rows: [(key: String, label: String)] = [
            ("five_hour", "5-hour"),
            ("seven_day", "Weekly"),
            ("seven_day_opus", "Opus weekly"),
            ("seven_day_sonnet", "Sonnet weekly")
        ]
        let windows = rows.compactMap { row -> UsageWindow? in
            guard let window = usage[row.key] as? [String: Any],
                  let used = number(window["utilization"])
            else { return nil }
            return UsageWindow(label: row.label, usedPercent: clamp(used), resetsAt: date(window["resets_at"]))
        }
        guard !windows.isEmpty else { return nil }
        return UsageSnapshot(plan: claudePlanName(plan), windows: windows, updatedAt: Date())
    }

    // {"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": 23, "reset_at": 1793040000}, "secondary_window": {...}}}
    private static func parseCodex(_ usage: [String: Any]) -> UsageSnapshot? {
        guard let limits = (usage["rate_limit"] ?? usage["rate_limits"]) as? [String: Any] else { return nil }
        let rows: [(keys: [String], label: String)] = [
            (["primary_window", "primary"], "5-hour"),
            (["secondary_window", "secondary"], "Weekly")
        ]
        let windows = rows.compactMap { row -> UsageWindow? in
            guard let window = row.keys.lazy.compactMap({ limits[$0] as? [String: Any] }).first,
                  let used = number(window["used_percent"])
            else { return nil }
            var resetsAt = date(window["reset_at"] ?? window["resets_at"])
            if resetsAt == nil, let seconds = number(window["reset_after_seconds"] ?? window["resets_in_seconds"]) {
                resetsAt = Date().addingTimeInterval(seconds)
            }
            return UsageWindow(label: row.label, usedPercent: clamp(used), resetsAt: resetsAt)
        }
        guard !windows.isEmpty else { return nil }
        let plan = (usage["plan_type"] as? String).map { $0.capitalized }
        return UsageSnapshot(plan: plan, windows: windows, updatedAt: Date())
    }

    private static func claudePlanName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return raw.capitalized
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value), !(value is String) {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }

    static func message(for error: String, service: AIService) -> String {
        switch error {
        case "notSignedIn": return service.signInHint
        case "expired": return "Sign-in expired. Open \(service == .claude ? "Claude Code" : "Codex") to refresh it"
        case "helperUnavailable": return "Helper unavailable"
        case "noAccountLogin": return "Claude Code uses an API key, which has no plan limits"
        case "credentialsUnreadable": return "Couldn't read the Claude Code sign-in"
        case "badResponse": return "Unexpected response"
        default:
            if error.hasPrefix("keychain:") { return "Keychain access failed (\(error.dropFirst(9))). Unlock your Keychain and retry" }
            if error.hasPrefix("http:429") { return "Rate limited, will retry" }
            if error.hasPrefix("http:") { return "Request failed (\(error.dropFirst(5)))" }
            if error.hasPrefix("network:") { return "Offline" }
            return "Couldn't load usage"
        }
    }
}
