import Foundation
import HeraclesCore
import Testing

@testable import HeraclesApp

struct TaskDatesTests {
    private let utc = TimeZone(identifier: "UTC")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    @Test func storedTimesAreReadWithOrWithoutFractionsOfASecond() {
        let expected = Date(timeIntervalSince1970: 1_796_029_200)  // 2026-11-30 09:00:00 UTC
        #expect(TaskDates.date(from: "2026-11-30T09:00:00.000Z") == expected)
        #expect(TaskDates.date(from: "2026-11-30T09:00:00Z") == expected)
        #expect(TaskDates.date(from: "nonsense") == nil)
        #expect(TaskDates.date(from: "") == nil)
    }

    @Test func aBareDateIsReadAsThatDay() {
        let date = TaskDates.date(from: "2026-12-01", in: utc)
        #expect(date == Date(timeIntervalSince1970: 1_796_083_200))  // 2026-12-01 00:00 UTC
    }

    @Test func timesAreWrittenTheWayTheOriginalAppWroteThem() {
        let date = Date(timeIntervalSince1970: 1_796_029_200.25)
        #expect(TaskDates.string(from: date) == "2026-11-30T09:00:00.250Z")
        #expect(TaskDates.date(from: TaskDates.string(from: date)) == date)
    }

    @Test func aDueDateIsNineInTheMorningAndADeadlineFiveInTheAfternoonLocalTime() {
        let day = TaskDates.date(from: "2026-12-01T15:30:00Z")!  // 10:30 in New York
        #expect(TaskDates.dueDate(on: day, in: newYork) == "2026-12-01T14:00:00.000Z")
        #expect(TaskDates.deadline(on: day, in: newYork) == "2026-12-01T22:00:00.000Z")
    }
}

struct ReminderPlanTests {
    private let now = Date(timeIntervalSince1970: 1_796_029_200)  // 2026-11-30 09:00 UTC

    private func reminder(_ task: String, _ at: String, title: String = "Task") -> Reminder {
        Reminder(taskId: task, todoListId: "list", taskTitle: title, remindAt: at)
    }

    @Test func futureRemindersAreScheduledAndPastOnesAreNot() {
        let plan = ReminderPlan(
            reminders: [
                reminder("t1", "2026-11-30T10:00:00.000Z", title: "Call"),
                reminder("t2", "2026-11-30T08:00:00.000Z"),
                reminder("t3", "not a date"),
            ],
            scheduled: [], now: now)

        #expect(plan.toAdd.map(\.identifier) == ["heracles.reminder.t1.2026-11-30T10:00:00.000Z"])
        #expect(plan.toAdd[0].title == "Call")
        #expect(plan.toAdd[0].noteID == "list")
        #expect(plan.toAdd[0].date == Date(timeIntervalSince1970: 1_796_032_800))
        #expect(plan.toRemove.isEmpty)
    }

    @Test func whatIsAlreadyScheduledIsLeftAloneAndWhatIsNoLongerWantedIsRemoved() {
        let kept = "heracles.reminder.t1.2026-11-30T10:00:00.000Z"
        let stale = "heracles.reminder.t9.2026-11-30T11:00:00.000Z"
        let plan = ReminderPlan(
            reminders: [reminder("t1", "2026-11-30T10:00:00.000Z")],
            scheduled: [kept, stale, "someone.elses.notification"], now: now)

        #expect(plan.toAdd.isEmpty)
        #expect(plan.toRemove == [stale], "only this app's reminders are ever removed")
    }

    @Test func aReminderForARenamedTaskIsScheduledAgainUnderItsNewName() {
        let identifier = "heracles.reminder.t1.2026-11-30T10:00:00.000Z"
        let plan = ReminderPlan(
            reminders: [reminder("t1", "2026-11-30T10:00:00.000Z", title: "Call the ferry office")],
            waiting: [ScheduledReminder(identifier: identifier, title: "Call")], now: now)

        #expect(plan.toAdd.map(\.identifier) == [identifier])
        #expect(plan.toAdd.map(\.title) == ["Call the ferry office"])
        #expect(plan.toRemove.isEmpty, "scheduled again under the same identifier, it takes the old one's place")
    }

