import Foundation

struct SCELECourse: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let fullName: String
    let shortName: String
    let startDate: TimeInterval?
    let endDate: TimeInterval?
    let lastAccess: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id, fullName = "fullname", shortName = "shortname"
        case startDate = "startdate", endDate = "enddate", lastAccess = "lastaccess"
    }

    var title: String { SCELEText.plain(shortName) }
    var subtitle: String { SCELEText.plain(fullName) }

    func isCurrent(at date: Date) -> Bool {
        let now = date.timeIntervalSince1970
        if let startDate, startDate > now { return false }
        if let endDate, endDate > 0 { return endDate >= now }
        // Some SCELE courses never set an end date. Prefer recently started/accessed courses.
        return (startDate ?? 0) >= now - 180 * 86_400
            || (lastAccess ?? 0) >= now - 90 * 86_400
    }
}

struct SCELECredential: Codable, Sendable {
    let token: String
    let userID: Int
    let username: String
    let fullName: String
    let functions: Set<String>
}

enum SCELETaskKind: String, Codable, Sendable {
    case assignment, quiz
}

enum SCELESubmissionState: String, Codable, Sendable {
    case unknown, notSubmitted, draft, submitted, inProgress, completed

    var isFinished: Bool { self == .submitted || self == .completed }

    var title: String {
        switch self {
        case .unknown: return "Status unavailable"
        case .notSubmitted: return "Not submitted"
        case .draft: return "Draft"
        case .submitted: return "Submitted"
        case .inProgress: return "In progress"
        case .completed: return "Attempt finished"
        }
    }
}

struct SCELETask: Codable, Identifiable, Equatable, Sendable {
    let instanceID: Int
    let moduleID: Int
    let courseID: Int
    let courseName: String
    let title: String
    let kind: SCELETaskKind
    var dueDate: Date
    var submission: SCELESubmissionState

    var id: String { "\(kind.rawValue)-\(instanceID)" }
    var url: URL {
        let module = kind == .assignment ? "assign" : "quiz"
        // Both the module name and numeric id come from typed values, never a server-provided URL.
        return URL(string: "https://scele.cs.ui.ac.id/mod/\(module)/view.php?id=\(moduleID)")!
    }

    func isInDisplayRange(at date: Date) -> Bool {
        dueDate >= date.addingTimeInterval(-7 * 86_400)
            && dueDate <= date.addingTimeInterval(60 * 86_400)
    }

    static func deadlineOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.dueDate == rhs.dueDate ? lhs.id < rhs.id : lhs.dueDate < rhs.dueDate
    }
}

struct SCELECache: Codable, Sendable {
    let userID: Int
    var courses: [SCELECourse]
    var selectedCourseIDs: Set<Int>
    var hiddenTaskIDs: Set<String>
    var tasks: [SCELETask]
    var updatedAt: Date?
    var statusFailureCount: Int
}

struct SCELETaskResult: Sendable {
    let tasks: [SCELETask]
    let statusFailureCount: Int
}

enum SCELEError: Error, LocalizedError, Equatable, Sendable {
    case invalidLogin, expiredSession, unavailableService, badResponse, network, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidLogin: return "SCELE could not sign you in. Check your username and password."
        case .expiredSession: return "Your SCELE session has expired. Sign in again in Settings → SCELE."
        case .unavailableService: return "This account cannot access the required Moodle mobile service."
        case .badResponse: return "SCELE returned an unexpected response. Try refreshing in a moment."
        case .network: return "Could not reach SCELE. Your saved tasks are still available."
        case .keychain: return "Could not access the SCELE token in Keychain. Unlock your login keychain and try again."
        }
    }
}

enum SCELEText {
    static func plain(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                        "&nbsp;": " ", "&ndash;": "–", "&mdash;": "—", "&rsquo;": "’"]
        for (entity, value) in entities { result = result.replacingOccurrences(of: entity, with: value) }
        let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        let matches = regex?.matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []
        for match in matches.reversed() {
            guard let numberRange = Range(match.range(at: 1), in: result),
                  let range = Range(match.range, in: result) else { continue }
            let number = String(result[numberRange])
            let code = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
            if let code, let scalar = UnicodeScalar(code) { result.replaceSubrange(range, with: String(scalar)) }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
