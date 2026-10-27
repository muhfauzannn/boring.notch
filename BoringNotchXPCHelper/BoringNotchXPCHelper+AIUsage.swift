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
    /// `notSignedIn`, `keychainApproval`, `expired`, `http:<status>`, `network:<description>`,
    /// `badResponse`, `unknownService`.
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
        let credentials: [String: Any]
        switch claudeCredentials() {
        case .success(let found):
            credentials = found
        case .failure(let error):
            reply(nil, error.code)
            return
        }

        guard let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            // Signed in with an API key or CLAUDE_CODE_OAUTH_TOKEN: no plan limits to show.
            reply(nil, "noAccountLogin")
            return
        }

        // Never refresh the token ourselves, so Claude Code's own session stays intact.
        // An expired token simply comes back as a 401 below.
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let plan = oauth["subscriptionType"] as? String
        perform(request, plan: plan, reply: reply)
    }

    private struct CredentialError: Error {
        let code: String
        /// Exit status of `security`, when that is what failed.
        var status: Int32?
    }

    private func claudeCredentials() -> Result<[String: Any], CredentialError> {
        // Claude Code stores its sign-in with `security add-generic-password`, so only
        // /usr/bin/security is on the item's access list. Reading it through the Security
        // framework from this helper would need an approval prompt, which an XPC service
        // can't reliably show, so the read fails and looks like "not signed in".
        // Going through the same tool Claude Code uses needs no prompt.
        let loginKeychain = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/login.keychain-db").path

        var firstFailure: CredentialError?
        var unreadable = false

        func lookup(in keychain: String?) -> [String: Any]? {
            for account in [nil, NSUserName()] as [String?] {
                var arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
                if let account { arguments += ["-a", account] }
                arguments.append("-w")
                if let keychain { arguments.append(keychain) }

                switch runSecurityTool(arguments) {
                case .success(let output):
                    if let json = parseCredentialOutput(output) { return json }
                    unreadable = true
                case .failure(let error):
                    // 44 = errSecItemNotFound: try the next lookup.
                    if error.status == 44 { continue }
                    firstFailure = firstFailure ?? error
                    return nil
                }
            }
            return nil
        }

        // Plain lookup first. If the default keychain can't be resolved or reached from this
        // process, retry with the login keychain named explicitly.
        if let json = lookup(in: nil) { return .success(json) }
        if firstFailure != nil, let json = lookup(in: loginKeychain) { return .success(json) }

        // Then ask the Keychain directly, as this helper. It never shows a dialog on a background
        // poll: if approval is needed it fails, and the user grants it from Settings once
        // (see requestClaudeKeychainAccess). After "Always Allow" this read succeeds silently.
        let direct = readClaudeKeychainItem(allowPrompt: false)
        if let json = direct.json { return .success(json) }

        // Older Claude Code versions store the sign-in in a file instead of the Keychain.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return .success(json)
        }

        let needsApproval = [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled]
        if needsApproval.contains(direct.status) {
            return .failure(CredentialError(code: "keychainApproval"))
        }
        if let firstFailure {
            return .failure(CredentialError(
                code: "\(firstFailure.code) [api \(direct.status)]", status: firstFailure.status))
        }
        return .failure(CredentialError(code: unreadable ? "credentialsUnreadable" : "notSignedIn"))
    }

    /// Reads the "Claude Code-credentials" item through the Security framework.
    /// With `allowPrompt` false, an item that needs approval fails with
    /// `errSecInteractionNotAllowed` instead of asking; with true, macOS shows its
    /// "wants to use your confidential information" dialog (Allow / Always Allow / Deny).
    private func readClaudeKeychainItem(allowPrompt: Bool) -> (json: [String: Any]?, status: OSStatus) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowPrompt {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return (nil, status) }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json, status)
        }
        // Stored as hex text rather than raw JSON.
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (parseCredentialOutput(text), status)
    }

    /// One-time approval, started by the user from Settings > AI Usage. Replies nil once the item
    /// can be read, or an error code: `notSignedIn`, `denied`, `api:<OSStatus>`.
    @objc func requestClaudeKeychainAccess(with reply: @escaping (String?) -> Void) {
        // The system dialog blocks this call until the user answers it.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.readClaudeKeychainItem(allowPrompt: true)
            switch result.status {
            case errSecSuccess:
                reply(result.json == nil ? "credentialsUnreadable" : nil)
            case errSecItemNotFound:
                reply("notSignedIn")
            case errSecUserCanceled, errSecAuthFailed:
                reply("denied")
            default:
                reply("api:\(result.status)")
            }
        }
    }

    private func runSecurityTool(_ arguments: [String]) -> Result<String, CredentialError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        // An XPC service can start with a thin environment; `security` finds the user's
        // keychains from HOME.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return .failure(CredentialError(code: "keychain:launch:\(error.localizedDescription)"))
        }

        // A locked Keychain makes `security` wait for the user to type a password. Give them
        // time to do that, but don't hang the helper forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
            if process.isRunning { process.terminate() }
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationReason == .uncaughtSignal {
            return .failure(CredentialError(code: "keychain:timeout"))
        }
        guard process.terminationStatus == 0 else {
            // Keep the first line of stderr: it says why (locked, denied, no default keychain).
            let detail = String(decoding: errorData, as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            return .failure(CredentialError(
                code: "keychain:\(process.terminationStatus):\(detail)",
                status: process.terminationStatus))
        }
        return .success(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `security -w` prints the JSON as text, or as hex when the stored bytes aren't printable.
    private func parseCredentialOutput(_ output: String) -> [String: Any]? {
        var data = Data(output.utf8)
        if !output.hasPrefix("{"), output.count % 2 == 0,
           output.allSatisfy({ $0.isHexDigit }) {
            var bytes = [UInt8]()
            var index = output.startIndex
            while index < output.endIndex {
                let next = output.index(index, offsetBy: 2)
                guard let byte = UInt8(output[index..<next], radix: 16) else { return nil }
                bytes.append(byte)
                index = next
            }
            data = Data(bytes)
        }
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
