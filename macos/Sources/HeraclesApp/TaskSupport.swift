import Foundation
import HeraclesCore
import UserNotifications

/// Reading and writing the dates stored on tasks. They are UTC timestamps in
/// the form JavaScript's `toISOString` writes, which is what the original
/// app stored.
public enum TaskDates {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()

    public static func date(from string: String, in zone: TimeZone = .current) -> Date? {
        if let date = try? withFraction.parse(string) { return date }
        if let date = try? withoutFraction.parse(string) { return date }
        // A bare day, such as "2026-12-01".
        return try? Date.ISO8601FormatStyle(timeZone: zone).year().month().day().parse(string)
    }

    public static func string(from date: Date) -> String {
        withFraction.format(date)
    }

    /// A due date: nine in the morning, local time, on the chosen day.
    public static func dueDate(on day: Date, in zone: TimeZone = .current) -> String {
        string(from: time(hour: 9, on: day, in: zone))
    }

    /// A deadline: five in the afternoon, local time, on the chosen day.
    public static func deadline(on day: Date, in zone: TimeZone = .current) -> String {
        string(from: time(hour: 17, on: day, in: zone))
    }

    private static func time(hour: Int, on day: Date, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// A stored date as a card shows it: "1 Dec", with the year if it is not
    /// this one.
    public static func label(for string: String) -> String {
        guard let date = date(from: string) else { return string }
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
    }
}

/// A notification to schedule for a task's reminder.
public struct PlannedReminder: Equatable, Sendable {
    public var identifier: String
    public var title: String
    /// The todo list to open when the notification is clicked.
    public var noteID: String
    public var date: Date
}

/// A notification the system is holding, and what it says, where that can
/// be read.
public struct ScheduledReminder: Equatable, Sendable {
    public var identifier: String
    public var title: String?

    public init(identifier: String, title: String?) {
        self.identifier = identifier
        self.title = title
    }
}

/// What to change so that the notifications the system holds match the
/// reminders the library has. Worked out apart from the system calls, so it
/// can be tested.
public struct ReminderPlan: Equatable, Sendable {
    /// Marks a notification as one of this app's reminders.
    public static let prefix = "heracles.reminder."

    public let toAdd: [PlannedReminder]
    public let toRemove: [String]

    /// The plan, knowing the waiting notifications only by their identifiers.
    public init(reminders: [Reminder], scheduled: [String], now: Date) {
        self.init(reminders: reminders, waiting: scheduled.map { ScheduledReminder(identifier: $0, title: nil) }, now: now)
    }

    /// The plan, knowing what each waiting notification says. One that names
    /// a task by a title it no longer has is scheduled again: its
    /// identifier does not change when a task is renamed, so nothing else
    /// would notice. It is not also removed, because the system replaces a
    /// waiting notification when another is scheduled under its identifier.
    public init(reminders: [Reminder], waiting: [ScheduledReminder], now: Date) {
        var wanted: [PlannedReminder] = []
        var wantedIDs: Set<String> = []
        for reminder in reminders {
            guard let date = TaskDates.date(from: reminder.remindAt), date > now else { continue }
            let identifier = "\(Self.prefix)\(reminder.taskId).\(reminder.remindAt)"
            // One notification for a reminder, however often it is listed.
            guard wantedIDs.insert(identifier).inserted else { continue }
            let title = reminder.taskTitle.trimmingCharacters(in: .whitespaces)
            wanted.append(
                PlannedReminder(
                    identifier: identifier, title: title.isEmpty ? "Untitled task" : title,
                    noteID: reminder.todoListId, date: date))
        }
        var says: [String: String?] = [:]
        for notification in waiting where says[notification.identifier] == nil {
            says[notification.identifier] = .some(notification.title)
        }
        toAdd = wanted.filter { reminder in
            // Not waiting at all, or waiting and saying something else.
            guard let said = says[reminder.identifier] else { return true }
            return said != nil && said != reminder.title
        }
        toRemove = waiting.map(\.identifier).filter { $0.hasPrefix(Self.prefix) && !wantedIDs.contains($0) }
    }
}

/// Whether this run hands reminders to the system.
enum ReminderPolicy {
    /// A run against a library named in the environment is a trial or a
    /// test. Its reminders are not the user's: handing them over would put
    /// a fixture's notifications on the screen, and take back the ones the
    /// real library is waiting on.
    static func schedules(environment: [String: String]) -> Bool {
        (environment["HERACLES_DATA_DIR"] ?? "").isEmpty
    }
}

/// A task shown in a window of its own: which list it is on, and the task
/// the window was opened on. One window for each: asked for again, the
/// window that has it comes forward.
public struct TaskWindowID: Hashable, Codable, Sendable {
    public var todoListID: String
    public var taskID: String

    public init(todoListID: String, taskID: String) {
        self.todoListID = todoListID
        self.taskID = taskID
    }
}

/// Which task a task window shows: the task it starts from, and the
/// subtasks drilled into below it, outermost first.
struct TaskPath: Equatable {
    var root: String
    var down: [String] = []

    /// The task being shown.
    var shown: String { down.last ?? root }

    /// The tasks above the one shown, outermost first.
    var above: [String] { Array(([root] + down).dropLast()) }

    /// The path as it stands among the tasks the board has now. `nil` when
    /// the task the window starts from has gone, and the window should
    /// close.
    func settled(among tasks: [TodoTask]) -> TaskPath? {
        let byID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chain = [root] + down
        // A subtask that has become a card is no longer under anything: the
        // window starts from it, and there is no way back up.
        if let card = chain.indices.dropFirst().last(where: { byID[chain[$0]].map { $0.parentTaskId == nil } ?? false }) {
            chain.removeFirst(card)
        }
        guard byID[chain[0]] != nil else { return nil }
        // The way down holds for as long as each task is there, under the
        // one before.
        var settled = TaskPath(root: chain[0])
        for id in chain.dropFirst() {
            guard byID[id]?.parentTaskId == settled.shown else { break }
            settled.down.append(id)
        }
        return settled
    }
}

/// Keeps the system's scheduled notifications in step with the reminders on
/// tasks. The system delivers them whether or not the app is running.
@MainActor
final class ReminderScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let model: AppModel
    private let center: UNUserNotificationCenter
    private var pending: Task<Void, Never>?

    /// `nil` when the process is not a bundled app. Notifications belong to
    /// a bundle, and asking for them without one stops the process.
    init?(model: AppModel) {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        self.model = model
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
    }

    /// Sync soon. Changes arrive in bursts, and one sync covers a burst.
    func syncSoon() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    func sync() async {
        guard let reminders = try? model.store.listReminders() else { return }
        let waiting = await center.pendingNotificationRequests().map {
            ScheduledReminder(identifier: $0.identifier, title: $0.content.title)
        }
        let plan = ReminderPlan(reminders: reminders, waiting: waiting, now: .now)
        center.removePendingNotificationRequests(withIdentifiers: plan.toRemove)
        guard !plan.toAdd.isEmpty else { return }
        // Asked the first time there is something to remind about, not at launch.
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for reminder in plan.toAdd {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = "Reminder"
            content.sound = .default
            content.userInfo = ["noteID": reminder.noteID]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // Show reminders while the app is in front, too.
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let noteID = response.notification.request.content.userInfo["noteID"] as? String else { return }
        await MainActor.run { model.pendingLink = AppLink(noteID: noteID, blockID: nil) }
    }
}
