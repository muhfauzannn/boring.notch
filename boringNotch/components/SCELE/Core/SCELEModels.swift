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

    static func onDay(_ date: Date, calendar: Calendar, tasks: [Self], selectedIDs: Set<Int>,
                      hiddenIDs: Set<String>, hideSubmitted: Bool) -> [Self] {
        guard let day = calendar.dateInterval(of: .day, for: date) else { return [] }
        return tasks.filter {
            $0.dueDate >= day.start && $0.dueDate < day.end && selectedIDs.contains($0.courseID)
                && !hiddenIDs.contains($0.id) && !(hideSubmitted && $0.submission.isFinished)
        }.sorted(by: Self.deadlineOrder)
    }
}

enum SCELESyncInterval {
    static let minuteRange = 1...1440

    static func minutes(_ configured: Int) -> Int {
        min(max(configured, minuteRange.lowerBound), minuteRange.upperBound)
    }

    static func seconds(_ configured: Int) -> TimeInterval { TimeInterval(minutes(configured)) * 60 }

    static func isFresh(updatedAt: Date?, now: Date = Date(), minutes: Int) -> Bool {
        guard let updatedAt else { return false }
        let age = now.timeIntervalSince(updatedAt)
        return age >= 0 && age < seconds(minutes)
    }

    static func nextDelay(updatedAt: Date?, now: Date = Date(), minutes: Int) -> TimeInterval {
        let interval = seconds(minutes)
        guard let updatedAt else { return interval }
        let age = now.timeIntervalSince(updatedAt)
        // A failed/stale refresh retries after an interval instead of spinning in a tight loop.
        return age >= 0 && age < interval ? interval - age : interval
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
    // Optional for caches written before new-task notifications were introduced.
    var discovery: SCELETaskDiscovery? = nil
}

struct SCELETaskResult: Sendable {
    let tasks: [SCELETask]
    let statusFailureCount: Int
    let inventoryIDs: Set<String>

    init(tasks: [SCELETask], statusFailureCount: Int, inventoryIDs: Set<String> = []) {
        self.tasks = tasks
        self.statusFailureCount = statusFailureCount
        self.inventoryIDs = inventoryIDs
    }
}

/// A durable baseline per course, separate from the rolling deadline list.
/// A previously known activity entering the 60-day window is not a newly published task.
struct SCELETaskDiscovery: Codable, Sendable {
    private(set) var seenIDs: Set<String> = []
    private(set) var baselinedCourseIDs: Set<Int> = []

    mutating func selectCourses(_ ids: Set<Int>) {
        // Re-selecting a course should establish a fresh baseline, without announcing its backlog.
        baselinedCourseIDs.formIntersection(ids)
    }

    mutating func discover(in result: SCELETaskResult, courseIDs: Set<Int>, hiddenIDs: Set<String>,
                           now: Date = Date()) -> [SCELETask] {
        let newTasks = result.tasks.filter {
            courseIDs.contains($0.courseID) && baselinedCourseIDs.contains($0.courseID)
                && !seenIDs.contains($0.id) && !hiddenIDs.contains($0.id)
                && !$0.submission.isFinished && $0.dueDate > now
        }
        seenIDs.formUnion(result.inventoryIDs)
        seenIDs.formUnion(result.tasks.map(\.id))
        baselinedCourseIDs.formIntersection(courseIDs)
        baselinedCourseIDs.formUnion(courseIDs)
        return newTasks.sorted(by: SCELETask.deadlineOrder)
    }
}

struct SCELETaskAnnouncement: Identifiable, Equatable, Sendable {
    let id = UUID()
    let tasks: [SCELETask]
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
