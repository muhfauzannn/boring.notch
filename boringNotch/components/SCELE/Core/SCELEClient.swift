import Foundation

/// Uses only read APIs after the normal Moodle mobile sign-in. Passwords and tokens stay in POST bodies.
struct SCELEClient: Sendable {
    static let site = URL(string: "https://scele.cs.ui.ac.id")!
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration, delegate: SCELEOriginGuard(), delegateQueue: nil)
        }
    }

    func signIn(username: String, password: String) async throws -> SCELECredential {
        let auth: TokenResponse = try await post("login/token.php", parameters: [
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password, "service": "moodle_mobile_app"
        ], signingIn: true)
        let info: SiteInfo = try await call("core_webservice_get_site_info", token: auth.token)
        let functions = Set(info.functions.map(\.name))
        guard functions.contains("mod_assign_get_assignments"),
              functions.contains("core_enrol_get_users_courses") else { throw SCELEError.unavailableService }
        return SCELECredential(token: auth.token, userID: info.userid, username: info.username,
                               fullName: SCELEText.plain(info.fullname), functions: functions)
    }

    func courses(using credential: SCELECredential) async throws -> [SCELECourse] {
        let courses: [SCELECourse] = try await call("core_enrol_get_users_courses", token: credential.token,
                                                  parameters: ["userid": String(credential.userID)])
        return courses.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func tasks(using credential: SCELECredential, courses: [SCELECourse], selectedIDs: Set<Int>,
               now: Date = Date()) async throws -> SCELETaskResult {
        let selected = courses.filter { selectedIDs.contains($0.id) }
        // Moodle treats an omitted/empty course list as ALL courses. An explicit empty selection means none here.
        guard !selected.isEmpty else { return SCELETaskResult(tasks: [], statusFailureCount: 0) }
        let parameters = Dictionary(uniqueKeysWithValues: selected.enumerated().map {
            ("courseids[\($0.offset)]", String($0.element.id))
        })
        async let assignments: AssignmentResponse = call("mod_assign_get_assignments", token: credential.token,
                                                        parameters: parameters)
        async let quizzes = quizzes(using: credential, parameters: parameters)
        let (assignmentResponse, quizResponse) = try await (assignments, quizzes)
        let names = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.title) })
        var tasks = assignmentResponse.courses.flatMap { course in
            course.assignments.compactMap { assignment -> SCELETask? in
                guard assignment.duedate > 0, let courseName = names[course.id] else { return nil }
                return SCELETask(instanceID: assignment.id, moduleID: assignment.cmid, courseID: course.id,
                                 courseName: courseName, title: SCELEText.plain(assignment.name), kind: .assignment,
                                 dueDate: Date(timeIntervalSince1970: assignment.duedate), submission: .unknown)
            }
        }
        tasks += quizResponse.quizzes.compactMap { quiz in
            guard quiz.timeclose > 0, let courseName = names[quiz.course] else { return nil }
            return SCELETask(instanceID: quiz.id, moduleID: quiz.coursemodule, courseID: quiz.course,
                             courseName: courseName, title: SCELEText.plain(quiz.name), kind: .quiz,
                             dueDate: Date(timeIntervalSince1970: quiz.timeclose), submission: .unknown)
        }
        tasks = tasks.filter { $0.isInDisplayRange(at: now) }.sorted(by: SCELETask.deadlineOrder)
        var enriched: [SCELETask] = []
        var failures = 0
        // Bound concurrency so a large enrollment does not flood the campus server.
        for start in stride(from: 0, to: tasks.count, by: 4) {
            try Task.checkCancellation()
            let batch = Array(tasks[start..<min(start + 4, tasks.count)])
            let results = try await withThrowingTaskGroup(of: (SCELETask, Bool).self) { group in
                for task in batch { group.addTask { try await taskWithStatus(task, credential: credential) } }
                var results: [(SCELETask, Bool)] = []
                for try await result in group { results.append(result) }
                return results
            }
            for (task, failed) in results {
                enriched.append(task)
                if failed { failures += 1 }
            }
        }
        return SCELETaskResult(tasks: enriched.sorted(by: SCELETask.deadlineOrder), statusFailureCount: failures)
    }

    private func quizzes(using credential: SCELECredential, parameters: [String: String]) async throws -> QuizResponse {
        guard credential.functions.contains("mod_quiz_get_quizzes_by_courses") else { return QuizResponse(quizzes: []) }
        return try await call("mod_quiz_get_quizzes_by_courses", token: credential.token, parameters: parameters)
    }

    private func taskWithStatus(_ original: SCELETask, credential: SCELECredential) async throws -> (SCELETask, Bool) {
        var task = original
        do {
            if task.kind == .assignment {
                guard credential.functions.contains("mod_assign_get_submission_status") else { return (task, true) }
                let response: SubmissionResponse = try await call("mod_assign_get_submission_status", token: credential.token,
                                                                  parameters: ["assignid": String(task.instanceID)])
                guard let attempt = response.lastattempt else { return (task, true) }
                task.submission = attempt.state
                if let extensionDate = attempt.extensionduedate, extensionDate > task.dueDate.timeIntervalSince1970 {
                    task.dueDate = Date(timeIntervalSince1970: extensionDate)
                }
            } else {
                guard credential.functions.contains("mod_quiz_get_user_attempts") else { return (task, true) }
                let response: QuizAttempts = try await call("mod_quiz_get_user_attempts", token: credential.token,
                                                            parameters: ["quizid": String(task.instanceID), "status": "all"])
                // A finished attempt does not mean a repeatable quiz cannot be attempted again.
                task.submission = response.attempts.contains { $0.state == "inprogress" || $0.state == "overdue" }
                    ? .inProgress : (response.attempts.contains { $0.state == "finished" } ? .completed : .notSubmitted)
            }
            return (task, task.submission == .unknown)
        } catch is CancellationError { throw CancellationError() }
        catch let error as SCELEError where error == .expiredSession { throw error }
        catch {
            try Task.checkCancellation()
            // Keep a deadline even when its individual status cannot be read. Never call it "not submitted".
            return (task, true)
        }
    }

    private func call<T: Decodable>(_ function: String, token: String,
                                     parameters: [String: String] = [:]) async throws -> T {
        var parameters = parameters
        parameters["wstoken"] = token
        parameters["wsfunction"] = function
        parameters["moodlewsrestformat"] = "json"
        return try await post("webservice/rest/server.php", parameters: parameters)
    }

    private func post<T: Decodable>(_ path: String, parameters: [String: String], signingIn: Bool = false) async throws -> T {
        var request = URLRequest(url: Self.site.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SCELEError.network
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.host == Self.site.host else { throw SCELEError.badResponse }
        let decoder = JSONDecoder()
        if let failure = try? decoder.decode(MoodleFailure.self, from: data), let code = failure.errorcode {
            switch code {
            case "invalidlogin": throw SCELEError.invalidLogin
            case "invalidtoken", "accessexception": throw SCELEError.expiredSession
            case "webservicedisabled", "servicenotavailable", "enablewsdescription", "wscallnotavailable":
                throw SCELEError.unavailableService
            default: throw signingIn ? SCELEError.invalidLogin : SCELEError.badResponse
            }
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw SCELEError.badResponse }
    }
}

