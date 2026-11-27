import Foundation
import HeraclesCore
import Testing

@testable import HeraclesApp

/// What a board decides, apart from its views.
struct BoardRulesTests {
    @Test func aColumnMovesOnePlaceLeftOrRight() {
        #expect(BoardRules.order(of: ["a", "b", "c"], moving: "b", by: -1) == ["b", "a", "c"])
        #expect(BoardRules.order(of: ["a", "b", "c"], moving: "b", by: 1) == ["a", "c", "b"])
    }

    @Test func aColumnAtAnEndDoesNotMovePastIt() {
        #expect(BoardRules.order(of: ["a", "b", "c"], moving: "a", by: -1) == nil)
        #expect(BoardRules.order(of: ["a", "b", "c"], moving: "c", by: 1) == nil)
        #expect(BoardRules.order(of: ["a"], moving: "a", by: 1) == nil)
    }

    @Test func aColumnThatIsNotOnTheBoardDoesNotMove() {
        #expect(BoardRules.order(of: ["a", "b"], moving: "z", by: 1) == nil)
    }

    @Test func aNewNameIsTrimmedAndKept() {
        #expect(BoardRules.columnName(typed: "  Waiting ", stored: "Active") == "Waiting")
    }

    @Test func aColumnIsNeverLeftWithNoName() {
        #expect(BoardRules.columnName(typed: "   ", stored: "Active") == nil)
        #expect(BoardRules.columnName(typed: "", stored: "Active") == nil)
    }

    @Test func aNameThatDidNotChangeIsNotStoredAgain() {
        #expect(BoardRules.columnName(typed: "Active ", stored: "Active") == nil)
    }

    private func task(_ id: String) -> TodoTask {
        TodoTask(
            id: id, todoListId: "list", parentTaskId: nil, columnId: "col", title: id, description: "", completed: false,
            position: 0, dueDate: nil, deadline: nil, priority: 4, labels: [], reminders: [], location: nil,
            createdAt: "", updatedAt: "")
    }

    @Test func aDraggedCardIsCarriedUnderANameOfItsOwn() {
        let drag = CardDrag(taskID: "t1")
        #expect(CardDrag(text: drag.text) == drag)
        #expect(CardDrag(text: "t1") == nil, "plain text is not a card")
        #expect(CardDrag(text: "heracles-card:") == nil)
        #expect(CardDrag(text: TabDrag(leafID: "leaf", noteID: "note").text) == nil, "nor is a tab")
    }

    @Test func onlyACardOfThisBoardIsMovedByADrop() {
        let tasks = [task("t1"), task("t2")]
        #expect(BoardRules.card(in: [CardDrag(taskID: "t2").text], of: tasks) == "t2")
        #expect(BoardRules.card(in: [CardDrag(taskID: "elsewhere").text], of: tasks) == nil)
        #expect(BoardRules.card(in: ["some text", TabDrag(leafID: "l", noteID: "n").text], of: tasks) == nil)
    }

    @Test func aCardDroppedOnItselfStaysWhereItIs() {
        let tasks = [task("t1"), task("t2")]
        #expect(BoardRules.card(in: [CardDrag(taskID: "t1").text], of: tasks, droppedOn: "t1") == nil)
        #expect(BoardRules.card(in: [CardDrag(taskID: "t1").text], of: tasks, droppedOn: "t2") == "t1")
    }
}

/// Board actions against a real core in a throwaway folder.
@MainActor
struct BoardModelTests {
    let store: Store
    let model: AppModel
    let list: Note

    init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("heracles-board-tests-\(UUID().uuidString)")
        store = try Store(dataDir: directory.path)
        model = try AppModel(store: store)
        list = try #require(model.createNote(.todoList, in: model.library.notebooks[0].id))
    }

    private var names: [String] { model.columns(of: list.id).map(\.name) }

    private func column(_ name: String) throws -> TaskColumn {
        try #require(model.columns(of: list.id).first { $0.name == name })
    }

    @Test func aColumnMovesLeftAndRight() throws {
        #expect(names == ["Up Next", "Active", "Done"])

        model.moveColumn(try column("Done").id, in: list.id, by: -1)
        #expect(names == ["Up Next", "Done", "Active"])

        model.moveColumn(try column("Up Next").id, in: list.id, by: 1)
        #expect(names == ["Done", "Up Next", "Active"])
        #expect(model.lastError == nil)
    }

    @Test func movingAColumnPastAnEndChangesNothing() throws {
        let version = model.boardVersion(for: list.id)
        model.moveColumn(try column("Up Next").id, in: list.id, by: -1)
        model.moveColumn(try column("Done").id, in: list.id, by: 1)

        #expect(names == ["Up Next", "Active", "Done"])
        #expect(model.boardVersion(for: list.id) == version, "nothing was written")
        #expect(model.lastError == nil)
    }

    @Test func movingAColumnTellsEveryViewOfTheBoard() throws {
        let version = model.boardVersion(for: list.id)
        model.moveColumn(try column("Active").id, in: list.id, by: 1)
        #expect(model.boardVersion(for: list.id) == version + 1)
    }
}
