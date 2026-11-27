import Foundation
import HeraclesCore

/// Board actions. Each is one write in the core, and the change feed tells
/// every board view of that todo list to reload.
extension AppModel {
    public func columns(of todoListID: String) -> [TaskColumn] {
        (try? store.listColumns(todoListId: todoListID)) ?? []
    }

    public func tasks(of todoListID: String) -> [TodoTask] {
        (try? store.listTasks(todoListId: todoListID)) ?? []
    }

    public func addColumn(to todoListID: String, named name: String) {
        attempt { try store.createColumn(todoListId: todoListID, name: name) }
    }

    public func renameColumn(_ id: String, to name: String) {
        attempt { try store.renameColumn(id: id, name: name) }
    }

    public func deleteColumn(_ id: String) {
        attempt { try store.deleteColumn(id: id) }
    }

    /// Move a column left (a negative number) or right by so many places.
    /// It stops at the ends, and then nothing is written.
    public func moveColumn(_ id: String, in todoListID: String, by places: Int) {
        guard let order = BoardRules.order(of: columns(of: todoListID).map(\.id), moving: id, by: places) else { return }
        attempt { try store.reorderColumns(todoListId: todoListID, orderedIds: order) }
    }

    public func addCard(to todoListID: String, column columnID: String, titled title: String) {
        attempt { try store.createTask(new: NewTask(todoListId: todoListID, columnId: columnID, title: title)) }
    }

    public func setCompleted(_ taskID: String, _ completed: Bool) {
        attempt { try store.updateTask(id: taskID, patch: TaskPatch(completed: completed)) }
    }

    public func renameTask(_ taskID: String, to title: String) {
        attempt { try store.updateTask(id: taskID, patch: TaskPatch(title: title)) }
    }

    /// Put a card in a column, before another card or at the end.
    public func moveCard(_ taskID: String, to columnID: String, before siblingID: String? = nil) {
        attempt { try store.moveTask(id: taskID, columnId: columnID, parentTaskId: nil, beforeId: siblingID) }
    }

    public func deleteTask(_ taskID: String) {
        attempt { try store.deleteTask(id: taskID) }
    }

    public func updateTask(_ taskID: String, _ patch: TaskPatch) {
        attempt { try store.updateTask(id: taskID, patch: patch) }
    }

    public func addSubtask(to parent: TodoTask, titled title: String) {
        attempt {
            try store.createTask(new: NewTask(todoListId: parent.todoListId, parentTaskId: parent.id, title: title))
        }
    }

    public func comments(on taskID: String) -> [TaskComment] {
        (try? store.listComments(taskId: taskID)) ?? []
    }

    public func addComment(to taskID: String, _ body: String) {
        attempt { try store.createComment(taskId: taskID, body: body) }
    }

    public func updateComment(_ commentID: String, _ body: String) {
        attempt { try store.updateComment(id: commentID, body: body) }
    }

    public func deleteComment(_ commentID: String) {
        attempt { try store.deleteComment(id: commentID) }
    }
}

/// What a board decides, worked out apart from its views so it can be tested.
enum BoardRules {
    /// The order of a board's columns once one has moved left (a negative
    /// number) or right by so many places. `nil` when it would not move:
    /// it is at that end already, or it is not one of these columns.
    static func order(of columns: [String], moving id: String, by places: Int) -> [String]? {
        guard let from = columns.firstIndex(of: id) else { return nil }
        let to = min(max(from + places, 0), columns.count - 1)
        guard to != from else { return nil }
        var order = columns
        order.remove(at: from)
        order.insert(id, at: to)
        return order
    }

    /// The name to store once a column's name has been typed over. `nil`
    /// when there is nothing to store: the name is as it was, or nothing
    /// was left of it, and a column is never left with no name.
    static func columnName(typed: String, stored: String) -> String? {
        let name = typed.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == stored ? nil : name
    }

    /// The card a drop moves: the first dragged card that belongs to this
    /// board and is not the card it was dropped on. What is dragged is
    /// text, and text can come from anywhere: a tab, another board, a
    /// word out of a note.
    static func card(in items: [String], of tasks: [TodoTask], droppedOn target: String? = nil) -> String? {
        items.lazy
            .compactMap { CardDrag(text: $0)?.taskID }
            .first { id in id != target && tasks.contains { $0.id == id } }
    }
}

/// A card being dragged, carried as text under a name of its own, so that
/// other text let go over a board is not taken for a card.
struct CardDrag: Equatable {
    var taskID: String

    private static let prefix = "heracles-card:"

    init(taskID: String) {
        self.taskID = taskID
    }

    init?(text: String) {
        guard text.hasPrefix(Self.prefix), text.count > Self.prefix.count else { return nil }
        self.init(taskID: String(text.dropFirst(Self.prefix.count)))
    }

    var text: String { Self.prefix + taskID }
}
