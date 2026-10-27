//
//  BoringNotchXPCHelper+AIUsage.swift
//  BoringNotchXPCHelper
//
//  Reads the existing Claude Code / Codex CLI sign-in and fetches plan usage.
//  Lives in the helper because the sandboxed app cannot read another app's
//  Keychain item or files in the user's home folder. Tokens never leave the helper.
//

import Foundation

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
    }

    private func claudeCredentials() -> Result<[String: Any], CredentialError> {
        // Claude Code stores its sign-in with `security add-generic-password`, so only
        // /usr/bin/security is on the item's access list. Reading it through the Security
        // framework from this helper would need an approval prompt, which an XPC service
        // can't reliably show, so the read fails and looks like "not signed in".
        // Going through the same tool Claude Code uses needs no prompt.
        var lastFailure: CredentialError?
        for account in [NSUserName(), nil] as [String?] {
            var arguments = ["find-generic-password", "-s", "Claude Code-credentials"]
            if let account { arguments += ["-a", account] }
            arguments.append("-w")

            switch runSecurityTool(arguments) {
            case .success(let output):
                if let json = parseCredentialOutput(output) { return .success(json) }
                lastFailure = CredentialError(code: "credentialsUnreadable")
            case .failure(let error):
                // 44 = errSecItemNotFound: try the next account lookup, then the file.
                if error.code != "keychain:44" { return .failure(error) }
                lastFailure = lastFailure ?? CredentialError(code: "notSignedIn")
            }
        }

        // Older Claude Code versions store the sign-in in a file instead of the Keychain.
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return .success(json)
        }
        return .failure(lastFailure ?? CredentialError(code: "notSignedIn"))
    }

    private func runSecurityTool(_ arguments: [String]) -> Result<String, CredentialError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return .failure(CredentialError(code: "keychain:launch"))
        }

        // A locked Keychain makes `security` wait for the user; don't hang the helper.
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            if process.isRunning { process.terminate() }
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return .failure(CredentialError(code: "keychain:\(process.terminationStatus)"))
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
