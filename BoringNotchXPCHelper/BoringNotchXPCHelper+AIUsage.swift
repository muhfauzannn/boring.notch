//
//  BoringNotchXPCHelper+AIUsage.swift
//  BoringNotchXPCHelper
//
//  Reads the existing Claude Code / Codex CLI sign-in and fetches plan usage.
//  Lives in the helper because the sandboxed app cannot read another app's
//  Keychain item or files in the user's home folder. Tokens never leave the helper.
//

import Foundation
import Security

extension BoringNotchXPCHelper {

    /// Replies with a JSON envelope `{"plan": String?, "usage": Object}` or an error code:
    /// `notSignedIn`, `expired`, `http:<status>`, `network:<description>`, `badResponse`, `unknownService`.
    @objc func fetchAIUsage(_ service: String, with reply: @escaping (Data?, String?) -> Void) {
        switch service {
        case "claude":
            fetchClaudeUsage(reply)
        case "chatgpt":
            fetchCodexUsage(reply)
        default:
            reply(nil, "unknownService")
        }
    }

    // MARK: - Claude (Claude Code OAuth sign-in)

    private func fetchClaudeUsage(_ reply: @escaping (Data?, String?) -> Void) {
        guard let credentials = claudeCredentials(),
              let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            reply(nil, "notSignedIn")
            return
        }

        // Never refresh the token ourselves, so Claude Code's own session stays intact.
        if let expiresAt = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: expiresAt / 1000) < Date() {
            reply(nil, "expired")
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let plan = oauth["subscriptionType"] as? String
        perform(request, plan: plan, reply: reply)
    }

    private func claudeCredentials() -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        // Older Claude Code versions store the sign-in in a file instead of the Keychain.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - ChatGPT (Codex CLI sign-in)

    private func fetchCodexUsage(_ reply: @escaping (Data?, String?) -> Void) {
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: codexHome.appendingPathComponent("auth.json")),
              let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String, !token.isEmpty
        else {
            reply(nil, "notSignedIn")
            return
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = tokens["account_id"] as? String {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        perform(request, plan: nil, reply: reply)
    }

    // MARK: - Request

    private func perform(_ request: URLRequest, plan: String?, reply: @escaping (Data?, String?) -> Void) {
        var request = request
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                reply(nil, "network:\(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                reply(nil, "badResponse")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                reply(nil, http.statusCode == 401 ? "expired" : "http:\(http.statusCode)")
                return
            }
            guard let data, let usage = try? JSONSerialization.jsonObject(with: data) else {
                reply(nil, "badResponse")
                return
            }

            var envelope: [String: Any] = ["usage": usage]
            if let plan { envelope["plan"] = plan }
            reply(try? JSONSerialization.data(withJSONObject: envelope), nil)
        }.resume()
    }
}