private final class SCELEOriginGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a credential-bearing body to a redirect destination, even on the same host.
        completionHandler(nil)
    }
}

private struct TokenResponse: Decodable { let token: String }
private struct MoodleFailure: Decodable { let errorcode: String? }
private struct SiteInfo: Decodable {
    let userid: Int
    let username: String
    let fullname: String
    let functions: [Function]
    struct Function: Decodable { let name: String }
}
private struct AssignmentResponse: Decodable {
    let courses: [Course]
    struct Course: Decodable { let id: Int; let assignments: [Assignment] }
    struct Assignment: Decodable {
        let id: Int
        let cmid: Int
        let name: String
        let duedate: TimeInterval
    }
}
private struct QuizResponse: Decodable {
    let quizzes: [Quiz]
    struct Quiz: Decodable {
        let id: Int
        let course: Int
        let coursemodule: Int
        let name: String
        let timeclose: TimeInterval
    }
}
struct SCELESubmissionAttempt: Decodable {
    let submission: Submission?
    let teamsubmission: Submission?
    let extensionduedate: TimeInterval?
    struct Submission: Decodable { let status: String }

    var state: SCELESubmissionState {
        // A team submission is authoritative for group assignments.
        switch (teamsubmission ?? submission)?.status {
        case "submitted": return .submitted
        case "draft": return .draft
        case "new": return .notSubmitted
        case nil: return .notSubmitted
        default: return .unknown
        }
    }
}
private struct SubmissionResponse: Decodable { let lastattempt: SCELESubmissionAttempt? }
private struct QuizAttempts: Decodable {
    let attempts: [Attempt]
    struct Attempt: Decodable { let state: String }
}
