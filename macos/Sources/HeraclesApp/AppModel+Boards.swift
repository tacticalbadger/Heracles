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
}
