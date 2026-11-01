import Foundation
import Testing
@testable import SCELECore

private final class StubRegistry: @unchecked Sendable {
    static let shared = StubRegistry()
    private let lock = NSLock()
    private var handlers: [String: @Sendable (URLRequest) -> (String, Int)] = [:]

    func register(_ handler: @escaping @Sendable (URLRequest) -> (String, Int)) -> String {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        return id
    }

    func response(for request: URLRequest) -> (String, Int) {
        let handler = lock.withLock { handlers[request.value(forHTTPHeaderField: "X-SCELE-Test") ?? ""] }
        return handler?(request) ?? ("{}", 500)
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (json, code) = StubRegistry.shared.response(for: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func client(_ handler: @escaping @Sendable (URLRequest) -> (String, Int)) -> SCELEClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    configuration.httpAdditionalHeaders = ["X-SCELE-Test": StubRegistry.shared.register(handler)]
    return SCELEClient(session: URLSession(configuration: configuration))
}

private func parameters(_ request: URLRequest) -> [String: String] {
    var body = request.httpBody ?? Data()
    if body.isEmpty, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
    let encoded = String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20")
    var components = URLComponents()
    components.percentEncodedQuery = encoded
    return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
}

private let credential = SCELECredential(token: "test-token", userID: 44, username: "student",
                                        fullName: "Student", functions: [
    "mod_assign_get_assignments", "mod_assign_get_submission_status", "mod_quiz_get_quizzes_by_courses",
    "mod_quiz_get_user_attempts", "core_enrol_get_users_courses"
])
private let now = Date(timeIntervalSince1970: 1_790_000_000)
private let course = SCELECourse(id: 7, fullName: "Analysis &amp; Design", shortName: "APAP",
                                startDate: nil, endDate: nil, lastAccess: nil)

@Test func signInEncodesSpecialCharactersAndKeepsCredentialsOutOfURL() async throws {
    let api = client { request in
        #expect(request.httpMethod == "POST")
        #expect(request.url?.scheme == "https")
        #expect(request.url?.query == nil)
        let form = parameters(request)
        if request.url?.lastPathComponent == "token.php" {
            #expect(form["username"] == "student")
            #expect(form["password"] == "a+b&c=d% 🌱")
            #expect(form["service"] == "moodle_mobile_app")
            return (#"{"token":"test-token"}"#, 200)
        }
        #expect(form["wstoken"] == "test-token")
        #expect(form["wsfunction"] == "core_webservice_get_site_info")
        return (#"{"userid":44,"username":"student","fullname":"Student","functions":[{"name":"mod_assign_get_assignments"},{"name":"core_enrol_get_users_courses"}]}"#, 200)
    }
    let session = try await api.signIn(username: " student ", password: "a+b&c=d% 🌱")
    #expect(session.userID == 44)
}

@Test func expiredTokenRequiresSignIn() async throws {
    let api = client { _ in (#"{"exception":"moodle_exception","errorcode":"invalidtoken","message":"secret server detail"}"#, 200) }
    await #expect(throws: SCELEError.expiredSession) { try await api.courses(using: credential) }
}

@Test func invalidPasswordHasActionableError() async throws {
    let api = client { _ in (#"{"error":"Invalid login","errorcode":"invalidlogin"}"#, 200) }
    await #expect(throws: SCELEError.invalidLogin) { try await api.signIn(username: "student", password: "wrong") }
}

@Test func emptyCourseSelectionNeverRequestsAllCourses() async throws {
    let api = client { _ in Issue.record("An empty selection must not send a request"); return ("{}", 500) }
    let result = try await api.tasks(using: credential, courses: [course], selectedIDs: [], now: now)
    #expect(result.tasks.isEmpty)
}

@Test func mergesAssignmentsAndQuizzesWithGroupSubmissionAndExtensions() async throws {
    let api = client { request in
        let form = parameters(request)
        switch form["wsfunction"] {
        case "mod_assign_get_assignments":
            #expect(form["courseids[0]"] == "7")
            #expect(form["courseids[1]"] == nil)
            return (#"{"courses":[{"id":7,"assignments":[{"id":12,"cmid":120,"name":"Design &amp; Model","duedate":1790003600}]}],"warnings":[{"warningcode":"1","message":"No access rights in module context"}]}"#, 200)
        case "mod_quiz_get_quizzes_by_courses":
            return (#"{"quizzes":[{"id":13,"course":7,"coursemodule":130,"name":"Quiz","timeclose":1790007200}]}"#, 200)
        case "mod_assign_get_submission_status":
            #expect(form["assignid"] == "12")
            #expect(form["assignmentid"] == nil)
            return (#"{"lastattempt":{"submission":{"status":"new"},"teamsubmission":{"status":"submitted"},"extensionduedate":1790010800}}"#, 200)
        case "mod_quiz_get_user_attempts":
            return (#"{"attempts":[{"state":"finished"}]}"#, 200)
        default: Issue.record("Unexpected API call"); return ("{}", 500)
        }
    }
    let result = try await api.tasks(using: credential, courses: [course], selectedIDs: [7], now: now)
    #expect(result.statusFailureCount == 0)
    #expect(result.tasks.map(\.id) == ["quiz-13", "assignment-12"])
    let assignment = try #require(result.tasks.last)
    #expect(assignment.title == "Design & Model")
    #expect(assignment.submission == .submitted)
    #expect(assignment.dueDate.timeIntervalSince1970 == 1_790_010_800)
    #expect(assignment.url.absoluteString == "https://scele.cs.ui.ac.id/mod/assign/view.php?id=120")
    #expect(result.tasks.first?.submission == .completed)
}

@Test func statusFailureKeepsDeadlineWithUnknownStatus() async throws {
    let api = client { request in
        switch parameters(request)["wsfunction"] {
        case "mod_assign_get_assignments":
            return (#"{"courses":[{"id":7,"assignments":[{"id":12,"cmid":120,"name":"Task","duedate":1790003600}]}]}"#, 200)
        case "mod_quiz_get_quizzes_by_courses": return (#"{"quizzes":[]}"#, 200)
        default: return (#"{"errorcode":"nopermissions"}"#, 200)
        }
    }
    let result = try await api.tasks(using: credential, courses: [course], selectedIDs: [7], now: now)
    #expect(result.tasks.count == 1)
    #expect(result.tasks.first?.submission == .unknown)
    #expect(result.statusFailureCount == 1)
}

@Test func expiredTokenDuringStatusFetchFailsWholeRefresh() async throws {
    let api = client { request in
        switch parameters(request)["wsfunction"] {
        case "mod_assign_get_assignments":
            return (#"{"courses":[{"id":7,"assignments":[{"id":12,"cmid":120,"name":"Task","duedate":1790003600}]}]}"#, 200)
        case "mod_quiz_get_quizzes_by_courses": return (#"{"quizzes":[]}"#, 200)
        default: return (#"{"errorcode":"invalidtoken"}"#, 200)
        }
    }
    await #expect(throws: SCELEError.expiredSession) {
        try await api.tasks(using: credential, courses: [course], selectedIDs: [7], now: now)
    }
}

@Test func cachedTasksAreAccountScopedAndHavePrivatePermissions() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SCELECacheStore(directory: directory)
    try store.save(SCELECache(userID: 44, courses: [course], selectedCourseIDs: [], hiddenTaskIDs: ["assignment-12"],
                              tasks: [], updatedAt: now, statusFailureCount: 0))
    #expect(store.read(userID: 45) == nil)
    let saved = try #require(store.read(userID: 44))
    #expect(saved.selectedCourseIDs.isEmpty)
    #expect(saved.hiddenTaskIDs == ["assignment-12"])
    let file = directory.appendingPathComponent("tasks.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains("token"))
    try store.delete()
    #expect(store.read(userID: 44) == nil)
}

@Test func decodesMoodleTitlesAndIgnoresUnknownStatusValues() throws {
    #expect(SCELEText.plain("<b>BST &amp; AVL</b> &#x1F331; &#39;Quiz&#39;") == "BST & AVL 🌱 'Quiz'")
    let attempt = try JSONDecoder().decode(SCELESubmissionAttempt.self, from: Data(#"{"submission":{"status":"future-state"}}"#.utf8))
    #expect(attempt.state == .unknown)
}

@Test func keychainTokenCanBeSavedReplacedAndRemoved() throws {
    // A unique service keeps this smoke test separate from the app's real account.
    let store = SCELECredentialStore(service: "boringnotch.tests.scele." + UUID().uuidString)
    defer { try? store.delete() }
    #expect(try store.read() == nil)
    try store.save(credential)
    #expect(try store.read()?.token == "test-token")
    let replacement = SCELECredential(token: "replacement-token", userID: 44, username: "student",
                                      fullName: "Student", functions: credential.functions)
    try store.save(replacement)
    #expect(try store.read()?.token == "replacement-token")
    try store.delete()
    #expect(try store.read() == nil)
}