    @Test func aReminderThatSaysWhatItsTaskIsCalledIsLeftAlone() {
        let identifier = "heracles.reminder.t1.2026-11-30T10:00:00.000Z"
        let plan = ReminderPlan(
            reminders: [reminder("t1", "2026-11-30T10:00:00.000Z", title: " Call ")],
            waiting: [ScheduledReminder(identifier: identifier, title: "Call")], now: now)

        #expect(plan.toAdd.isEmpty)
        #expect(plan.toRemove.isEmpty)
    }

    @Test func aWaitingReminderWhoseWordsCannotBeReadIsLeftAlone() {
        let identifier = "heracles.reminder.t1.2026-11-30T10:00:00.000Z"
        let plan = ReminderPlan(
            reminders: [reminder("t1", "2026-11-30T10:00:00.000Z", title: "Call")],
            waiting: [ScheduledReminder(identifier: identifier, title: nil)], now: now)

        #expect(plan.toAdd.isEmpty)
    }

    @Test func aReminderListedTwiceIsScheduledOnce() {
        let plan = ReminderPlan(
            reminders: [reminder("t1", "2026-11-30T10:00:00.000Z"), reminder("t1", "2026-11-30T10:00:00.000Z")],
            scheduled: [], now: now)

        #expect(plan.toAdd.count == 1)
    }

    @Test func anUntitledTaskStillSaysSomething() {
        let plan = ReminderPlan(reminders: [reminder("t1", "2026-11-30T10:00:00.000Z", title: " ")], scheduled: [], now: now)
        #expect(plan.toAdd[0].title == "Untitled task")
    }
}

struct ReminderPolicyTests {
    @Test func theEverydayAppHandsItsRemindersToTheSystem() {
        #expect(ReminderPolicy.schedules(environment: [:]))
        #expect(ReminderPolicy.schedules(environment: ["HERACLES_DATA_DIR": ""]))
    }

    @Test func aRunOnALibraryOfItsOwnLeavesTheSystemsRemindersAlone() {
        #expect(!ReminderPolicy.schedules(environment: ["HERACLES_DATA_DIR": "/tmp/trial"]))
    }
}

/// Which task a task window shows, as the board changes under it.
struct TaskPathTests {
    private func task(_ id: String, under parent: String? = nil) -> TodoTask {
        TodoTask(
            id: id, todoListId: "list", parentTaskId: parent, columnId: parent == nil ? "col" : nil, title: id,
            description: "", completed: false, position: 0, dueDate: nil, deadline: nil, priority: 4, labels: [],
            reminders: [], location: nil, createdAt: "", updatedAt: "")
    }

    @Test func theWayDownHoldsWhileEachTaskIsUnderTheOneBefore() {
        let tasks = [task("card"), task("sub", under: "card"), task("deep", under: "sub")]
        let path = TaskPath(root: "card", down: ["sub", "deep"]).settled(among: tasks)
        #expect(path == TaskPath(root: "card", down: ["sub", "deep"]))
        #expect(path?.shown == "deep")
    }

    @Test func aDeletedSubtaskEndsTheWayDownAtTheTaskAboveIt() {
        let tasks = [task("card"), task("sub", under: "card")]
        #expect(TaskPath(root: "card", down: ["sub", "deep"]).settled(among: tasks) == TaskPath(root: "card", down: ["sub"]))
    }

    @Test func aWindowWhoseTaskHasGoneHasNothingToShow() {
        #expect(TaskPath(root: "card", down: []).settled(among: [task("other")]) == nil)
        #expect(TaskPath(root: "card", down: ["sub"]).settled(among: [task("other")]) == nil)
    }

    @Test func aSubtaskMadeACardBecomesTheTaskTheWindowStartsFrom() {
        // "sub" was under "card" and is now a card of its own.
        let tasks = [task("card"), task("sub"), task("deep", under: "sub")]
        let path = TaskPath(root: "card", down: ["sub", "deep"]).settled(among: tasks)
        #expect(path == TaskPath(root: "sub", down: ["deep"]), "there is no way back up to a task it is no longer under")
    }

    @Test func theTasksAboveTheOneShownAreItsBreadcrumb() {
        let tasks = [task("card"), task("sub", under: "card"), task("deep", under: "sub")]
        #expect(TaskPath(root: "card", down: ["sub", "deep"]).above == ["card", "sub"])
        #expect(TaskPath(root: "card", down: []).above.isEmpty)
        _ = tasks
    }
}
